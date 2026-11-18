name="incusdev"
share="${BASH_SOURCE[0]%/*}"
root="$share/../.."

# The stopped copy of the freshly installed VM that "task reset" starts from.
base="$name-base"

# The simulated top-of-rack switch of a VM made with "task up -- --bgp": a
# network namespace in the VM, the VM's end of the link to it, and the
# control socket of the Bird in it. provision/tor.sh makes them.
tor_netns="incusdev-tor"
tor_link="incusdev-tor0"
tor_socket="/run/incusdev-tor/bird.ctl"

# An Incus source tree on this computer. "task up" mounts it into a new VM,
# writable and at the same path: see docs/incus-development.md.
incus_src="${INCUS_SRC:-}"

# Where "task up" keeps the output and the process ID of its background work.
up_log="${TMPDIR:-/tmp}/$name-up.log"
up_pid="${TMPDIR:-/tmp}/$name-up.pid"

source "$share/logging.sh"  || return $?
source "$share/vm.sh"       || return $?
source "$share/services.sh" || return $?
source "$share/tor.sh"      || return $?
