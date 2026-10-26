# macOS's /bin/bash is 3.2, and a PATH without Homebrew first finds it.
if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 502 )); then
	for bash in ${HOMEBREW_PREFIX:+"$HOMEBREW_PREFIX/bin/bash"} \
	            /opt/homebrew/bin/bash /usr/local/bin/bash \
	            /home/linuxbrew/.linuxbrew/bin/bash; do
		[[ -f "$0" && -x "$bash" ]] || continue
		"$bash" -c '(( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] >= 502 ))' &&
			exec "$bash" "$0" "$@"
	done
	echo "${0##*/}: needs bash 5.2 or newer; brew bundle installs bash 5" >&2
	exit 1
fi

name="incusdev"
share="${BASH_SOURCE[0]%/*}"
root="$share/../.."

# The stopped copy of the freshly installed VM that "task reset" starts from.
base="$name-base"

# The simulated top-of-rack switch, a VM of its own on macOS: see tor.yaml.
tor="$name-tor"

# The point-to-point link between the two, laid by "task p2p": a pair of feth
# interfaces joined to each other, and a Lima network bridged on each end.
# Lima gives each VM its end as lima0.
p2p_feth="feth4"
p2p_feth_tor="feth5"
p2p_network="$name-p2p"
p2p_network_tor="$name-p2p-tor"
lima_networks="${LIMA_HOME:-$HOME/.lima}/_config/networks.yaml"

# An Incus source tree on this computer. "task up" mounts it into a new VM,
# writable and at the same path: see "Work on Incus itself" in README.md.
incus_src="${INCUS_SRC:-}"

# Where "task up" keeps the output and the process ID of its background work.
up_log="${TMPDIR:-/tmp}/$name-up.log"
up_pid="${TMPDIR:-/tmp}/$name-up.pid"

source "$share/logging.sh"  || return $?
source "$share/vm.sh"       || return $?
source "$share/services.sh" || return $?
source "$share/tor.sh"      || return $?
