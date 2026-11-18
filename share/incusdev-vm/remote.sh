#
# Prints a one-time token for a client of the given name, after removing the
# certificates and unused tokens that the name already has in Incus. So a
# remote that is set up again replaces its old entry.
#
function trust_token()
{
	local client="$1"

	# shellcheck disable=SC2016
	guest sudo bash -c '
		incus config trust list -f json |
		jq -r --arg name "$1" \
			".[] | select(.name == \$name) | .fingerprint" |
		while read -r fingerprint; do
			incus config trust remove "$fingerprint" || exit 1
		done
		incus config trust revoke-token "$1" >/dev/null 2>&1
		incus config trust add --quiet "$1"
	' bash "$client" || return $?
}

#
# Makes sure that the incus client on this computer has a working remote for
# the VM, named incusdev. These functions own that remote: a remote that
# does not answer, as after "task destroy", is replaced. Your default remote
# is only changed when it is the one being replaced.
#
function ensure_remote()
{
	local token default

	incus query "$name:/1.0/instances" >/dev/null 2>&1 </dev/null && return

	if incus remote list -f csv </dev/null | grep -q "^${name}[ ,]"; then
		log "Replacing the incus remote $name ..."
		default="$(incus remote get-default </dev/null)"
		if [[ "$default" == "$name" ]]; then
			incus remote switch local </dev/null || return $?
		fi
		incus remote remove "$name" </dev/null || return $?
	else
		log "Adding the incus remote $name ..."
	fi

	token="$(trust_token "$name-host")" || return $?
	incus remote add "$name" https://127.0.0.1:26870 --accept-certificate \
		--token "$token" </dev/null || return $?
}

#
# Removes the remote, and its certificate in the VM when the VM runs. Your
# default remote goes back to local when it was this one.
#
function remove_remote()
{
	if incus remote list -f csv </dev/null | grep -q "^${name}[ ,]"; then
		if [[ "$(incus remote get-default </dev/null)" == "$name" ]]; then
			incus remote switch local </dev/null || return $?
		fi
		incus remote remove "$name" </dev/null || return $?
	fi

	vm_runs || return 0
	# shellcheck disable=SC2016
	guest sudo bash -c '
		incus config trust list -f json |
		jq -r --arg name "$1" \
			".[] | select(.name == \$name) | .fingerprint" |
		while read -r fingerprint; do
			incus config trust remove "$fingerprint" || exit 1
		done
		incus config trust revoke-token "$1" >/dev/null 2>&1
		exit 0
	' bash "$name-host" || return $?
}
