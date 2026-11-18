#!/usr/bin/env bash
#
# Builds Incus from source, the way the Incus documentation describes, and
# runs the build in place of the packaged incusd. Run it as root, after
# incus.sh:
#
#   sudo provision/incus-source.sh
#
# The package stays for everything but incusd: QEMU, the firmware, lxcfs,
# the agents for other systems, the web UI and the LXC hooks. Drop-ins for
# incus.service and incus-startup.service start the build instead, with the
# package's wrappers given /opt/incusdev in front of /opt/incus. Removing
# them, with --package, brings the package's incusd back.
#
# Safe to run again; Lima runs it on every start, see lima.yaml, and it does
# nothing there unless the VM was made with "task up -- --source". Once
# there is a build it only builds again with --build, which "task build"
# gives. Settings, from the environment:
#
#   INCUS_SRC       a checkout to build, as it is; without it a clone of
#                   INCUS_GIT, in the user's home as ~/incus
#   INCUS_GIT       the repository to clone, default
#                   https://github.com/lxc/incus
#   INCUS_REF       what the clone checks out: a branch, tag, commit or
#                   refs/pull/N/head; default main on the first clone, and
#                   what is checked out after that
#   INCUSDEV_USER   the user that builds
#

export DEBIAN_FRONTEND=noninteractive
export HOME=/root

src="${INCUS_SRC:-${PARAM_INCUS_SRC:-}}"
repository="${INCUS_GIT:-${PARAM_INCUS_GIT:-}}"
repository="${repository:-https://github.com/lxc/incus}"
ref="${INCUS_REF:-${PARAM_INCUS_REF:-}}"
# INCUSDEV_USER, else who called sudo, else the first user with a home
# directory in /home.
user="${INCUSDEV_USER:-${SUDO_USER:-$(getent passwd |
	awk -F: '$6 ~ /^\/home\// { print $1; exit }')}}"
home="$(getent passwd "$user" | cut -d: -f6)"

# The Delve that "task debug" attaches; Renovate raises it.
delve_version="v1.27.2"

prefix="/opt/incusdev"
build_info="$prefix/build-info"
build_log="$prefix/build.log"
# There after --package, so that a restart keeps the package's incusd.
use_package="$prefix/use-package"
units="/etc/systemd/system"
dropin="incusdev-source.conf"

# Upstream's build and runtime packages for Debian, the test suite's, and
# ceph-common for the ceph storage driver.
packages=(acl attr autoconf automake dnsmasq-base git golang-go libacl1-dev
	libcap-dev liblxc1 lxc-dev libsqlite3-dev libtool libudev-dev
	liblz4-dev libuv1-dev make pkg-config rsync squashfs-tools tar tcl
	xz-utils nftables busybox-static curl gettext jq sqlite3 socat
	bind9-dnsutils ceph-common)

build=""
debug=""
package=""

#
# Prints a log message.
#
function log()
{
	echo ">>> $1"
}

#
# Prints an error message.
#
function error()
{
	echo "!!! $1" >&2
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
# Prints usage information for incus-source.sh.
#
function usage()
{
	cat <<USAGE
usage: incus-source.sh [OPTIONS]

Options:

	    --build		Builds again, also where a build is running
	    --debug		With --build: a build without optimizations,
				for Delve
	    --package		Goes back to the package's incusd
	-h, --help		Prints this message

USAGE
}

#
# Parses command-line options for incus-source.sh.
#
function parse_options()
{
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--build)
				build=1
				shift
				;;
			--debug)
				debug=1
				shift
				;;
			--package)
				package=1
				shift
				;;
			-h|--help)
				usage
				exit
				;;
			*)
				echo "incus-source.sh: unrecognized option $1" >&2
				return 1
				;;
		esac
	done
}

#
# Runs a command as $user in the source tree, with the Go that go.mod asks
# for and the environment that "make deps" prints. Go's temporary files go
# to the disk: /tmp is a tmpfs of half the memory, which the linker fills
# in a VM of 2 GiB.
#
function as_user()
{
	local deps="$home/go/deps"

	sudo -u "$user" -H mkdir -p "$home/.cache/go-tmp" || return $?
	sudo -u "$user" -H env -C "$src" \
		GOTOOLCHAIN=auto GOTMPDIR="$home/.cache/go-tmp" \
		CGO_CFLAGS="-I$deps/raft/include/ -I$deps/cowsql/include/" \
		CGO_LDFLAGS="-L$deps/raft/.libs -L$deps/cowsql/.libs/" \
		CGO_LDFLAGS_ALLOW="(-Wl,-wrap,pthread_create)|(-Wl,-z,now)" \
		LD_LIBRARY_PATH="$deps/raft/.libs/:$deps/cowsql/.libs/" \
		"$@"
}

#
# Runs apt-get. It waits for another apt or dpkg instead of failing on the
# lock.
#
function apt_get()
{
	local tries=60

	while pgrep -x "apt|apt-get|dpkg" >/dev/null ||
	      pgrep -f "bin/unattended-upgrade" >/dev/null; do
		(( tries-- > 0 )) || break
		sleep 5
	done

	apt-get -q -o DPkg::Lock::Timeout=300 "$@" || return $?
}

#
# Installs the packages, and masks Debian's LXC services, as the Incus CI
# does: they would add a bridge of their own.
#
function install_packages()
{
	local unit

	if ! dpkg-query -W "${packages[@]}" >/dev/null 2>&1; then
		log "Installing what Incus needs to build ..."
		apt_get update                        || return $?
		apt_get install -y "${packages[@]}"   || return $?
	fi

	for unit in lxc.service lxc-net.service; do
		[[ "$(systemctl is-enabled "$unit" 2>/dev/null)" == masked ]] &&
			continue
		systemctl list-unit-files "$unit" >/dev/null 2>&1 || continue
		systemctl mask --now "$unit" >/dev/null 2>&1 || return $?
	done
}

#
# Gets the source: the checkout in INCUS_SRC, or a clone, checked out at
# INCUS_REF when that is given.
#
function get_source()
{
	if [[ -n "$PARAM_INCUS_SRC$INCUS_SRC" ]]; then
		[[ -d "$src/.git" || -f "$src/Makefile" ]] || {
			error "$src is not an Incus source tree, or not mounted!"
			return 1
		}
		[[ -z "$ref" ]] || {
			error "INCUS_REF does not go with INCUS_SRC!"
			return 1
		}
		return
	fi

	src="$home/incus"
	if [[ ! -d "$src/.git" ]]; then
		log "Cloning $repository ..."
		sudo -u "$user" -H git clone -q "$repository" "$src" ||
			return $?
		ref="${ref:-main}"
	fi
	[[ -n "$ref" ]] || return 0

	log "Checking out $ref ..."
	as_user git fetch -q origin "$ref"           || return $?
	as_user git checkout -q --detach FETCH_HEAD  || return $?
}

#
# Runs make as $user, into the build log. When it fails, the end of the log
# says why.
#
function run_make()
{
	if ! as_user make "$@" >> "$build_log" 2>&1; then
		tail -n 20 "$build_log" >&2
		return 1
	fi
}

#
# Builds Incus: raft and cowsql with "make deps" when they are missing, then
# "make", or "make debug" without optimizations.
#
function build_incus()
{
	mkdir -p "$prefix"  || return $?
	: > "$build_log"    || return $?

	if [[ ! -e "$home/go/deps/cowsql/.libs/libcowsql.so" ]]; then
		log "Building raft and cowsql ..."
		run_make deps || return $?
	fi

	if [[ -n "$debug" ]]; then
		log "Building Incus $(describe), for debugging ..."
		# The Makefile puts DEBUG into a shell command as it is.
		run_make debug DEBUG='-gcflags=all="-N -l"' || return $?
	else
		log "Building Incus $(describe) ..."
		run_make || return $?
	fi
}

#
# Prints the version of the source, as git describes it.
#
function describe()
{
	# Without the index refresh that --dirty writes: on a mounted checkout
	# that write can fail while the mount catches up with an edit.
	as_user git --no-optional-locks describe --always --dirty 2>/dev/null ||
		echo "unknown"
}

#
# Installs Delve, at the version above.
#
function install_delve()
{
	local go_version

	[[ "$("$prefix/bin/dlv" version 2>/dev/null |
		awk '/^Version:/ { print "v" $2 }')" == "$delve_version" ]] &&
		return

	log "Installing Delve $delve_version ..."
	# With the Go that Incus builds with, not one more toolchain.
	go_version="$(as_user go env GOVERSION)" || return $?
	as_user env GOTOOLCHAIN="$go_version" go install \
		"github.com/go-delve/delve/cmd/dlv@$delve_version" || return $?
	mkdir -p "$prefix/bin"                                 || return $?
	install -m 755 "$home/go/bin/dlv" "$prefix/bin/dlv"    || return $?
}

#
# Installs a file in place of a running one: a new file renamed over it.
#
function put()
{
	install -m "$1" "$2" "$3.new" && mv -f "$3.new" "$3"
}

#
# Copies the build to /opt/incusdev: the binaries, raft and cowsql, and the
# package's agents with the build's for this architecture.
#
function install_build()
{
	local bin

	mkdir -p "$prefix/bin" "$prefix/lib" "$prefix/agent" || return $?
	for bin in incusd incus incus-agent incus-migrate; do
		put 755 "$home/go/bin/$bin" "$prefix/bin/$bin" || return $?
	done
	cp -a "$home/go/deps/raft/.libs/"libraft.so* \
	      "$home/go/deps/cowsql/.libs/"libcowsql.so* "$prefix/lib/" ||
		return $?

	cp -a /opt/incus/agent/. "$prefix/agent/" || return $?
	put 755 "$home/go/bin/incus-agent" \
		"$prefix/agent/incus-agent.linux.$(uname -m)" || return $?

	printf 'version=%s\ndebug=%s\n' "$(describe)" "${debug:-0}" \
		> "$build_info" || return $?
}

#
# Writes one of the package's wrappers with /opt/incusdev in front of
# /opt/incus, and fails when the package's has changed so that nothing
# would point at the build.
#
function wrap()
{
	local from="$1"
	local to="$2"

	sed -e "s#^export PATH=/opt/incus/bin/#export PATH=$prefix/bin/:/opt/incus/bin/#" \
	    -e "s#^export LD_LIBRARY_PATH=/opt/incus/lib/#export LD_LIBRARY_PATH=$prefix/lib/:/opt/incus/lib/#" \
	    -e "s#^export INCUS_AGENT_PATH=.*#export INCUS_AGENT_PATH=$prefix/agent/#" \
	    "$from" > "$to.new" || return $?
	chmod 755 "$to.new" || return $?

	if ! grep -q "^export PATH=$prefix/bin/" "$to.new"; then
		rm -f "$to.new"
		error "$from no longer looks as expected!"
		return 1
	fi
	mv -f "$to.new" "$to" || return $?
}

#
# Writes a drop-in that starts a unit's commands from /opt/incusdev in
# place of the package's.
#
function write_dropin()
{
	local unit="$1"
	local commands

	commands="$(grep -E '^Exec' "/usr/lib/systemd/system/$unit")" ||
		return $?
	mkdir -p "$units/$unit.d" || return $?
	{
		echo "# Written by provision/incus-source.sh."
		echo "[Service]"
		sed -E 's/^(Exec[A-Za-z]*)=.*/\1=/' <<< "$commands" | sort -u
		echo "${commands//\/opt\/incus\/lib\/systemd\//$prefix/libexec/}"
	} > "$units/$unit.d/$dropin" || return 1
}

#
# Points the services and the client at the build, and restarts incusd.
# Running instances stay up.
#
function use_build()
{
	mkdir -p "$prefix/libexec" || return $?
	wrap /opt/incus/lib/systemd/incusd "$prefix/libexec/incusd" ||
		return $?
	wrap /opt/incus/lib/systemd/incus-startup \
		"$prefix/libexec/incus-startup" || return $?
	wrap /usr/bin/incus /usr/local/bin/incus || return $?

	write_dropin incus.service         || return $?
	write_dropin incus-startup.service || return $?
	systemctl daemon-reload            || return $?
	stop_delve

	log "Starting incusd from the build ..."
	systemctl restart incus             || return $?
	incus admin waitready --timeout 120 || return $?
}

#
# Stops "task debug"'s Delve, which detaches it, before incusd restarts.
#
function stop_delve()
{
	systemctl stop incusdev-dlv.service >/dev/null 2>&1
}

#
# Tells whether the services run the build.
#
function uses_build()
{
	[[ -f "$units/incus.service.d/$dropin" ]]
}

#
# Goes back to the package's incusd. When the build has changed the
# database so that the package's incusd does not start, as upstream warns
# for a downgrade, it goes back to the build and says so.
#
function use_package()
{
	uses_build || return 0

	log "Starting the package's incusd ..."
	stop_delve
	rm -f "$units/incus.service.d/$dropin" \
	      "$units/incus-startup.service.d/$dropin" \
	      /usr/local/bin/incus || return $?
	systemctl daemon-reload || return $?

	if systemctl restart incus &&
	   incus admin waitready --timeout 60 2>/dev/null; then
		return
	fi

	error "The package's incusd does not start: the build changed the"
	error "database, and a downgrade needs its backup. Back to the build."
	use_build
	return 1
}

#
# Prints the version of the build that runs, as it was described when built.
#
function build_version()
{
	sed -n 's/^version=//p' "$build_info" 2>/dev/null
}

parse_options "$@" || exit $?

# A VM made without "task up -- --source": Lima says so with PARAM_SOURCE=off.
[[ "${PARAM_SOURCE:-on}" == "on" ]] || exit 0
[[ $EUID -eq 0 ]]  || fail "Run this as root!"
[[ -n "$home" ]]   || fail "No user to build as. Set INCUSDEV_USER!"
command -v incus >/dev/null || fail "Incus is not installed: run incus.sh!"

if [[ -n "$package" ]]; then
	use_package || exit $?
	touch "$use_package" || exit $?
	log "Incus runs from the package: $(incus version |
		sed -n 's/^Server version: //p')."
	exit
fi

if [[ -z "$build" && -f "$use_package" ]]; then
	log "Incus runs from the package, as asked: task build goes back."
	exit
fi

if [[ -z "$build" && -x "$prefix/bin/incusd" ]] && uses_build; then
	log "Incus runs from the build: $(build_version)."
	exit
fi

install_packages || fail "Installing what Incus needs to build failed!"
get_source       || fail "Getting the Incus source failed!"
build_incus      || fail "Building Incus failed!"
install_delve    || fail "Installing Delve failed!"
install_build    || fail "Installing the build failed!"
if ! use_build; then
	error "Starting incusd from the build failed! See /var/log/incus/incusd.log."
	fail "To go back: task build -- --package, or task reset."
fi
rm -f "$use_package"

log "Incus runs from the build: $(describe)$([[ -n "$debug" ]] && echo ", for debugging")."
