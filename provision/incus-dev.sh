#!/usr/bin/env bash
#
# Builds Incus from source and puts it in place of the packaged daemon,
# client and agent. Run it as root, after incus.sh, and again after each
# change to the source:
#
#   sudo provision/incus-dev.sh
#
# The build replaces the files in /opt/incus that the Zabbly package installed,
# and the package's wrapper starts it with the package's QEMU, LXC and web UI.
# A newer daemon may upgrade the database past what the package can read: in
# the VM, "task reset" goes back. Settings, from the environment:
#
#   INCUS_SRC   the source tree; default a clone of the main branch in
#               /usr/local/src/incus, updated on each run
#

export DEBIAN_FRONTEND=noninteractive
export HOME=/root

# Debian's Go is older than what Incus needs; auto has it fetch that version.
# The source can belong to another user, which git would refuse to stamp.
export GOTOOLCHAIN=auto GOFLAGS=-buildvcs=false

# The clone of the main branch, where INCUS_SRC is not given.
clone="/usr/local/src/incus"
src="${INCUS_SRC:-$clone}"

# The output of the last build. Its end is printed when the build fails.
build_log="/var/log/incus-dev-build.log"

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
# Installs the compiler and the headers that the build needs.
#
function install_build_deps()
{
	dpkg -s lxc-dev libcowsql-dev >/dev/null 2>&1 && return

	log "Installing the build dependencies ..."
	apt-get -qq update || return $?
	apt-get -qq install -y build-essential git golang-go pkg-config \
		lxc-dev libcowsql-dev libraft-dev libsqlite3-dev libacl1-dev \
		libcap-dev libudev-dev libuv1-dev >/dev/null || return $?
}

#
# Checks that the machine has the memory to link incusd: 4 GiB, less what the
# kernel keeps for itself.
#
function check_memory()
{
	local kib

	kib="$(awk '/^MemTotal/ { print $2 }' /proc/meminfo)" || return $?
	(( kib > 3500000 )) || return 1
}

#
# Clones the main branch, or updates the clone, unless INCUS_SRC is given.
# Either way the source must be there at the end.
#
function fetch_source()
{
	local url="https://github.com/lxc/incus"

	if [[ "$src" == "$clone" && -d "$src/.git" ]]; then
		git -C "$src" pull -q --ff-only || return $?
	elif [[ "$src" == "$clone" ]]; then
		log "Cloning Incus into $src ..."
		git clone -q --depth 1 "$url" "$src" || return $?
	fi

	[[ -f "$src/go.mod" ]] || return 1
}

#
# Builds Incus, puts it in place of the packaged one and restarts the daemon.
# Instances keep running through the restart.
#
function build_and_install()
{
	log "Building Incus in $src ..."
	if ! make -C "$src" > "$build_log" 2>&1; then
		tail -n 30 "$build_log" >&2
		return 1
	fi

	install -m 755 "$HOME/go/bin/incusd" "$HOME/go/bin/incus" \
		/opt/incus/bin/ || return $?
	install -m 755 "$HOME/go/bin/incus-agent" \
		"/opt/incus/agent/incus-agent.linux.$(uname -m)" || return $?

	systemctl restart incus             || return $?
	incus admin waitready --timeout 120 || return $?
}

[[ $EUID -eq 0 ]]              || fail "Run this as root!"
[[ -x /opt/incus/bin/incusd ]] || fail "Run provision/incus.sh first!"
check_memory                   || fail "The build needs 4 GiB of memory!"
install_build_deps             || fail "Installing build dependencies failed!"
fetch_source                   || fail "No Incus source in $src!"
build_and_install              || fail "Building or installing Incus failed!"

version="$(incus version | awk '/^Server/ { print $3 }')"
log "Incus $version from $src is running."
