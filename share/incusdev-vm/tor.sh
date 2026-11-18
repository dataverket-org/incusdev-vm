#
# Runs a command in the ToR, the namespace in the VM, with stdin closed.
#
function tor_guest()
{
	guest sudo ip netns exec "$tor_netns" "$@"
}

#
# Asks the ToR's Bird, which has a control socket of its own.
#
function tor_birdc()
{
	guest sudo birdc -s "$tor_socket" "$@"
}

#
# Checks that the VM is running and was made with a ToR.
#
function check_bgp()
{
	check_running || return $?
	vm_has_bgp && return

	error "$name has no ToR! Run: task destroy, task up -- --bgp"
	return 1
}

#
# Prints the state of the VM's BGP session to the ToR, as Bird calls it:
# Established once the two have exchanged routes.
#
function bgp_state()
{
	guest sudo birdc show protocols tor 2>/dev/null |
		awk '$1 == "tor" { print $6; found = 1 } END { exit !found }'
}

#
# Waits until the BGP session to the ToR is established.
#
function wait_for_bgp()
{
	local tries=24

	until [[ "$(bgp_state)" == "Established" ]]; do
		(( tries-- > 0 )) || return 1
		sleep 5
	done
}

#
# Prints the BGP session to the ToR, when the VM has one.
#
function print_tor()
{
	local state="down"

	vm_has_bgp || return 0

	[[ "$(bgp_state)" == "Established" ]] && state="up"
	log "The ToR, in the VM:"
	print_row "BGP session" "fe80::1, AS 65000" "$state" \
		"task tor shows the routes"
}

#
# Pings an address from the ToR, from an address of the fabric: the ToR must
# have a route to it, and the VM one back.
#
function ping_from_tor()
{
	local from="$1"
	local to="$2"

	log "Pinging $to from $from on the ToR ..."
	tor_guest ping -c 3 -W 2 -I "$from" "$to" || return $?
}

#
# Pings an address from the ToR until it answers, for up to the given
# number of seconds: a virtual machine takes minutes to boot.
#
function wait_from_tor()
{
	local from="$1"
	local to="$2"
	local tries=$(( $3 / 5 ))

	log "Waiting for $to to answer the ToR ..."
	until tor_guest ping -c 1 -W 2 -I "$from" "$to" >/dev/null 2>&1; do
		(( tries-- > 0 )) || return 1
		sleep 3
	done
	ping_from_tor "$from" "$to" || return $?
}

#
# Prints the cloud-init network configuration of a virtual machine with a
# routed NIC. It finds the NIC by its MAC address. The link carries IPv6
# only, as the one to the ToR does: both default routes go by fe80::1, which
# Incus puts on the host's side, and IPv4 travels with an IPv6 next hop.
#
function routed_network_config()
{
	local mac="$1"
	local ipv4="$2"
	local ipv6="$3"

	cat <<EOF
version: 2
ethernets:
  eth0:
    match:
      macaddress: "$mac"
    set-name: eth0
    addresses: [$ipv4/32, $ipv6/128]
    routes:
    - {to: 0.0.0.0/0, via: "fe80::1"}
    - {to: "::/0", via: "fe80::1"}
EOF
}

#
# Launches an instance with a routed NIC on 203.0.113.N and
# 2001:db8:200::N, from N between 1 and 254. Bird in the VM announces both
# addresses to the ToR. It is a container, or with --vm a virtual machine.
# A container gets its addresses and routes from Incus, a virtual machine
# from cloud-init. The instance is removed if it does not start.
#
function launch_routed()
{
	local instance="$1"
	local n="$2"
	local vm="${3:-}"
	local ipv4="203.0.113.$n"
	local ipv6="2001:db8:200::$n"
	local mac network args=(images:alpine/3.21 "$instance")

	mac="$(printf "10:66:6a:cb:00:%02x" "$n")"
	if [[ "$vm" == "--vm" ]]; then
		network="$(routed_network_config "$mac" "$ipv4" "$ipv6")"
		args=(images:debian/13/cloud "$instance" --vm
		      --config limits.memory=512MiB
		      --config security.secureboot=false
		      --config "cloud-init.network-config=$network")
	fi

	log "Launching $instance with a routed NIC, $ipv4 and $ipv6 ..."
	guest incus init "${args[@]}" --profile root-local >/dev/null ||
		return $?

	if ! guest incus config device add "$instance" eth0 nic \
	         nictype=routed "ipv4.address=$ipv4" "ipv6.address=$ipv6" \
	         "hwaddr=$mac" >/dev/null ||
	   ! guest incus start "$instance"; then
		guest incus delete --force "$instance"
		return 1
	fi
}

#
# Waits until the ToR reaches both addresses of a routed NIC from
# launch_routed. A virtual machine gets ten minutes, a container one.
#
function wait_for_routed()
{
	local n="$1"
	local vm="${2:-}"
	local seconds=60

	[[ "$vm" == "--vm" ]] && seconds=600
	wait_from_tor 198.51.100.1 "203.0.113.$n" "$seconds"        || return $?
	wait_from_tor 2001:db8:100::1 "2001:db8:200::$n" "$seconds" || return $?
}
