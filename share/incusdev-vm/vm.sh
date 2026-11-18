#
# Tells whether a Lima VM exists, incusdev unless another is named.
#
function vm_exists()
{
	local vm="${1:-$name}"

	limactl list --quiet 2>/dev/null | grep -qx "$vm"
}

#
# Tells whether a Lima VM is running, incusdev unless another is named.
#
function vm_runs()
{
	local vm="${1:-$name}"

	[[ "$(limactl list --format '{{.Status}}' "$vm" 2>/dev/null)" == \
		"Running" ]]
}

#
# Tells whether the VM was made with "task up -- --ceph". Lima keeps the
# setting, so a stopped VM answers too. A VM made before the setting existed
# has none, and has Ceph.
#
function vm_has_ceph()
{
	vm_exists || return 1
	[[ "$(limactl list --format '{{.Param.CEPH}}' "$name" 2>/dev/null)" != \
		"off" ]]
}

#
# Tells whether the VM was made with "task up -- --source".
#
function vm_has_source()
{
	[[ "$(limactl list --format '{{.Param.SOURCE}}' "$name" 2>/dev/null)" == \
		"on" ]]
}

#
# Tells whether the VM was made with "task up -- --bgp". Lima keeps the
# setting, so a stopped VM answers too.
#
function vm_has_bgp()
{
	[[ "$(limactl list --format '{{.Param.BGP}}' "$name" 2>/dev/null)" == \
		"on" ]]
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
# Checks that the VM is running and builds Incus from source.
#
function check_source()
{
	check_running || return $?
	vm_has_source && return

	error "$name runs the packaged Incus! Run: task destroy,"
	error "task up -- --source"
	return 1
}

#
# Checks that the VM is running and was made with Ceph.
#
function check_ceph()
{
	check_running || return $?
	vm_has_ceph && return

	error "$name has no Ceph! Run: task destroy, task up -- --ceph"
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
