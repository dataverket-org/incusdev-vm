#!/usr/bin/env bash
#
# Makes this machine a simulated top-of-rack switch for incusdev: Bird2
# takes BGP sessions on the server port, unnumbered: the port has only
# IPv6 link-local addresses, among them the fixed fe80::1 that servers
# connect to, and IPv4 routes travel with IPv6 next hops (RFC 8950). The
# switch announces the "fabric", a prefix on a dummy interface that stands
# for the rest of the data centre, and installs what servers announce in the
# kernel. Run it as root, in the VM of tor.yaml:
#
#   sudo provision/tor.sh
#
# Safe to run again; Lima runs it on every start. Settings, from the
# environment:
#
#   TOR_IFACE      the server port, default lima0
#   TOR_ADDRESS    the port's fixed link-local address, default fe80::1
#   TOR_ASN        this switch's AS, default 65000
#   TOR_FABRIC4    the fabric's IPv4 address, default 198.51.100.1/24
#   TOR_FABRIC6    the fabric's IPv6 address, default 2001:db8:100::1/64
#
# Servers may use any AS but this one.
#

export DEBIAN_FRONTEND=noninteractive
export HOME=/root

iface="${TOR_IFACE:-lima0}"
address="${TOR_ADDRESS:-fe80::1}"
asn="${TOR_ASN:-65000}"
fabric4="${TOR_FABRIC4:-198.51.100.1/24}"
fabric6="${TOR_FABRIC6:-2001:db8:100::1/64}"

netplan="/etc/netplan/60-tor.yaml"
networkd="/etc/systemd/networkd.conf.d/60-bird.conf"
sysctl="/etc/sysctl.d/60-tor.conf"
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
# Sets up the server port and the fabric through netplan, so that they
# last. The port gets fe80::1 beside its own link-local address, and no
# DHCP: Lima asks for it on every network, and the link has no server, so
# the boot would wait for one. The switch forwards packets, and networkd
# leaves alone the routes that Bird puts in the kernel.
#
function configure_network()
{
	local status

	ip link show "$iface" >/dev/null 2>&1 ||
		{ echo "!!! There is no interface $iface." >&2; return 1; }

	write_file "$networkd" 644 <<EOF
[Network]
ManageForeignRoutes=no
EOF
	status=$?
	(( status == 2 )) && return 1
	(( status == 0 )) && { systemctl restart systemd-networkd || return $?; }

	write_file "$sysctl" 644 <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
	status=$?
	(( status == 2 )) && return 1
	(( status == 0 )) && { sysctl -q -p "$sysctl" || return $?; }

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
      addresses:
      - "$address/64"
  dummy-devices:
    fabric0:
      addresses:
      - "$fabric4"
      - "$fabric6"
EOF
	status=$?
	(( status == 2 )) && return 1
	(( status == 1 )) && ip -br address show dev fabric0 2>/dev/null |
		grep -qF " ${fabric4} " && return

	log "Adding $address on $iface, and the fabric $fabric4 and $fabric6 ..."
	netplan apply || return $?
}

#
# Writes the Bird configuration and has Bird read it.
#
function configure_bird()
{
	local status

	write_file "$bird" 640 <<EOF
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
	status=$?
	(( status == 2 )) && return 1
	(( status == 1 )) && systemctl is-active -q bird && return

	log "Configuring Bird: AS $asn, servers on $iface ..."
	chown root:bird "$bird" || return $?
	systemctl enable bird   || return $?
	systemctl restart bird  || return $?
}

[[ $EUID -eq 0 ]] || fail "Run this as root!"
install_bird      || fail "Installing Bird2 failed!"
configure_network || fail "Configuring the network failed!"
configure_bird    || fail "Configuring Bird failed!"

log "The ToR is ready: AS $asn on $address%$iface, fabric $fabric4 and $fabric6."
