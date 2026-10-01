name="incusdev"
root="${BASH_SOURCE[0]%/*}/.."

#
# Prints a log message.
#
function log()
{
	if [[ -t 1 ]]; then
		echo -e "\x1b[1m\x1b[32m>>>\x1b[0m \x1b[1m$1\x1b[0m"
	else
		echo ">>> $1"
	fi
}

#
# Prints an error message.
#
function error()
{
	if [[ -t 2 ]]; then
		echo -e "\x1b[1m\x1b[31m!!!\x1b[0m \x1b[1m$1\x1b[0m" >&2
	else
		echo "!!! $1" >&2
	fi
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
# Tells whether the Lima VM exists.
#
function vm_exists()
{
	limactl list --quiet 2>/dev/null | grep -qx "$name"
}

#
# Tells whether the Lima VM is running.
#
function vm_runs()
{
	[[ "$(limactl list --format '{{.Status}}' "$name" 2>/dev/null)" == \
		"Running" ]]
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
# Prints the services that the VM offers on this computer, and says for each
# whether it answers. The ports are those of portForwards in lima.yaml. Any
# HTTP status counts as an answer: the S3 API says 403 without a key.
#
function print_services()
{
	local service url hint state

	log "Services on this computer:"
	while read -r service url hint; do
		state="down"
		curl -k -s -o /dev/null --max-time 3 "$url" && state="up"
		printf "  %-15s %-27s %-5s %s\n" \
			"${service//_/ }" "$url" "$state" "${hint//_/ }"
	done <<EOF
Incus_API https://127.0.0.1:8443 task_incus-dash_adds_the_incus_remote
Incus_web_UI https://127.0.0.1:8443/ui/ task_incus-dash
Ceph_dashboard https://127.0.0.1:8444 task_ceph-dash
S3_API http://127.0.0.1:8000 task_s3-credentials
EOF
	echo "  How to log in to each: docs/access.md"
}
