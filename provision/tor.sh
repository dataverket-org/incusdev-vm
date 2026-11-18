#!/usr/bin/env bash
#
# Gives this Incus host a simulated top-of-rack switch (ToR): a network
# namespace, joined to the host by a pair of veth interfaces, with a Bird2
# of its own in it. The switch takes BGP sessions on its server port,
# unnumbered: the port has only IPv6 link-local addresses, among them the
# fixed fe80::1 that servers connect to, and IPv4 routes travel with IPv6
# next hops (RFC 8950). It announces the "fabric", a prefix on a dummy
# interface that stands for the rest of the data centre, and installs what
# servers announce in its own routing table. Run it as root, before bird.sh:
#
#   sudo provision/tor.sh
#
# The commands that make the namespace and the link are the ExecStart lines
# of incusdev-tor.service, which runs them on every boot; "systemctl cat
# incusdev-tor" shows them. Bird runs in the namespace as
# incusdev-tor-bird.service.
#
# Safe to run again; Lima runs it on every start, and it does nothing in a
# VM made without "task up -- --bgp": Lima says so with PARAM_BGP=off.
# Settings, from the environment:
#
#   TOR_NETNS      the namespace, default incusdev-tor
#   TOR_LINK       the host's end of the link, default incusdev-tor0
#   TOR_IFACE      the switch's end, its server port, default server0
#   TOR_ADDRESS    the port's fixed link-local address, default fe80::1
#   TOR_ASN        this switch's AS, default 65000
#   TOR_FABRIC4    the fabric's IPv4 address, default 198.51.100.1/24
#   TOR_FABRIC6    the fabric's IPv6 address, default 2001:db8:100::1/64
#
# Servers may use any AS but this one.
#
# On a host with a network of its own, the names are the script's, and the
# addresses are from the ranges set aside for documentation. It stops
# before changing anything where the namespace or the link exists already
# and is not this script's. To remove the switch again:
#
#   sudo systemctl disable --now incusdev-tor-bird incusdev-tor
#   sudo rm /etc/systemd/system/incusdev-tor*.service /etc/bird/tor.conf
#

export DEBIAN_FRONTEND=noninteractive
export HOME=/root

netns="${TOR_NETNS:-incusdev-tor}"
link="${TOR_LINK:-incusdev-tor0}"
iface="${TOR_IFACE:-server0}"
address="${TOR_ADDRESS:-fe80::1}"
asn="${TOR_ASN:-65000}"
fabric4="${TOR_FABRIC4:-198.51.100.1/24}"
fabric6="${TOR_FABRIC6:-2001:db8:100::1/64}"

link_service="incusdev-tor.service"
bird_service="incusdev-tor-bird.service"
units="/etc/systemd/system"
bird="/etc/bird/tor.conf"
runtime="incusdev-tor"
socket="/run/$runtime/bird.ctl"

# Set to 1 once the namespace is made anew, and Bird must start in it again.
restarted=0

#
# Prints a log message.
#
function log()
{
	echo ">>> $1"
}

#
# Prints an error message.
#
function error()
{
	echo "!!! $1" >&2
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
# Runs apt-get. It waits for another apt or dpkg instead of failing on the
# lock.
#
function apt_get()
{
	local tries=60

	while pgrep -x "apt|apt-get|dpkg" >/dev/null ||
	      pgrep -f "bin/unattended-upgrade" >/dev/null; do
		(( tries-- > 0 )) || break
		sleep 5
	done

	apt-get -q -o DPkg::Lock::Timeout=300 "$@" || return $?
}

#
# Writes stdin to a file with the given mode, unless the file holds it
# already. Sets changed to 1 when it wrote, else to 0.
#
function write_file()
{
	local file="$1"
	local mode="$2"
	local content

	content="$(cat)"
	changed=0
	[[ -f "$file" && "$(< "$file")" == "$content" ]] && return

	mkdir -p "${file%/*}"                || return $?
	install -m "$mode" /dev/null "$file" || return $?
	cat > "$file" <<< "$content"         || return $?
	changed=1
}

#
# Checks that the namespace and the link are free, or this script's: its
# unit is there once it has made them.
#
function check_free()
{
	[[ -f "$units/$link_service" ]] && return

	if [[ -e "/run/netns/$netns" ]]; then
		error "A namespace $netns exists already. Set TOR_NETNS!"
		return 1
	fi

	if [[ -e "/sys/class/net/$link" ]]; then
		error "An interface $link exists already. Set TOR_LINK!"
		return 1
	fi
}

#
# Installs Bird2. The package's own service is the host's Bird, which
# bird.sh configures.
#
function install_bird()
{
	command -v bird >/dev/null && return

	log "Installing Bird2 ..."
	apt_get update           || return $?
	apt_get install -y bird2 || return $?
}

#
# Makes the namespace and the link, with a unit that makes them again on
# every boot: the switch's end of the link gets fe80::1 beside its own
# link-local address, the host's end only its own. The switch forwards
# packets. A namespace left from before is removed first.
#
function configure_link()
{
	write_file "$units/$link_service" 644 <<EOF || return $?
# Written by provision/tor.sh.
[Unit]
Description=incusdev: the top-of-rack switch's namespace and its link
Before=bird.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-ip netns delete $netns
ExecStart=ip netns add $netns
ExecStart=ip link add $link type veth peer name $iface netns $netns
ExecStart=ip -n $netns link add fabric0 type dummy
ExecStart=ip -n $netns address add $fabric4 dev fabric0
ExecStart=ip -n $netns address add $fabric6 dev fabric0 nodad
ExecStart=ip -n $netns address add $address/64 dev $iface nodad
ExecStart=ip netns exec $netns sysctl -q -w net.ipv4.ip_forward=1
ExecStart=ip netns exec $netns sysctl -q -w net.ipv6.conf.all.forwarding=1
ExecStart=ip -n $netns link set lo up
ExecStart=ip -n $netns link set fabric0 up
ExecStart=ip -n $netns link set $iface up
ExecStart=ip link set $link up
ExecStop=ip netns delete $netns

[Install]
WantedBy=multi-user.target
EOF
	(( ! changed )) && systemctl is-active -q "$link_service" && return

	log "Making the namespace $netns, and the link $link into it ..."
	systemctl daemon-reload             || return $?
	systemctl enable -q "$link_service" || return $?
	systemctl restart "$link_service"   || return $?
	restarted=1
}

#
# Writes the switch's Bird configuration, and the unit that runs a second
# Bird with it, in the namespace and with a control socket of its own.
#
function configure_bird()
{
	local conf_changed

	write_file "$bird" 640 <<EOF || return $?
# The simulated top-of-rack switch, written by provision/tor.sh.

router id ${fabric4%/*};
log syslog all;

protocol device {
}

# The fabric: what this switch offers its servers.
protocol direct {
	ipv4;
	ipv6;
	interface "fabric0";
}

# What the servers announce goes into the kernel.
protocol kernel {
	ipv4 {
		export where source = RTS_BGP;
	};
}

protocol kernel {
	ipv6 {
		export where source = RTS_BGP;
	};
}

# The server port, unnumbered: a session for each server that connects from
# its link-local address, in an AS of its own.
protocol bgp servers {
	interface "$iface";
	local as $asn;
	neighbor range fe80::/10 external;
	dynamic name "server";
	ipv4 {
		extended next hop on;
		import all;
		export where source = RTS_DEVICE;
	};
	ipv6 {
		import all;
		export where source = RTS_DEVICE;
	};
}
EOF
	conf_changed="$changed"
	chown root:bird "$bird" || return $?

	write_file "$units/$bird_service" 644 <<EOF || return $?
# Written by provision/tor.sh.
[Unit]
Description=incusdev: Bird2 in the top-of-rack switch
Requires=$link_service
After=$link_service
PartOf=$link_service

[Service]
NetworkNamespacePath=/run/netns/$netns
RuntimeDirectory=$runtime
ExecStart=/usr/sbin/bird -f -u bird -g bird -c $bird -s $socket
ExecReload=/usr/sbin/birdc -s $socket configure
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
	(( ! changed && ! conf_changed && ! restarted )) &&
		systemctl is-active -q "$bird_service" && return

	log "Configuring the switch's Bird: AS $asn, servers on $iface ..."
	systemctl daemon-reload             || return $?
	systemctl enable -q "$bird_service" || return $?
	systemctl restart "$bird_service"   || return $?
}

[[ "${PARAM_BGP:-on}" == "on" ]] || exit 0
[[ $EUID -eq 0 ]] || fail "Run this as root!"

check_free     || exit $?
install_bird   || fail "Installing Bird2 failed!"
configure_link || fail "Making the namespace and the link failed!"
configure_bird || fail "Configuring the switch's Bird failed!"

log "The ToR is ready: AS $asn on $address%$link, fabric $fabric4, $fabric6."
