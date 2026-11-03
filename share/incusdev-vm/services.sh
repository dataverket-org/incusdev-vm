#
# Prints a service per line: its name, its URL and the task that uses it,
# with _ for spaces.
#
function service_rows()
{
	local incus="https://127.0.0.1:$incus_port"
	local ceph="https://127.0.0.1:$ceph_port"
	local s3="http://127.0.0.1:$s3_port"

	echo "Incus_API $incus task_dashboard_adds_the_incus_remote"
	echo "Incus_web_UI $incus/ui/ task_dashboard_--_incus"
	[[ -n "$with_ceph" ]] || return 0
	echo "Ceph_dashboard $ceph task_dashboard_--_ceph"
	echo "S3_API $s3 task_s3-credentials"
	echo "RadosGW_admin_API $s3/admin task_s3-credentials_--_admin"
}

#
# Prints a row of the tables that task status shows: a name, an address, up
# or down, and a hint.
#
function print_row()
{
	printf "  %-18s %-27s %-5s %s\n" "$1" "$2" "$3" "$4"
}

#
# Waits until the service ports answer on this computer.
#
function wait_for_services()
{
	local tries=12 url

	for url in $(service_rows | awk '{ print $2 }'); do
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
		print_row "${service//_/ }" "$url" "$state" "${hint//_/ }"
	done <<< "$(service_rows)"
	echo "  How to log in to each: docs/access.md"
}
