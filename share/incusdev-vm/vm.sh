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
# Runs a command inside the ToR's VM, with stdin closed.
#
function tor_guest()
{
	limactl shell --workdir / "$tor" "$@" </dev/null
}
