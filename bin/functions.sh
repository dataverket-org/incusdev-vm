name="incusdev"
root="${BASH_SOURCE[0]%/*}/.."

# The stopped copy of the freshly installed VM that "task reset" starts from.
base="$name-base"

# The simulated top-of-rack switch, a VM of its own on macOS: see tor.yaml.
tor="$name-tor"

# The point-to-point link between the two, laid by "task p2p": a pair of feth
# interfaces joined to each other, and a Lima network bridged on each end.
# Lima gives each VM its end as lima0.
p2p_feth="feth4"
p2p_feth_tor="feth5"
p2p_network="$name-p2p"
p2p_network_tor="$name-p2p-tor"
lima_networks="${LIMA_HOME:-$HOME/.lima}/_config/networks.yaml"

# An Incus source tree on this computer. "task up" mounts it into a new VM,
# writable and at the same path: see "Work on Incus itself" in README.md.
incus_src="${INCUS_SRC:-}"

# Where "task up" keeps the output and the process ID of its background work.
up_log="${TMPDIR:-/tmp}/$name-up.log"
up_pid="${TMPDIR:-/tmp}/$name-up.pid"

#
# Prints a log message.
#
function log()
{
	if [[ -t 1 ]]; then
		echo -e "\x1b[1m\x1b[32m>>>\x1b[0m \x1b[1m$1\x1b[0m"
	else
		echo ">>> $1"
	fi
}

#
# Prints an error message.
#
function error()
{
	if [[ -t 2 ]]; then
		echo -e "\x1b[1m\x1b[31m!!!\x1b[0m \x1b[1m$1\x1b[0m" >&2
	else
		echo "!!! $1" >&2
	fi
}

#
# Prints an error message and exits.
#
function fail()
{
	error "$1"
	exit 1
}

#
# Tells whether the Lima VM exists.
#
function vm_exists()
{
	limactl list --quiet 2>/dev/null | grep -qx "$name"
}

#
# Tells whether the saved copy for "task reset" exists.
#
function base_exists()
{
	limactl list --quiet 2>/dev/null | grep -qx "$base"
}

#
# Tells whether the Lima VM is running.
#
function vm_runs()
{
	[[ "$(limactl list --format '{{.Status}}' "$name" 2>/dev/null)" == \
		"Running" ]]
}

#
# Tells whether the ToR's VM exists.
#
function tor_exists()
{
	limactl list --quiet 2>/dev/null | grep -qx "$tor"
}

#
# Tells whether the ToR's VM is running.
#
function tor_runs()
{
	[[ "$(limactl list --format '{{.Status}}' "$tor" 2>/dev/null)" == \
		"Running" ]]
}

#
# Tells whether this computer has a ToR: only macOS has feth interfaces.
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
# Tells whether "task up" is at work in the background.
#
function up_runs()
{
	[[ -f "$up_pid" ]] || return 1
	ps -p "$(< "$up_pid")" -o args= 2>/dev/null | grep -q "bin/up --run"
}

#
# Checks that limactl is installed and the VM is running.
#
function check_running()
{
	if ! command -v limactl >/dev/null; then
		error "limactl not found. Run: brew bundle"
		return 1
	fi

	if up_runs; then
		error "$name is still starting. Follow it with: task status"
		return 1
	fi

	vm_runs && return

	error "$name is not running. Run: task up"
	return 1
}

#
# Runs a command inside the VM, with stdin closed: incus reads YAML from
# stdin whenever it is not a terminal, and then waits for it.
#
function guest()
{
	limactl shell --workdir / "$name" "$@" </dev/null
}

#
# Waits until the three service ports answer on this computer.
#
function wait_for_services()
{
	local tries=12 url

	for url in https://127.0.0.1:26870 https://127.0.0.1:26871 \
	           http://127.0.0.1:26872; do
		until curl -k -s -o /dev/null --max-time 3 "$url"; do
			(( tries-- > 0 )) || return 1
			sleep 5
		done
	done
}

#
# Prints the services that the VM offers on this computer, and says for each
# whether it answers. The ports are those of portForwards in lima.yaml. Any
# HTTP status counts as an answer: the S3 API says 403 without a key.
#
function print_services()
{
	local service url hint state

	log "Services on this computer:"
	while read -r service url hint; do
		state="down"
		curl -k -s -o /dev/null --max-time 3 "$url" && state="up"
		printf "  %-18s %-27s %-5s %s\n" \
			"${service//_/ }" "$url" "$state" "${hint//_/ }"
	done <<EOF
Incus_API https://127.0.0.1:26870 task_dashboard_adds_the_incus_remote
Incus_web_UI https://127.0.0.1:26870/ui/ task_dashboard_--_incus
Ceph_dashboard https://127.0.0.1:26871 task_dashboard_--_ceph
S3_API http://127.0.0.1:26872 task_s3-credentials
RadosGW_admin_API http://127.0.0.1:26872/admin task_s3-credentials_--_admin
EOF
	echo "  How to log in to each: docs/access.md"
}

#
# Runs a command inside the ToR's VM, with stdin closed.
#
function tor_guest()
{
	limactl shell --workdir / "$tor" "$@" </dev/null
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
	local state

	tor_exists || return 0

	log "The ToR:"
	if ! tor_runs; then
		printf "  %-18s %-27s %-5s %s\n" "$tor" "stopped" "down" "task up"
		return
	fi
	state="$(bgp_state)"
	printf "  %-18s %-27s %-5s %s\n" "BGP session" "fe80::1%lima0, AS 65000" \
		"$( [[ "$state" == "Established" ]] && echo up || echo down )" \
		"task tor shows the routes"
}

#
# Pings an address from the ToR, from an address of the fabric: the ToR must
# have a route to it, and incusdev one back.
#
function ping_from_tor()
{
	local from="$1" to="$2"

	log "Pinging $to from $from on $tor ..."
	tor_guest ping -c 3 -W 2 -I "$from" "$to" || return $?
}

#
# Pings an address from the ToR until it answers, for up to the given
# number of seconds: a virtual machine takes minutes to boot.
#
function wait_from_tor()
{
	local from="$1" to="$2" tries=$(( $3 / 5 ))

	log "Waiting for $to to answer $tor ..."
	until tor_guest ping -c 1 -W 2 -I "$from" "$to" >/dev/null 2>&1; do
		(( tries-- > 0 )) || return 1
		sleep 3
	done
	ping_from_tor "$from" "$to" || return $?
}

#
# Launches an instance with a routed NIC on 203.0.113.N and
# 2001:db8:200::N, from N between 1 and 254. Bird on incusdev announces both
# addresses to the ToR. It is a virtual machine with --vm, else a container.
# A container gets its addresses and routes from Incus. A virtual machine
# configures its NIC itself, by cloud-init, finding it by a MAC address made
# from N. Its link carries IPv6 only, as the one to the ToR does: both
# default routes go by fe80::1, which Incus puts on the host's side, and
# IPv4 travels with an IPv6 next hop.
#
function launch_routed()
{
	local instance="$1" n="$2" vm="${3:-}" ipv4 ipv6 mac network status=0
	local args=(images:alpine/3.21 "$instance" --profile root-local)

	ipv4="203.0.113.$n"
	ipv6="2001:db8:200::$n"
	mac="$(printf "10:66:6a:cb:00:%02x" "$n")"

	if [[ "$vm" == "--vm" ]]; then
		network="version: 2
ethernets:
  eth0:
    match:
      macaddress: \"$mac\"
    set-name: eth0
    addresses: [$ipv4/32, $ipv6/128]
    routes:
    - {to: 0.0.0.0/0, via: \"fe80::1\"}
    - {to: \"::/0\", via: \"fe80::1\"}"
		args=(images:debian/13/cloud "$instance" --vm --profile root-local
			--config limits.memory=512MiB --config security.secureboot=false
			--config "cloud-init.network-config=$network")
	fi

	log "Launching $instance with a routed NIC, $ipv4 and $ipv6 ..."
	guest incus init "${args[@]}" >/dev/null || return $?
	guest incus config device add "$instance" eth0 nic nictype=routed \
		"ipv4.address=$ipv4" "ipv6.address=$ipv6" "hwaddr=$mac" \
		>/dev/null || status=$?
	(( status == 0 )) && { guest incus start "$instance" || status=$?; }
	(( status == 0 )) || { guest incus delete --force "$instance"; return "$status"; }
}

#
# Waits until the ToR reaches both addresses of a routed NIC from launch_routed.
#
function wait_for_routed()
{
	local n="$1" vm="${2:-}" wait=60

	[[ "$vm" == "--vm" ]] && wait=600
	wait_from_tor 198.51.100.1 "203.0.113.$n" "$wait"         || return $?
	wait_from_tor 2001:db8:100::1 "2001:db8:200::$n" "$wait"  || return $?
}
