#
# Tells whether this computer can have a ToR: only macOS has feth interfaces.
#
function has_tor()
{
	[[ "$(uname -s)" == "Darwin" ]]
}

#
# Tells whether the feth pair exists, joined end to end. Whether an end is
# up does not matter: socket_vmnet brings it up when its VM starts, and down
# when it stops.
#
function feth_ready()
{
	ifconfig "$p2p_feth" 2>/dev/null | grep -q "peer: $p2p_feth_tor"
}

#
# Tells whether Lima knows both networks and may start them with sudo.
#
function networks_ready()
{
	grep -q "^  $p2p_network:" "$lima_networks" 2>/dev/null &&
	grep -q "^  $p2p_network_tor:" "$lima_networks" 2>/dev/null &&
	limactl sudoers --check >/dev/null 2>&1
}

#
# Checks that the link is laid, and says how to lay it if not.
#
function check_p2p()
{
	feth_ready && networks_ready && return

	error "The link to the ToR is not there; a restart of the Mac removes it."
	error "Lay it with: task p2p"
	return 1
}

#
# Checks that the VM and its ToR are running.
#
function check_tor_running()
{
	check_running || return $?

	if ! vm_exists "$tor"; then
		error "$name has no ToR. Run: task destroy, task up -- --tor"
		return 1
	fi

	vm_runs "$tor" && return

	error "$tor is not running. Run: task up"
	return 1
}

#
# Prints the state of incusdev's BGP session to the ToR, as Bird calls it:
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
# Prints the ToR and its BGP session, when there is a ToR.
#
function print_tor()
{
	local state="down"

	vm_exists "$tor" || return 0

	log "The ToR:"
	if ! vm_runs "$tor"; then
		printf "  %-18s %-27s %-5s %s\n" "$tor" "stopped" "down" "task up"
		return
	fi

	[[ "$(bgp_state)" == "Established" ]] && state="up"
	printf "  %-18s %-27s %-5s %s\n" "BGP session" "fe80::1%lima0, AS 65000" \
		"$state" "task tor shows the routes"
}

#
# Pings an address from the ToR, from an address of the fabric: the ToR must
# have a route to it, and incusdev one back.
#
function ping_from_tor()
{
	local from="$1"
	local to="$2"

	log "Pinging $to from $from on $tor ..."
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

	log "Waiting for $to to answer $tor ..."
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
# 2001:db8:200::N, from N between 1 and 254. Bird on incusdev announces both
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

	if ! guest incus config device add "$instance" eth0 nic nictype=routed \
	         "ipv4.address=$ipv4" "ipv6.address=$ipv6" "hwaddr=$mac" \
	         >/dev/null ||
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
