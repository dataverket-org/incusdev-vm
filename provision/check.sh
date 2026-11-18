#!/usr/bin/env bash
#
# Tests the testbed end to end, on the machine it is installed on. Run it as
# root, after incus.sh, and after ceph.sh if Ceph is wanted:
#
#   sudo provision/check.sh
#
# It checks that an Incus instance boots from the local pool and gets an
# address, and the Incus API and web UI. Where ceph.sh has given Incus its
# pool ceph, or with --ceph, which fails without it, the instance boots from the ceph pool in
# place of the local one, and it also checks Ceph, the kernel mapping an RBD
# image, and Ceph's dashboard, S3 API and RadosGW admin API. The instance is
# a container, which needs no nested virtualization; with --vm it is a
# virtual machine, and KVM is checked first. It removes what it makes, and
# force-deletes any instance named incusdev-check.
#
#   sudo provision/check.sh --vm
#

export HOME=/root

instance="incusdev-check"
image="images:alpine/3.21"
rbd_image="incus/incusdev-check"
mode="container"
with_ceph=""
pool="default"
profile="root-local"

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
# Prints usage information for check.sh.
#
function usage()
{
	cat <<USAGE
usage: check.sh [OPTIONS]

Options:

	    --vm		Launches a virtual machine in place of a
				container, which needs KVM
	    --ceph		Fails unless ceph.sh has installed Ceph
	-h, --help		Prints this message

Examples:

	$ sudo provision/check.sh
	$ sudo provision/check.sh --vm

USAGE
}

#
# Parses command-line options for check.sh.
#
function parse_options()
{
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--vm)
				mode="vm"
				shift
				;;
			--ceph)
				with_ceph=1
				shift
				;;
			-h|--help)
				usage
				exit
				;;
			*)
				echo "check.sh: unrecognized option $1" >&2
				return 1
				;;
		esac
	done
}

#
# Checks that the machine has KVM and that Incus found QEMU.
#
function check_kvm()
{
	[[ -e /dev/kvm ]] || return 1
	incus info </dev/null | grep -q 'driver:.*qemu' || return $?
}

#
# Checks that Incus found LXC, which runs the containers.
#
function check_lxc()
{
	incus info </dev/null | grep -q 'driver:.*lxc' || return $?
}

#
# Checks that the cluster answers with the key Incus uses, and has no errors.
#
function check_ceph()
{
	ceph --id incus -s || return $?
	[[ "$(ceph health)" != HEALTH_ERR* ]] || return 1
}

#
# Maps an RBD image with the kernel and the client.incus key, writes to it
# and reads it back. The image is unmapped and removed whether the step
# passes or not.
#
function check_rbd_map()
{
	local device status=0

	rbd --id incus unmap "$rbd_image" >/dev/null 2>&1
	rbd --id incus rm "$rbd_image" >/dev/null 2>&1
	rbd --id incus create --size 64M "$rbd_image" || return $?

	if device="$(rbd --id incus map "$rbd_image")"; then
		echo "mapped $rbd_image at $device"
		echo incusdev > "$device"
		[[ "$(head -c 8 "$device")" == "incusdev" ]] || status=1
		rbd --id incus unmap "$device" || status=1
	else
		status=1
	fi

	rbd --id incus rm "$rbd_image" >/dev/null 2>&1
	return "$status"
}

#
# Waits until Incus has the ceph pool: after a boot Incus is up before Ceph.
#
function wait_for_pool()
{
	local tries=36

	until incus storage list -f csv </dev/null |
	      grep -q '^ceph,.*,CREATED'; do
		(( tries-- > 0 )) || return 1
		sleep 5
	done
}

#
# Launches the instance with its root disk on the pool: a container, or with
# --vm a virtual machine, without secure boot since the image is unsigned.
#
function launch_instance()
{
	local options=()

	[[ "$mode" == vm ]] &&
		options=(--vm --config security.secureboot=false)
	incus delete --force "$instance" </dev/null >/dev/null 2>&1
	incus launch --quiet "$image" "$instance" "${options[@]}" \
		--profile default --profile "$profile" </dev/null || return $?
}

#
# Waits until the instance answers an exec, which for a virtual machine
# means its agent is up, and has an IPv4 address from the bridge.
#
function wait_for_instance()
{
	local tries=36

	until incus exec "$instance" -- true </dev/null 2>/dev/null &&
	      incus list "$instance" -f csv -c 4 </dev/null | grep -q eth0; do
		(( tries-- > 0 )) || return 1
		sleep 5
	done

	incus list "$instance" </dev/null
}

#
# Checks that the running instance's disk is an RBD image mapped by the
# kernel and mounted from it: a container's root, or a virtual machine's
# configuration volume beside its root disk.
#
function check_instance_rbd()
{
	rbd showmapped                                    || return $?
	rbd showmapped | grep -q "$instance"              || return $?
	mount | grep "^/dev/rbd.*/ceph/.*/$instance "     || return $?
}

#
# Checks that a URL answers with the expected HTTP status.
#
function check_url()
{
	local url="$1"
	local expected="$2"
	local status

	status="$(curl -k -s -o /dev/null --max-time 5 \
		-w '%{http_code}' "${@:3}" "$url")"
	echo "$url $status"
	[[ "$status" == "$expected" ]] || return 1
}

#
# Checks that a URL answers a request signed with the keys of a user of the
# object gateway with the expected HTTP status.
#
function check_signed()
{
	local user="$1"
	local url="$2"
	local expected="$3"
	local keys

	keys="$(radosgw-admin user info --uid "$user" 2>/dev/null |
		jq -r '.keys[0] | "\(.access_key):\(.secret_key)"')" ||
		return $?
	check_url "$url" "$expected" \
		--aws-sigv4 "aws:amz:us-east-1:s3" --user "$keys" || return $?
}

#
# Checks that the Ceph dashboard lets its admin in with the password that
# ceph.sh has set.
#
function check_dashboard_login()
{
	local password

	password="$(< /etc/ceph/dashboard.password)" || return $?
	check_url https://127.0.0.1:8444/api/auth 201 \
		-H "Accept: application/vnd.ceph.api.v1.0+json" \
		-H "Content-Type: application/json" \
		-d "{\"username\": \"admin\", \"password\": \"$password\"}" ||
		return $?
}

#
# Checks the services on their ports. With Ceph, also the dashboard's login,
# and that the RadosGW admin API lets the admin user in and refuses the S3
# user.
#
function check_services()
{
	local admin="http://127.0.0.1:8000/admin/user?uid=incusdev"

	check_url https://127.0.0.1:8443/1.0 200 || return $?
	check_url https://127.0.0.1:8443/ui/ 200 || return $?
	[[ -n "$with_ceph" ]] || return 0

	check_url https://127.0.0.1:8444/    200 || return $?
	check_dashboard_login                    || return $?

	check_signed incusdev       http://127.0.0.1:8000/ 200 || return $?
	check_signed incusdev-admin "$admin" 200               || return $?
	check_signed incusdev       "$admin" 403               || return $?
}

parse_options "$@" || exit $?

[[ $EUID -eq 0 ]] || fail "Run this as root!"
command -v incus >/dev/null || fail "Incus is not installed: run incus.sh!"
# The pool, not the ceph command: incus-source.sh installs ceph-common for
# the storage driver, without a cluster.
if incus storage show ceph </dev/null >/dev/null 2>&1; then
	with_ceph=1
	pool="ceph"
	profile="root-ceph"
elif [[ -n "$with_ceph" ]]; then
	fail "Ceph is not installed: run ceph.sh!"
fi

if [[ "$mode" == vm ]]; then
	log "Checking KVM ..."
	check_kvm || fail "No KVM here! Without --vm the test uses a container."
else
	log "Checking that Incus runs containers ..."
	check_lxc || fail "Incus has no LXC driver!"
fi
if [[ -n "$with_ceph" ]]; then
	log "Checking Ceph ..."
	check_ceph    || fail "Ceph has errors, or does not answer client.incus!"
	log "Mapping an RBD image with the kernel ..."
	check_rbd_map || fail "The kernel cannot map an RBD image!"
	log "Waiting for the ceph pool in Incus ..."
	wait_for_pool || fail "Incus does not have the ceph pool!"
fi
log "Launching $instance, a ${mode/vm/virtual machine}, on the $pool pool ..."
launch_instance    || fail "Launching $instance failed!"
wait_for_instance  || fail "$instance did not come up!"
if [[ -n "$with_ceph" ]]; then
	log "Checking the RBD images behind $instance ..."
	check_instance_rbd || fail "$instance does not run from RBD images!"
fi
incus delete --force "$instance" </dev/null ||
	fail "Deleting $instance failed!"
log "Checking the services ..."
check_services     || fail "A service does not answer!"

log "All good."
