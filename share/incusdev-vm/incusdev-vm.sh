name="incusdev"
share="${BASH_SOURCE[0]%/*}"
root="$share/../.."

# The stopped copy of the freshly installed VM that "task reset" starts from.
base="$name-base"

# The simulated top-of-rack switch, a VM of its own: see tor.yaml.
tor="$name-tor"

# The link between the two, laid by "task p2p". On macOS a pair of feth
# interfaces joined to each other, and a Lima network bridged on each end; on
# Linux a bridge without addresses, and one Lima network on it for both VMs.
# Lima gives each VM the link as lima0.
p2p_feth="feth4"
p2p_feth_tor="feth5"
p2p_bridge="$name-p2p"
p2p_network="$name-p2p"
case "$(uname -s)" in
	Linux)	p2p_network_tor="$p2p_network" ;;
	*)	p2p_network_tor="$name-p2p-tor" ;;
esac
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
