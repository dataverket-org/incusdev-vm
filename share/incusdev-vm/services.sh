#
# Prints a row of the tables that "task status" shows: a name, an address,
# up or down, and a hint.
#
function print_row()
{
	printf "  %-18s %-27s %-5s %s\n" "$1" "$2" "$3" "$4"
}

#
# Prints the services that the VM offers on this computer, one per line: a
# name, a URL and a hint, with _ for space. Incus, and Ceph's when the VM
# has Ceph. The ports are those of portForwards in lima.yaml.
#
function services()
{
	cat <<EOF
Incus_API https://127.0.0.1:26870 task_dashboard_adds_the_incus_remote
Incus_web_UI https://127.0.0.1:26870/ui/ task_dashboard_--_incus
EOF
	vm_has_ceph || return 0
	cat <<EOF
Ceph_dashboard https://127.0.0.1:26871 task_dashboard_--_ceph
S3_API http://127.0.0.1:26872 task_s3-credentials
RadosGW_admin_API http://127.0.0.1:26872/admin task_s3-credentials_--_admin
EOF
}

#
# Waits until the services answer on this computer.
#
function wait_for_services()
{
	local tries=12 service url hint

	while read -r service url hint; do
		until curl -k -s -o /dev/null --max-time 3 "$url"; do
			(( tries-- > 0 )) || return 1
			sleep 5
		done
	done < <(services)
}

#
# Prints the services that the VM offers on this computer, and says for each
# whether it answers. Any HTTP status counts as an answer: the S3 API says
# 403 without a key.
#
function print_services()
{
	local service url hint state

	log "Services on this computer:"
	while read -r service url hint; do
		state="down"
		curl -k -s -o /dev/null --max-time 3 "$url" && state="up"
		print_row "${service//_/ }" "$url" "$state" "${hint//_/ }"
	done < <(services)
	echo "  How to log in to each: docs/access.md"
}
