#!/usr/bin/env bash
#
# Installs Incus from the Zabbly packages on Debian 13 and gives it a bridge,
# a local storage pool and the profiles. Run it as root, before ceph.sh:
#
#   sudo provision/incus.sh
#
# Lima runs it too, see lima.yaml. It can run again: every step checks before
# it changes anything. Settings, from the environment:
#
#   INCUS_CHANNEL   Zabbly channel: lts-7.0 (default), lts-6.0 or stable
#   INCUSDEV_USER   the user that gets the incus-admin group
#

export DEBIAN_FRONTEND=noninteractive
export HOME=/root

channel="${INCUS_CHANNEL:-lts-7.0}"
# The user that gets the incus-admin group and runs Podman: INCUSDEV_USER,
# or who called sudo, or the first user with a home directory in /home.
user="${INCUSDEV_USER:-${SUDO_USER:-$(getent passwd |
	awk -F: '$6 ~ /^\/home\// { print $1; exit }')}}"

# The bridge's address and subnet, where Incus cannot pick one itself.
subnet="10.158.42.1/24"

keyring="/etc/apt/keyrings/zabbly.asc"
sources="/etc/apt/sources.list.d/zabbly-incus-$channel.sources"

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
# Runs apt-get once no other apt or dpkg is at work, as one is right after a
# first boot. The lock timeout covers one that starts in between.
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
# Adds the Zabbly package repository for the chosen channel.
#
function add_repository()
{
	[[ -f "$keyring" ]] && [[ -f "$sources" ]] && return

	log "Adding the Zabbly $channel repository ..."
	apt_get update                          || return $?
	apt_get install -y ca-certificates curl || return $?
	mkdir -p "${keyring%/*}"                  || return $?
	curl -fsSL -o "$keyring" https://pkgs.zabbly.com/key.asc || return $?

	local codename arch

	codename="$(. /etc/os-release && echo "$VERSION_CODENAME")" || return $?
	arch="$(dpkg --print-architecture)"                         || return $?

	cat > "$sources" <<EOF || return $?
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/$channel
Suites: $codename
Components: main
Architectures: $arch
Signed-By: $keyring
EOF
	apt_get update || return $?
}

#
# Installs the Incus daemon, client and web UI. The Zabbly package carries its
# own QEMU and firmware, so nothing else is needed for virtual machines.
#
function install_incus()
{
	if ! command -v incus >/dev/null; then
		log "Installing Incus ..."
		apt_get install -y incus incus-ui-canonical || return $?
	fi

	if [[ -n "$user" ]]; then
		usermod -aG incus-admin "$user" || return $?
	fi

	incus admin waitready --timeout 120 || return $?
}

#
# Sets a server configuration key unless it already has the value.
#
function set_config()
{
	local key="$1"
	local value="$2"

	[[ "$(incus config get "$key")" == "$value" ]] && return
	incus config set "$key" "$value" || return $?
}

#
# Makes the API and web UI listen on port 8443.
#
function configure_server()
{
	set_config core.https_address ":8443" || return $?
}

#
# Creates the bridge network and puts a NIC on it in the default profile.
#
# Incus picks an IPv4 subnet that nothing answers on. In a Lima VM on macOS
# every address answers a ping, so Incus finds none: then the bridge gets
# the subnet named here.
#
function configure_network()
{
	if ! incus network show incusbr0 >/dev/null 2>&1; then
		log "Creating the network incusbr0 ..."
		incus network create incusbr0 2>/dev/null ||
			incus network create incusbr0 \
				ipv4.address="$subnet" ipv4.nat=true || return $?
	fi

	incus profile device get default eth0 type >/dev/null 2>&1 && return
	incus profile device add default eth0 nic \
		network=incusbr0 name=eth0 || return $?
}

#
# Creates the local storage pool and the profile that boots from it. The
# default profile has no root disk: an instance takes root-local or root-ceph.
#
function configure_local_storage()
{
	if ! incus storage show default >/dev/null 2>&1; then
		log "Creating the storage pool default ..."
		incus storage create default dir || return $?
	fi

	if ! incus profile show root-local >/dev/null 2>&1; then
		incus profile create root-local || return $?
	fi

	incus profile device get root-local root pool >/dev/null 2>&1 && return
	incus profile device add root-local root disk \
		path=/ pool=default || return $?
}

[[ $EUID -eq 0 ]]       || fail "Run this as root!"
add_repository          || fail "Adding the Zabbly repository failed!"
install_incus           || fail "Installing Incus failed!"
configure_server        || fail "Configuring the Incus server failed!"
configure_network       || fail "Configuring the Incus network failed!"
configure_local_storage || fail "Configuring local storage failed!"

[[ -e /dev/kvm ]] || echo "*** No /dev/kvm: containers work," \
	"virtual machines will not start." >&2
log "Incus is ready."
