#!/usr/bin/env bash
#
# Tests the testbed end to end, on the machine it is installed on. Run it as
# root, after incus.sh and ceph.sh:
#
#   sudo provision/check.sh
#
# It checks KVM, Ceph, the kernel mapping an RBD image, an Incus
# virtual machine that boots from the ceph pool and gets an address, and the
# three service ports. It removes what it makes. It force-deletes an instance
# named incusdev-check, so do not use that name yourself.
#

export HOME=/root

instance="incusdev-check"
image="images:alpine/3.21"
rbd_image="incus/incusdev-check"

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
# Checks that the machine has KVM and that Incus found QEMU.
#
function check_kvm()
{
	[[ -e /dev/kvm ]] || return 1
	incus info </dev/null | grep -q 'driver:.*qemu' || return $?
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
# Waits until Incus has the ceph pool. After a boot, Incus is up before Ceph
# and takes a minute or two to find it.
#
function wait_for_pool()
{
	local tries=36

	until incus storage list -f csv </dev/null | grep -q '^ceph,.*,CREATED'; do
		(( tries-- > 0 )) || return 1
		sleep 5
	done
}

#
# Launches a virtual machine with its root disk on Ceph.
#
function launch_instance()
{
	incus delete --force "$instance" </dev/null >/dev/null 2>&1
	incus launch --quiet "$image" "$instance" --vm \
		--profile default --profile root-ceph \
		--config security.secureboot=false </dev/null || return $?
}

#
# Waits until the agent inside the virtual machine answers and the machine
# has an IPv4 address from the bridge.
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
# Checks that the running virtual machine's disks are RBD images mapped by
# the kernel, and that its configuration volume is mounted from one.
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
		jq -r '.keys[0] | "\(.access_key):\(.secret_key)"')" || return $?
	check_url "$url" "$expected" \
		--aws-sigv4 "aws:amz:us-east-1:s3" --user "$keys" || return $?
}

#
# Checks the services: the Incus API and web UI, the Ceph dashboard, and the
# object gateway. There the S3 user lists its buckets, the admin user reads a
# user through the RadosGW admin API, and the S3 user is refused the same.
#
function check_services()
{
	local admin="http://127.0.0.1:8000/admin/user?uid=incusdev"

	check_url https://127.0.0.1:8443/1.0 200 || return $?
	check_url https://127.0.0.1:8443/ui/ 200 || return $?
	check_url https://127.0.0.1:8444/    200 || return $?

	check_signed incusdev       http://127.0.0.1:8000/ 200 || return $?
	check_signed incusdev-admin "$admin" 200               || return $?
	check_signed incusdev       "$admin" 403               || return $?
}

[[ $EUID -eq 0 ]] || fail "Run this as root!"
command -v incus >/dev/null || fail "Incus is not installed: run incus.sh!"
command -v ceph >/dev/null  || fail "Ceph is not installed: run ceph.sh!"

log "Checking KVM ..."
check_kvm          || fail "No KVM here: Incus cannot run virtual machines!"
log "Checking Ceph ..."
check_ceph         || fail "Ceph does not answer client.incus, or has errors!"
log "Mapping an RBD image with the kernel ..."
check_rbd_map      || fail "The kernel cannot map an RBD image!"
log "Waiting for the ceph pool in Incus ..."
wait_for_pool      || fail "Incus does not have the ceph pool!"
log "Launching $instance from $image on the ceph pool ..."
launch_instance    || fail "Launching $instance failed!"
wait_for_instance  || fail "$instance did not come up!"
log "Checking the RBD images behind $instance ..."
check_instance_rbd || fail "$instance does not run from mapped RBD images!"
incus delete --force "$instance" </dev/null ||
	fail "Deleting $instance failed!"
log "Checking the services ..."
check_services     || fail "A service does not answer!"

log "All good."
