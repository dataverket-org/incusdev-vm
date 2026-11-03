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

share="${BASH_SOURCE[0]%/*}"
root="$share/../.."

# The Incus host the tasks work on: incusdev, or with INCUSDEV_HOST=2
# incusdev2, a second Incus beside it, standalone and not in a cluster with
# it. incusdev2 has no Ceph, and needs the ToR: both hosts peer with it on the
# same link, and reach each other through it. Each host has its own bridge
# subnet, AS, range for routed NICs and ports on this computer; "task up"
# hands them to Lima, see param in lima.yaml.
case "${INCUSDEV_HOST:-1}" in
	1)
		name="incusdev"
		bridge_subnet="10.158.42.1/24"
		asn=65001
		routed4="203.0.113"
		routed6="2001:db8:200"
		incus_port=26870
		with_ceph=1
		;;
	2)
		name="incusdev2"
		bridge_subnet="10.158.43.1/24"
		asn=65002
		routed4="192.0.2"
		routed6="2001:db8:300"
		incus_port=26873
		with_ceph=""
		;;
	*)
		echo "INCUSDEV_HOST is 1 or 2, not $INCUSDEV_HOST" >&2
		return 1
		;;
esac
hosts="incusdev incusdev2"

# The Ceph dashboard and the S3 API follow the Incus API, see portForwards in
# lima.yaml. incusdev2 has the ports, and nothing behind them.
ceph_port=$(( incus_port + 1 ))
s3_port=$(( incus_port + 2 ))

# The stopped copy of the freshly installed VM that "task reset" starts from.
base="$name-base"

# The simulated top-of-rack switch, a VM of its own on macOS: see tor.yaml.
# Both hosts share it.
tor="incusdev-tor"

# The point-to-point link to it, laid by "task p2p": a pair of feth
# interfaces joined to each other, and a Lima network bridged on each end.
# Lima gives each VM its end as lima0; both hosts take the same end.
p2p_feth="feth4"
p2p_feth_tor="feth5"
p2p_network="incusdev-p2p"
p2p_network_tor="incusdev-p2p-tor"
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
