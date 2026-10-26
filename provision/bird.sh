#!/usr/bin/env bash
#
# Peers this Incus host with its top-of-rack switch: Bird2 holds a BGP
# session, unnumbered, from its own IPv6 link-local address to the switch's
# fe80::1 on the link. IPv4 routes travel with IPv6 next hops (RFC 8950).
# Bird announces the Incus networks, and the addresses of routed NICs, which
# it learns from the routes that Incus puts in the kernel for them. It
# installs what the switch announces in the kernel, but never a default
# route: that stays on eth0. Run it as root, after incus.sh:
#
#   sudo provision/bird.sh
#
# Without the link it does nothing, so Lima runs it in every VM, on every
# start, and only a VM made with "task up -- --tor" has the link. The
# switch is provision/tor.sh. Settings, from the environment:
#
#   BGP_IFACE      the link to the switch, default lima0
#   BGP_PEER       the switch's link-local address, default fe80::1
#   BGP_PEER_ASN   the switch's AS, default 65000
#   BGP_ASN        this host's AS, default 65001
#   BGP_NETWORKS   the interfaces whose networks are announced, default
#                  incusbr0
#   BGP_ROUTED4    where routed NICs take IPv4 addresses, announced as
#                  /32s, default 203.0.113.0/24
#   BGP_ROUTED6    where routed NICs take IPv6 addresses, announced as
#                  /128s, default 2001:db8:200::/48
#
# A routed NIC, with an address from each range:
#
#   incus config device add v1 eth0 nic nictype=routed \
#       ipv4.address=203.0.113.10 ipv6.address=2001:db8:200::10
#

export DEBIAN_FRONTEND=noninteractive
export HOME=/root

iface="${BGP_IFACE:-lima0}"
peer="${BGP_PEER:-fe80::1}"
peer_asn="${BGP_PEER_ASN:-65000}"
asn="${BGP_ASN:-65001}"
networks="${BGP_NETWORKS:-incusbr0}"
routed4="${BGP_ROUTED4:-203.0.113.0/24}"
routed6="${BGP_ROUTED6:-2001:db8:200::/48}"

netplan="/etc/netplan/60-bird.yaml"
networkd="/etc/systemd/networkd.conf.d/60-bird.conf"
bird="/etc/bird/bird.conf"

#
# Prints a log message.
#
function log()
{
	echo ">>> $1"
}

#
# Prints an error message and exits.
#
function fail()
{
	echo "!!! $1" >&2
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
# Writes stdin to a file if that changes it. Returns 0 when it wrote, 1 when
# the file was already so, and 2 when writing failed.
#
function write_file()
{
	local file="$1" mode="$2" content

	content="$(cat)"
	[[ -f "$file" ]] && [[ "$(< "$file")" == "$content" ]] && return 1

	mkdir -p "${file%/*}"                || return 2
	install -m "$mode" /dev/null "$file" || return 2
	echo "$content" > "$file"            || return 2
}

#
# Installs Bird2.
#
function install_bird()
{
	command -v bird >/dev/null && return

	log "Installing Bird2 ..."
	apt_get update           || return $?
	apt_get install -y bird2 || return $?
}

#
# Leaves the link with its link-local address only. On Lima's link, which
# has no DHCP server, it also turns off the DHCP that Lima asks for, which
# the boot would wait for; another host's interface keeps its settings.
# networkd leaves alone the routes that Bird puts in the kernel.
#
function configure_network()
{
	local status

	write_file "$networkd" 644 <<EOF
[Network]
ManageForeignRoutes=no
EOF
	status=$?
	(( status == 2 )) && return 1
	(( status == 0 )) && { systemctl restart systemd-networkd || return $?; }

	[[ "$iface" == lima* ]] || return 0

	write_file "$netplan" 600 <<EOF
network:
  version: 2
  ethernets:
    $iface:
      dhcp4: false
      dhcp6: false
      accept-ra: false
      optional: true
      link-local: [ipv6]
EOF
	status=$?
	(( status == 2 )) && return 1
	(( status == 1 )) && return

	log "Leaving $iface with its link-local address only ..."
	netplan apply || return $?
}

#
# Writes the Bird configuration and has Bird read it. The router ID is the
# first network's IPv4 address: eth0 has the same address in every Lima VM,
# the switch's among them.
#
function configure_bird()
{
	local status router_id interfaces="" network

	router_id="$(ip -4 -o address show dev "${networks%% *}" 2>/dev/null |
		awk '{ sub("/.*", "", $4); print $4; exit }')"
	[[ -n "$router_id" ]] ||
		{ echo "!!! ${networks%% *} has no IPv4 address." >&2; return 1; }

	for network in $networks; do
		interfaces+="${interfaces:+, }\"$network\""
	done

	write_file "$bird" 640 <<EOF
# This Incus host and its top-of-rack switch, written by provision/bird.sh.

router id $router_id;
log syslog all;

protocol device {
}

# The Incus networks: what this host offers the switch.
protocol direct {
	ipv4;
	ipv6;
	interface $interfaces;
}

# Where routed NICs take their addresses.
define ROUTED4 = [ $routed4+ ];
define ROUTED6 = [ $routed6+ ];

# What the switch announces goes into the kernel. From the kernel come the
# routes that Incus adds for routed NICs, one for each address.
protocol kernel {
	learn;
	ipv4 {
		import where net ~ ROUTED4;
		export where source = RTS_BGP;
	};
}

protocol kernel {
	learn;
	ipv6 {
		import where net ~ ROUTED6;
		export where source = RTS_BGP;
	};
}

protocol bgp tor {
	interface "$iface";
	local as $asn;
	neighbor $peer as $peer_asn;
	ipv4 {
		extended next hop on;
		import where net != 0.0.0.0/0;
		export where source = RTS_DEVICE ||
			(source = RTS_INHERIT && net ~ ROUTED4);
	};
	ipv6 {
		import where net != ::/0;
		export where source = RTS_DEVICE ||
			(source = RTS_INHERIT && net ~ ROUTED6);
	};
}
EOF
	status=$?
	(( status == 2 )) && return 1
	(( status == 1 )) && systemctl is-active -q bird && return

	log "Configuring Bird: AS $asn, the switch $peer%$iface in AS $peer_asn ..."
	chown root:bird "$bird" || return $?
	systemctl enable bird   || return $?
	systemctl restart bird  || return $?
}

[[ $EUID -eq 0 ]] || fail "Run this as root!"
ip link show "$iface" >/dev/null 2>&1 || exit 0

install_bird      || fail "Installing Bird2 failed!"
configure_network || fail "Configuring the network failed!"
configure_bird    || fail "Configuring Bird failed!"

log "Bird is ready: AS $asn, peering with the switch on $iface."
