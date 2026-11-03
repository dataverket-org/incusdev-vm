share="${BASH_SOURCE[0]%/*}"
root="$share/../.."

# INCUSDEV_HOST=2 picks incusdev2: a standalone Incus beside incusdev, not
# clustered with it, without Ceph, on the same ToR. "task up" hands each
# host's settings to Lima, see param in lima.yaml.
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
		echo "incusdev-vm: unknown INCUSDEV_HOST $INCUSDEV_HOST" >&2
		return 1
		;;
esac
hosts="incusdev incusdev2"

# The order of portForwards in lima.yaml. incusdev2 has the Ceph ports with
# nothing behind them.
ceph_port=$(( incus_port + 1 ))
s3_port=$(( incus_port + 2 ))

# The copy of the freshly installed VM that "task reset" starts from.
base="$name-base"

# The simulated top-of-rack switch, shared by both hosts: see tor.yaml.
tor="incusdev-tor"

# The link to the ToR, laid by "task p2p": a feth pair, a Lima network
# bridged on each end. Each VM has its end as lima0; both hosts share one.
p2p_feth="feth4"
p2p_feth_tor="feth5"
p2p_network="incusdev-p2p"
p2p_network_tor="incusdev-p2p-tor"
lima_networks="${LIMA_HOME:-$HOME/.lima}/_config/networks.yaml"

# Mounted into a new VM, writable, at the same path: see "Work on Incus
# itself" in README.md.
incus_src="${INCUS_SRC:-}"

up_log="${TMPDIR:-/tmp}/$name-up.log"
up_pid="${TMPDIR:-/tmp}/$name-up.pid"

# The browser's client certificate for the Incus web UI, one for both hosts.
# It is the web UI's own login: no cookie, so both hosts' pages stay logged
# in side by side.
cert_dir="${XDG_CONFIG_HOME:-$HOME/.config}/incusdev-vm"
browser_cert_name="incusdev-browser"
browser_cert="$cert_dir/$browser_cert_name.crt"
browser_key="$cert_dir/$browser_cert_name.key"
browser_p12="$cert_dir/$browser_cert_name.p12"
browser_p12_password="incusdev"

case "$(uname -s)" in
	Darwin)	opener="open" ;;
	*)	opener="xdg-open" ;;
esac

source "$share/logging.sh"  || return $?
source "$share/vm.sh"       || return $?
source "$share/services.sh" || return $?
source "$share/tor.sh"      || return $?
