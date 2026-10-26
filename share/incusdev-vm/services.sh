#
# Waits until the three service ports answer on this computer.
#
function wait_for_services()
{
	local tries=12 url

	for url in https://127.0.0.1:26870 https://127.0.0.1:26871 \
	           http://127.0.0.1:26872; do
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
Incus_API https://127.0.0.1:26870 task_dashboard_adds_the_incus_remote
Incus_web_UI https://127.0.0.1:26870/ui/ task_dashboard_--_incus
Ceph_dashboard https://127.0.0.1:26871 task_dashboard_--_ceph
S3_API http://127.0.0.1:26872 task_s3-credentials
RadosGW_admin_API http://127.0.0.1:26872/admin task_s3-credentials_--_admin
EOF
	echo "  How to log in to each: docs/access.md"
}
