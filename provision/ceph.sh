#!/usr/bin/env bash
#
# Runs a single-container Ceph cluster in rootless Podman on Debian 13,
# installs the Ceph client and gives Incus a storage pool on it. Run it as
# root, after incus.sh:
#
#   sudo provision/ceph.sh
#
# The cluster is newer than Debian 13's Ceph client and kernel, which only
# know keys of the older type aes. So the script lets the cluster use that
# type, and makes the keys of this machine with it.
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

# Where the password of the dashboard's admin is kept, for root to read.
password_file="/etc/ceph/dashboard.password"

# The health checks that Ceph raises once keys of the type aes are allowed.
# They are what this setup is, so they are muted.
aes_checks="AUTH_INSECURE_CLIENT_KEY_TYPE AUTH_INSECURE_KEYS_ALLOWED
	AUTH_INSECURE_KEYS_CREATABLE AUTH_INSECURE_SERVICE_TICKETS"

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
# Installs Debian's Ceph client.
#
function install_ceph_client()
{
	command -v ceph >/dev/null && return

	log "Installing the Ceph client ..."
	apt_get install -y ceph-common || return $?
}

#
# Lets the cluster use keys and tickets of the type aes, next to its own
# type aes256k. The monitors apply the change a moment later.
#
function allow_aes()
{
	local tries=12

	in_container ceph mon dump 2>/dev/null |
		grep -q "^auth_service_cipher aes$" && return

	log "Allowing Ceph keys of the type aes ..."
	in_container ceph mon set auth_allowed_ciphers aes,aes256k || return $?
	in_container ceph mon set auth_service_cipher aes          || return $?

	until in_container ceph mon dump 2>/dev/null |
	      grep -q "^auth_service_cipher aes$"; do
		(( tries-- > 0 )) || return 1
		sleep 5
	done
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
# Copies the cluster's configuration out of the container, and gives this
# machine the admin key. The configuration is copied on every run, since it
# names the monitor's address.
#
# The cluster made its admin key with the type aes256k. The key is made anew
# with the type aes, once, and the container gets the new one too. Right
# after allow_aes the cluster may still refuse the type, so this tries for a
# minute.
#
function configure_ceph_client()
{
	local conf="/etc/ceph/ceph.conf"
	local keyring="/etc/ceph/ceph.client.admin.keyring"
	local tries=12

	mkdir -p /etc/ceph || return $?
	in_container cat /etc/ceph/ceph.conf > "$conf.new" || return $?
	install -m 644 "$conf.new" "$conf" || return $?
	rm -f "$conf.new"

	if ! ceph -s >/dev/null 2>&1; then
		log "Making the Ceph admin key anew, with the type aes ..."
		until ( umask 077 && in_container ceph auth rotate client.admin \
			--key_type aes > "$keyring" 2>/dev/null ); do
			(( tries-- > 0 )) || return 1
			sleep 5
		done
		in_container tee /etc/ceph/ceph.client.admin.keyring \
			< "$keyring" >/dev/null || return $?
	fi

	ceph -s >/dev/null || return $?
}

#
# Mutes the health checks about keys of the type aes, for good.
#
function mute_aes_checks()
{
	local check

	for check in $aes_checks; do
		ceph health mute "$check" --sticky >/dev/null || return $?
	done
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
# Gives the dashboard's admin a password of its own, in place of the one the
# image comes with, which everyone knows. The dashboard takes commands a
# moment after move_dashboard has started it again, so this tries for a
# minute.
#
function set_dashboard_password()
{
	local tries=12

	[[ -s "$password_file" ]] && return

	log "Setting a password for the Ceph dashboard ..."
	( umask 077 && printf "%s" "$(head -c 15 /dev/urandom | base64)" \
		> "$password_file.new" ) || return $?

	until ceph dashboard ac-user-set-password --force-password admin \
	      -i "$password_file.new" >/dev/null 2>&1; do
		(( tries-- > 0 )) || return 1
		sleep 5
	done

	mv "$password_file.new" "$password_file" || return $?
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
		mon "allow *" osd "allow *" mgr "allow *" \
		--key_type aes -o "$keyring" ) || return $?
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
install_podman          || fail "Installing Podman failed!"
start_ceph              || fail "Starting the Ceph container failed!"
wait_for_ceph           || fail "Ceph did not come up!"
install_ceph_client     || fail "Installing the Ceph client failed!"
allow_aes               || fail "Allowing keys of the type aes failed!"
load_rbd                || fail "Loading the rbd module failed!"
configure_ceph_client   || fail "Configuring the Ceph client failed!"
mute_aes_checks         || fail "Muting the health checks failed!"
move_dashboard          || fail "Moving the Ceph dashboard failed!"
set_dashboard_password  || fail "Setting the dashboard's password failed!"
create_s3_users         || fail "Creating the S3 users failed!"
create_incus_key        || fail "Creating the client.incus key failed!"
configure_incus_storage || fail "Creating the ceph storage pool failed!"

log "Ceph is ready."
