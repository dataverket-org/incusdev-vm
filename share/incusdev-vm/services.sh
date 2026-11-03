#
# Prints the URLs of the services on this computer: the Incus API, and the
# Ceph dashboard and the S3 API on a host with Ceph.
#
function service_urls()
{
	echo "https://127.0.0.1:$incus_port"
	[[ -n "$with_ceph" ]] || return 0
	echo "https://127.0.0.1:$ceph_port"
	echo "http://127.0.0.1:$s3_port"
}

#
# Waits until the service ports answer on this computer.
#
function wait_for_services()
{
	local tries=12 url

	for url in $(service_urls); do
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
	local service url hint state services

	services="Incus_API https://127.0.0.1:$incus_port task_dashboard_adds_the_incus_remote
Incus_web_UI https://127.0.0.1:$incus_port/ui/ task_dashboard_--_incus"
	[[ -n "$with_ceph" ]] && services+="
Ceph_dashboard https://127.0.0.1:$ceph_port task_dashboard_--_ceph
S3_API http://127.0.0.1:$s3_port task_s3-credentials
RadosGW_admin_API http://127.0.0.1:$s3_port/admin task_s3-credentials_--_admin"

	log "Services on this computer:"
	while read -r service url hint; do
		state="down"
		curl -k -s -o /dev/null --max-time 3 "$url" && state="up"
		printf "  %-18s %-27s %-5s %s\n" \
			"${service//_/ }" "$url" "$state" "${hint//_/ }"
	done <<< "$services"
	echo "  How to log in to each: docs/access.md"
}
