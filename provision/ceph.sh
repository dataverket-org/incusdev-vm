#!/usr/bin/env bash
#
# Runs a single-container Ceph cluster in rootless Podman on Debian 13,
# installs the Ceph client and gives Incus a storage pool on it. Run it as
# root, after incus.sh:
#
#   sudo provision/ceph.sh
#
# It installs Linux 7 from trixie-backports, which the kernel needs to use
# Ceph's keys. Reboot the machine afterwards when the script says so.
#
# Lima runs it too, see lima.yaml. It can run again: every step checks before
# it changes anything. Settings, from the environment:
#
#   CEPH_IMAGE      default quay.io/benjamin_holmes/ceph-aio:v20
#   OSD_SIZE        size of the one OSD, default 10G; counts on the first run
#   INCUSDEV_USER   the user that runs Podman
#

export DEBIAN_FRONTEND=noninteractive
export HOME=/root

image="${CEPH_IMAGE:-quay.io/benjamin_holmes/ceph-aio:v20}"
osd_size="${OSD_SIZE:-10G}"
# The user that gets the incus-admin group and runs Podman: INCUSDEV_USER,
# or who called sudo, or the first user with a home directory in /home.
user="${INCUSDEV_USER:-${SUDO_USER:-$(getent passwd |
	awk -F: '$6 ~ /^\/home\// { print $1; exit }')}}"
uid="$(id -u "$user")"

container="ceph-dev"

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
# Runs a command as the Lima user, with the user's systemd session.
#
function as_user()
{
	sudo -u "$user" -H env -C / \
		XDG_RUNTIME_DIR="/run/user/$uid" \
		DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
		"$@"
}

#
# Runs a command inside the Ceph container.
#
function in_container()
{
	as_user podman exec -i "$container" "$@"
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
# Tells whether the running kernel can use Ceph's keys. Ceph makes keys of
# the type aes256k, which the kernel's RBD client knows from Linux 7.0 on.
# Debian 13 comes with Linux 6.12.
#
function kernel_is_new()
{
	local release

	release="$(uname -r)"
	(( ${release%%.*} >= 7 ))
}

#
# Installs the kernel from trixie-backports, unless the running or an
# installed kernel is new enough. It counts from the next boot.
#
function install_kernel()
{
	local package codename

	kernel_is_new && return
	compgen -G "/boot/vmlinuz-[7-9].*" >/dev/null && return

	package="linux-image-$(dpkg --print-architecture)"         || return $?
	codename="$(. /etc/os-release && echo "$VERSION_CODENAME")" || return $?

	log "Installing Linux 7 from $codename-backports ..."
	apt_get update || return $?

	if ! apt-cache policy | grep -q "$codename-backports"; then
		cat > /etc/apt/sources.list.d/backports.sources <<EOF || return $?
Types: deb
URIs: http://deb.debian.org/debian
Suites: $codename-backports
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
		apt_get update || return $?
	fi

	apt_get install -y -t "$codename-backports" "$package" || return $?
}

#
# Installs Podman and what it needs to run rootless without a login session:
# a user D-Bus, subordinate IDs and a lingering user manager.
#
function install_podman()
{
	if ! command -v podman >/dev/null || ! command -v jq >/dev/null; then
		log "Installing Podman ..."
		apt_get update || return $?
		apt_get install -y podman uidmap dbus-user-session \
			slirp4netns passt jq curl || return $?
	fi

	if ! grep -q "^$user:" /etc/subuid; then
		usermod --add-subuids 100000-165535 \
			--add-subgids 100000-165535 "$user" || return $?
	fi

	loginctl enable-linger "$user" || return $?

	# The user manager was started before dbus-user-session was installed,
	# so it has to be told about the bus. Restarting it would close the
	# session this script runs in.
	as_user systemctl --user daemon-reload      || return $?
	as_user systemctl --user start dbus.socket || return $?

	local tries=30

	until [[ -S "/run/user/$uid/bus" ]]; do
		(( tries-- > 0 )) || return 1
		sleep 1
	done
}

#
# Starts the Ceph container on the host network, so the monitor is reachable
# from the VM's kernel on the VM's own address.
#
function start_ceph()
{
	if ! as_user podman container exists "$container"; then
		log "Starting Ceph from $image ..."
		as_user podman run -d --name "$container" \
			--network host --restart always \
			-e OSD_SIZE="$osd_size" "$image" || return $?
	fi

	# Brings the container back after a reboot of the VM.
	as_user systemctl --user enable -q podman-restart.service || return $?
	as_user podman start "$container" >/dev/null || return $?
}

#
# Waits until the cluster answers and its OSD is up.
#
function wait_for_ceph()
{
	local tries=36

	log "Waiting for Ceph ..."
	until in_container timeout 10 ceph -s --format json 2>/dev/null |
	      jq -e '.osdmap.num_up_osds >= 1' >/dev/null 2>&1; do
		(( tries-- > 0 )) || return 1
		sleep 5
	done
}

#
# Installs the Ceph client of the cluster's release. Debian 13 ships Ceph 18;
# Proxmox publishes newer ones for trixie, for amd64 only, in a repository
# named after the release. The cluster says which release it is, so a newer
# image brings its own client along.
#
function install_ceph_client()
{
	command -v ceph >/dev/null && return

	local keyring="/usr/share/keyrings/proxmox-archive-keyring.gpg"
	local proxmox="download.proxmox.com/debian"
	local release repository

	if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
		echo "*** No Proxmox packages for this architecture," \
			"using Debian's Ceph client." >&2
		apt_get install -y ceph-common || return $?
		return
	fi

	# "ceph version 20.2.4 (7f79...) tentacle (stable)"
	release="$(in_container ceph --version | awk '{ print $5 }')" || return $?
	repository="ceph-$release"

	if ! curl -fsSL -o /dev/null \
	     "http://$proxmox/$repository/dists/trixie/InRelease"; then
		echo "!!! Proxmox has no repository $repository for trixie:" \
			"no client for this Ceph release." >&2
		return 1
	fi

	log "Adding the Proxmox repository $repository ..."
	curl -fsSL -o "$keyring" \
		"https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg" ||
		return $?
	cat > /etc/apt/sources.list.d/ceph.sources <<EOF || return $?
Types: deb
URIs: http://$proxmox/$repository
Suites: trixie
Components: no-subscription
Signed-By: $keyring
EOF
	apt_get update || return $?

	log "Installing the Ceph client ..."
	apt_get install -y ceph-common || return $?
}

#
# Loads the RBD kernel module, now and on every boot.
#
function load_rbd()
{
	modprobe rbd                           || return $?
	echo rbd > /etc/modules-load.d/rbd.conf || return 1
}

#
# Copies the cluster's configuration and admin keyring out of the container.
# The configuration is copied on every run, since it names the monitor's
# address.
#
function configure_ceph_client()
{
	local conf="/etc/ceph/ceph.conf"
	local keyring="/etc/ceph/ceph.client.admin.keyring"

	mkdir -p /etc/ceph || return $?
	in_container cat /etc/ceph/ceph.conf > "$conf.new" || return $?
	install -m 644 "$conf.new" "$conf" || return $?
	rm -f "$conf.new"

	( umask 077 && in_container ceph auth get client.admin \
		> "$keyring" 2>/dev/null ) || return $?
	ceph -s >/dev/null || return $?
}

#
# Moves the Ceph dashboard from port 8443, which Incus listens on, to 8444.
#
function move_dashboard()
{
	local key="mgr/dashboard/ssl_server_port"

	[[ "$(ceph config get mgr "$key")" == "8444" ]] && return

	log "Moving the Ceph dashboard to port 8444 ..."
	ceph config set mgr mgr/dashboard/server_port 8444 || return $?
	ceph config set mgr "$key" 8444                    || return $?
	ceph mgr module disable dashboard                  || return $?
	ceph mgr module enable dashboard                   || return $?
}

#
# Creates the two users of the object gateway, RadosGW: incusdev for the S3
# API, and incusdev-admin, which may also use the RadosGW admin API, under
# /admin on the same port. Ceph makes their keys;
# "radosgw-admin user info --uid NAME" shows them.
#
function create_s3_users()
{
	local caps="users=*;buckets=*;metadata=*;usage=*;info=*"

	if ! radosgw-admin user info --uid incusdev >/dev/null 2>&1; then
		log "Creating the S3 user incusdev ..."
		radosgw-admin user create --uid incusdev \
			--display-name "incusdev" >/dev/null 2>&1 || return $?
	fi

	radosgw-admin user info --uid incusdev-admin >/dev/null 2>&1 && return

	log "Creating the RadosGW admin user incusdev-admin ..."
	radosgw-admin user create --uid incusdev-admin \
		--display-name "incusdev admin" \
		--caps "$caps" >/dev/null 2>&1 || return $?
}

#
# Creates the client.incus key that Incus and the kernel map RBD images with.
#
function create_incus_key()
{
	local keyring="/etc/ceph/ceph.client.incus.keyring"

	if [[ -f "$keyring" ]] && ceph --id incus -s >/dev/null 2>&1; then
		return
	fi

	log "Creating the Ceph key client.incus ..."
	( umask 077 && ceph auth get-or-create client.incus \
		mon "allow *" osd "allow *" mgr "allow *" -o "$keyring" ) ||
		return $?
	ceph --id incus -s >/dev/null || return $?
}

#
# Creates the Incus storage pool on Ceph and the profile that boots from it.
#
function configure_incus_storage()
{
	incus admin waitready --timeout 120 || return $?

	if ! incus storage show ceph >/dev/null 2>&1; then
		log "Creating the storage pool ceph ..."
		incus storage create ceph ceph source=incus \
			ceph.cluster_name=ceph ceph.user.name=incus \
			ceph.osd.pg_num=32 || return $?
	fi

	if ! incus profile show root-ceph >/dev/null 2>&1; then
		incus profile create root-ceph || return $?
	fi

	incus profile device get root-ceph root pool >/dev/null 2>&1 && return
	incus profile device add root-ceph root disk \
		path=/ pool=ceph || return $?
}

[[ $EUID -eq 0 ]]       || fail "Run this as root!"
install_kernel          || fail "Installing the kernel failed!"
install_podman          || fail "Installing Podman failed!"
start_ceph              || fail "Starting the Ceph container failed!"
wait_for_ceph           || fail "Ceph did not come up!"
install_ceph_client     || fail "Installing the Ceph client failed!"
load_rbd                || fail "Loading the rbd module failed!"
configure_ceph_client   || fail "Configuring the Ceph client failed!"
move_dashboard          || fail "Moving the Ceph dashboard failed!"
create_s3_users         || fail "Creating the S3 users failed!"
create_incus_key        || fail "Creating the client.incus key failed!"
configure_incus_storage || fail "Creating the ceph storage pool failed!"

log "Ceph is ready."
kernel_is_new ||
	log "Reboot this machine: Incus needs the new kernel to use Ceph."
