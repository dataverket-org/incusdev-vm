name="incusdev"
root="${BASH_SOURCE[0]%/*}/.."

# Where "task up" keeps the output and the process ID of its background work.
up_log="${TMPDIR:-/tmp}/$name-up.log"
up_pid="${TMPDIR:-/tmp}/$name-up.pid"

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
# Waits until the three service ports answer on this computer.
#
function wait_for_services()
{
	local tries=12 url

	for url in https://127.0.0.1:8443 https://127.0.0.1:8444 \
	           http://127.0.0.1:8000; do
		until curl -k -s -o /dev/null --max-time 3 "$url"; do
			(( tries-- > 0 )) || return 1
			sleep 5
		done
	done
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
		printf "  %-18s %-27s %-5s %s\n" \
			"${service//_/ }" "$url" "$state" "${hint//_/ }"
	done <<EOF
Incus_API https://127.0.0.1:8443 task_dashboard_adds_the_incus_remote
Incus_web_UI https://127.0.0.1:8443/ui/ task_dashboard_--_incus
Ceph_dashboard https://127.0.0.1:8444 task_dashboard_--_ceph
S3_API http://127.0.0.1:8000 task_s3-credentials
RadosGW_admin_API http://127.0.0.1:8000/admin task_s3-credentials_--_admin
EOF
	echo "  How to log in to each: docs/access.md"
}
