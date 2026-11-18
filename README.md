# incusdev-vm

A testbed for [Incus](https://linuxcontainers.org/incus/) with virtual
machines and Ceph storage, on Debian 13 (trixie). Two scripts install it.
Run them on a Debian host yourself, or let [Lima](https://lima-vm.io) run
them in a VM on your computer.

## What you get

- Incus 7.0 LTS with its web UI, running virtual machines and containers;
  `task up -- --stable` gives the newest feature release instead.
- A one-node Ceph cluster with block storage (RBD), an S3 API and a dashboard.
- Two Incus storage pools: `default` on local disk and `ceph` on RBD.
- With `task up -- --bgp`: a simulated top-of-rack switch in the VM, and
  Bird2 peering with it over an unnumbered IPv6 link-local BGP session.
  Instances with a routed NIC are announced to it.
- These services:

| Service | Port on a Debian host | On your computer, with Lima | Login |
|---|---|---|---|
| Incus API and web UI | 8443 | `127.0.0.1:26870` | a client certificate |
| Ceph dashboard | 8444 | `127.0.0.1:26871` | `admin` and a password made at install |
| S3 API | 8000 | `127.0.0.1:26872` | keys of the user `incusdev` |
| RadosGW admin API, under `/admin` | 8000 | `127.0.0.1:26872` | keys of the user `incusdev-admin` |

## In a VM on your computer

You need [Homebrew](https://brew.sh) and a computer that runs a virtual
machine: Linux with `/dev/kvm`, or a Mac with Apple silicon. For Incus to
run virtual machines inside that VM as well, and not only containers, the
VM needs nested virtualization:

- Linux with nested KVM on, or
- a Mac with Apple silicon M3 or newer, on macOS 15 or newer.

The test uses a container, so it passes without; `task check -- --vm`
asks for a virtual machine.

The VM takes 2 CPUs, 2 GiB of memory and a 20 GiB disk. The ports 26870,
26871 and 26872 must be free on `127.0.0.1`: a block nothing well-known
uses, which is why the VM's own 8443, 8444 and 8000 are not what you reach.

```sh
brew bundle        # install the tools
task up            # create the VM; returns at once, the install runs on
task status        # follow the install: about 6 minutes, then the services
task check         # run the end-to-end test: 1 to 2 minutes
```

On Arch Linux the tools come without Homebrew. Lima is in the AUR, and Arch
names Task's binary `go-task`; a link makes it `task`:

```sh
sudo pacman -S go-task incus shellcheck qemu-base
yay -S lima-bin
ln -s /usr/bin/go-task ~/.local/bin/task
```

`task up` starts the work in the background. `task status` prints the install
steps as they happen, a step that failed with `!!!`, and ends with the
services and whether each one answers:

```
>>> Services on this computer:
  Incus API          https://127.0.0.1:26870     up    task dashboard adds the incus remote
  Incus web UI       https://127.0.0.1:26870/ui/ up    task dashboard -- incus
  Ceph dashboard     https://127.0.0.1:26871     up    task dashboard -- ceph
  S3 API             http://127.0.0.1:26872      up    task s3-credentials
  RadosGW admin API  http://127.0.0.1:26872/admin up   task s3-credentials -- admin
```

| Task | What it does |
|---|---|
| `task up` | Create the VM, or start it, in the background; `-- --bgp` creates it with a ToR, see [A top-of-rack switch](#a-top-of-rack-switch-with-bgp); `-- --stable` creates it with Incus from Zabbly's stable channel in place of the LTS, for the VM's life |
| `task status` | Show the VM and its services; while it starts, follow the steps |
| `task check` | Run the end-to-end test, with a container; `-- --vm` launches a virtual machine instead, which needs nested virtualization |
| `task dashboard` | Open the Incus web UI, logged in, and the Ceph dashboard, and print its password. One of them: `-- incus` or `-- ceph` |
| `task s3-credentials` | Print the S3 endpoint and keys; `-- admin` for the RadosGW admin user |
| `task tor` | Show the BGP session and the routes on both ends; `-- shell` opens a shell in the ToR |
| `task routed` | Deploy a test instance with a routed NIC, announced to the ToR: a container, or with `--vm` a virtual machine; `-- 2`, `--delete` |
| `task reset` | Put the VM back to how it was right after the install |
| `task down` | Stop the VM and keep its disk |
| `task destroy` | Delete the VM and the copy saved for `task reset` |
| `task lint` | Run shellcheck and validate `lima.yaml` |

After `task down`, `task up` and `task status` have the VM back in about
30 seconds.
Everything is kept: instances, images, the Ceph cluster and its data.

To start over, `task reset` replaces the VM with a copy that `task up` saved
right after the install. It takes about 30 seconds, where a new install takes
6 minutes. The copy uses up to 6 GiB of disk; on a filesystem that can share
blocks it uses almost none. `task destroy` followed by `task up` builds a new
VM, and a new copy, from what is current.

For a larger VM, give the size when you create it. What follows `--` goes to
`limactl start`:

```sh
task up -- --cpus 4 --memory 8 --disk 40
```

## Work on Incus itself

The VM is also a place to build and test Incus from source, the way the
[Incus documentation][from-source] describes, with its Ceph cluster for the
storage tests. Set `INCUS_SRC` to your checkout before you create the VM.
`task up` mounts it into the VM, writable and at the same path: the test
suite writes into it.

You edit on your computer and build in the VM. `incusd` links liblxc,
cowsql and raft from the Linux system it is built on: macOS cannot build it,
and a build from another Linux does not match the VM's libraries. A rebuild
in the VM takes seconds.

```sh
export INCUS_SRC=~/kode/incus         # in your shell profile
task up -- --cpus 4 --memory 6
cd ~/kode/incus && limactl shell incusdev
```

In the VM, once: Incus's build and test dependencies for Debian, and
`xfsprogs`. Mask Debian's LXC services, as the Incus CI does; they add a
bridge of their own.

```sh
sudo apt install acl attr autoconf automake dnsmasq-base git golang-go \
	libacl1-dev libcap-dev liblxc1 lxc-dev libsqlite3-dev libtool \
	libudev-dev liblz4-dev libuv1-dev make pkg-config rsync tar tcl \
	squashfs-tools xz-utils nftables busybox-static curl gettext jq \
	sqlite3 socat bind9-dnsutils xfsprogs
sudo systemctl mask --now lxc.service lxc-net.service
echo 'export GOTOOLCHAIN=auto' >> ~/.bashrc     # Debian's Go is too old
make deps | grep '^export ' >> ~/.bashrc && . ~/.bashrc
```

Then build, and run a test against the Ceph cluster. `main.sh` takes the
name of a test in `test/suites`; without one it runs all of them. Its
daemons run beside the VM's own Incus and keep their state on a tmpfs. They
find no QEMU, so they cannot run virtual machines.

```sh
make
cd test && sudo -E env "PATH=$PATH:$HOME/go/bin" "GOPATH=$HOME/go" \
	"LD_LIBRARY_PATH=$LD_LIBRARY_PATH" INCUS_BACKEND=ceph \
	INCUS_CEPH_CLUSTER=ceph INCUS_TMPFS=1 ./main.sh storage_driver_ceph
```

`task reset` keeps the mount, and drops what was installed in the VM.
For a VM made before `INCUS_SRC` was set, add the mount and the memory to it
and to the copy that `task reset` starts from:

```sh
task down
limactl edit --tty=false incusdev --memory 6 --mount "$INCUS_SRC:w"
limactl edit --tty=false incusdev-base --memory 6 --mount "$INCUS_SRC:w"
task up
```

[from-source]: https://linuxcontainers.org/incus/docs/main/installing/#install-incus-from-source

## A top-of-rack switch, with BGP

The testbed has two modes, chosen when it is made:

| Mode | With | What you get |
|---|---|---|
| default | `task up` | Incus and Ceph, no BGP |
| BGP | `task up -- --bgp` | also a simulated top-of-rack switch (ToR), and Bird2 on the Incus host peering with it |

The switch is a network namespace on the Incus host, `incusdev-tor`, with a
Bird2 of its own in it, joined to the host by a pair of veth interfaces.
With Lima all of it is inside the VM: nothing is set up on your computer,
there is no second VM, and nothing asks for sudo. It is the same on macOS,
on Linux and [on a Debian host](#directly-on-a-debian-host).

```
the Incus host, AS 65001                the namespace incusdev-tor, AS 65000
  Bird2: incusbr0, routed NICs            Bird2: the fabric
  incusdev-tor0: link-local only  ⇄ veth ⇄  server0: fe80::1
  BGP to fe80::1%incusdev-tor0            fabric0: 198.51.100.1/24
                                                   2001:db8:100::1/64
```

The session is unnumbered: the link has no addresses but IPv6 link-local
ones. The switch's port has the fixed `fe80::1` and accepts any server that
connects from a link-local address in an AS other than its own; the host
connects to it. IPv4 routes travel with IPv6 next hops (RFC 8950), and land
in the kernel as `via inet6 fe80::…`.

| Announced by | What | Prefixes |
|---|---|---|
| the host | the Incus networks | `incusbr0`'s subnets |
| the host | routed NICs, learned from the host routes Incus adds | `/32`s in `203.0.113.0/24`, `/128`s in `2001:db8:200::/48` |
| the ToR | the fabric, a dummy interface for the rest of the data centre | `198.51.100.0/24`, `2001:db8:100::/64` |

The host never takes a default route from the switch; its internet stays
where it was.

### Create it

```sh
task up -- --bgp    # the VM, with the ToR in it: about 6 minutes
task status         # the services, and the BGP session
task tor            # the session, and the routes on both ends
task check          # also pings incusbr0 and a routed NIC from the fabric
```

A VM made without `--bgp` stays without it: run `task destroy` and
`task up -- --bgp`. After that `task up`, `task down` and `task reset` keep
the mode.

### What it sets up

Two scripts do it, as root, on the Incus host: in the VM Lima runs them, on
a Debian host you do. This is all they run and write.

`provision/tor.sh` makes the switch. The namespace and the link are these
commands, which `incusdev-tor.service` runs again on every boot;
`systemctl cat incusdev-tor` shows them on the host:

```sh
ip netns add incusdev-tor
ip link add incusdev-tor0 type veth peer name server0 netns incusdev-tor
ip -n incusdev-tor link add fabric0 type dummy
ip -n incusdev-tor address add 198.51.100.1/24 dev fabric0
ip -n incusdev-tor address add 2001:db8:100::1/64 dev fabric0 nodad
ip -n incusdev-tor address add fe80::1/64 dev server0 nodad
ip netns exec incusdev-tor sysctl -q -w net.ipv4.ip_forward=1
ip netns exec incusdev-tor sysctl -q -w net.ipv6.conf.all.forwarding=1
ip -n incusdev-tor link set lo up
ip -n incusdev-tor link set fabric0 up
ip -n incusdev-tor link set server0 up
ip link set incusdev-tor0 up
```

Then it installs Bird2 and starts a second Bird in the namespace, as
`incusdev-tor-bird.service`:

```sh
apt-get install -y bird2
bird -f -u bird -g bird -c /etc/bird/tor.conf -s /run/incusdev-tor/bird.ctl
```

`provision/bird.sh` configures the host's own Bird, the package's
`bird.service`, to peer with the switch over `incusdev-tor0`:

```sh
systemctl enable bird
systemctl restart bird      # with the /etc/bird/bird.conf it wrote
```

| Script | Writes |
|---|---|
| `tor.sh` | `/etc/systemd/system/incusdev-tor.service`, `/etc/systemd/system/incusdev-tor-bird.service`, `/etc/bird/tor.conf` |
| `bird.sh` | `/etc/bird/bird.conf` |

In the host's own network that leaves one interface, `incusdev-tor0`, with
a link-local address only, the routes to the fabric that Bird learns, and
Bird on the BGP port, 179. The fabric and the switch's port are inside the
namespace. Where networkd manages the link, as it may with a real switch,
`bird.sh` also writes `/etc/systemd/networkd.conf.d/60-bird.conf`, so that
networkd leaves Bird's routes alone.

So that this does not collide with a network you have, the names carry
`incusdev`, the addresses are from the ranges set aside for documentation,
and both scripts stop before they change anything when a namespace or an
interface of that name exists that they did not make, when
`/etc/bird/bird.conf` is neither the package's nor theirs, or when another
program listens on port 179. The names and the ranges are
[settings](#settings).

To remove it again from a Debian host:

```sh
sudo systemctl disable --now bird incusdev-tor-bird incusdev-tor
sudo rm /etc/systemd/system/incusdev-tor*.service /etc/bird/tor.conf
sudo systemctl daemon-reload
```

### An instance with a routed NIC

`task routed` deploys a test instance whose NIC is routed: Incus gives it the
addresses `203.0.113.N` and `2001:db8:200::N` and a host route for each, Bird
on the host learns those routes from the kernel and announces them, and the
task waits until the ToR pings both from the fabric. It is a container, as in
`task check`; `--vm` makes it a virtual machine. It stays until you remove it.

```sh
task routed              # routed1: 203.0.113.1, 2001:db8:200::1
task routed -- 2 --vm    # routed2, a virtual machine
task routed -- 2 --delete
```

Every link that routes is IPv6 only, a virtual machine's too: `task routed`
has cloud-init give it its two addresses and both default routes by `fe80::1`,
which Incus puts on the host's side of a routed NIC. IPv4 then travels with
an IPv6 next hop at every hop:

```
routed2:    default via inet6 fe80::1 dev eth0
the host:   198.51.100.0/24 via inet6 fe80::1 dev incusdev-tor0
the ToR:    203.0.113.2 via inet6 fe80::5055:… dev server0
```

`task check` checks the link to the ToR so: no IPv4 address on either end,
and no IPv4 route over it without an IPv6 next hop.

Any instance can have a routed NIC with addresses from those ranges. A
container gets its addresses and routes from Incus; a virtual machine
configures them itself, as `task routed` does.

```sh
incus config device add v1 eth0 nic nictype=routed \
	ipv4.address=203.0.113.20 ipv6.address=2001:db8:200::20
```

In the ToR, `task tor -- shell`, ping one from the fabric:
`ping -I 198.51.100.1 203.0.113.1`.

### Settings

The names, ranges and AS numbers are settings of the two scripts, read from
the environment; Lima runs them with the defaults. `provision/bird.sh` also
peers with a real switch: set `BGP_IFACE` to the NIC that faces it, and
leave `tor.sh` out. Without that interface it does nothing.

| Script | Variable | Default |
|---|---|---|
| `tor.sh` | `TOR_NETNS`, the namespace | `incusdev-tor` |
| `tor.sh` | `TOR_LINK`, `TOR_IFACE`, the two ends of the link | `incusdev-tor0`, `server0` |
| `tor.sh` | `TOR_ADDRESS`, `TOR_ASN` | `fe80::1`, `65000` |
| `tor.sh` | `TOR_FABRIC4`, `TOR_FABRIC6` | `198.51.100.1/24`, `2001:db8:100::1/64` |
| `bird.sh` | `BGP_IFACE`, `BGP_ASN` | `incusdev-tor0`, `65001` |
| `bird.sh` | `BGP_PEER`, `BGP_PEER_ASN` | `fe80::1`, `65000` |
| `bird.sh` | `BGP_NETWORKS`, the interfaces whose subnets it announces | `incusbr0` |
| `bird.sh` | `BGP_ROUTED4`, `BGP_ROUTED6` | `203.0.113.0/24`, `2001:db8:200::/48` |

## Directly on a Debian host

On Linux you choose where the testbed goes: into the Lima VM, with the tasks
above, or onto the computer itself, with the same scripts. The VM is the one
to take unless the computer is there for this:

| | In the Lima VM | On the host |
|---|---|---|
| Runs on | any Linux with KVM, and macOS | Debian 13 only: the scripts use apt and Debian's packages |
| Changes on your computer | the VM's files under `~/.lima`, and three ports on `127.0.0.1` | Incus, Ceph in Podman and their networks, installed on it |
| Undo | `task reset`, `task destroy` | by hand; nothing puts the host back |
| Nested virtualization | needed for virtual machines in Incus | not needed |
| The tasks | all of them | none: you use `incus`, `ceph` and the scripts yourself |

On a Debian 13 host with `/dev/kvm`, 2 CPUs and 4 GiB of memory or more:

```sh
sudo provision/incus.sh     # Incus, its network, local pool and profiles
sudo provision/ceph.sh      # Ceph in Podman, its client, keys and the ceph pool
sudo provision/check.sh     # the end-to-end test
```

For the BGP mode, two more, after `incus.sh`.
[What it sets up](#what-it-sets-up) lists every command they run, and how to
remove it again:

```sh
sudo provision/tor.sh       # the simulated ToR, in a namespace
sudo provision/bird.sh      # Bird2 on the host, peering with it
sudo birdc show protocols tor                            # the session
sudo ip netns exec incusdev-tor ping -I 198.51.100.1 …   # from the fabric
```

The scripts can run again; they only change what is missing. The user who
calls `sudo` gets the `incus-admin` group and runs the Ceph container.

The Ceph cluster is newer than Debian 13's Ceph client and kernel. `ceph.sh`
lets the cluster use keys of the older type `aes`, which both know, and mutes
the health checks that Ceph raises about it.
[docs/troubleshooting.md](docs/troubleshooting.md) says why.

On a host, the three services listen on all of its addresses, not only on
`127.0.0.1`. The password of the Ceph dashboard is in
`/etc/ceph/dashboard.password`, for root to read.

The tasks above are for the Lima VM. On a host you use `incus`, `ceph` and
`radosgw-admin` yourself; [docs/access.md](docs/access.md) has the commands.

## Use it

An instance takes the profile `default`, which has the network card, plus one
profile for its root disk:

```sh
incus launch images:debian/13 c1 --profile default --profile root-local
incus launch images:alpine/3.21 v1 --vm --profile default --profile root-ceph \
	--config security.secureboot=false
incus list
```

| Profile | Root disk on |
|---|---|
| `root-local` | the pool `default`, a directory on local disk |
| `root-ceph` | the pool `ceph`, an RBD image in the Ceph cluster |

Run these on the host itself, in the VM with `limactl shell incusdev`, or
from your computer once `task dashboard` has added the remote:
`incus list incusdev:`.

## Settings

The scripts read these from the environment, on a host:

| Variable | Default | Meaning |
|---|---|---|
| `INCUS_CHANNEL` | `lts-7.0` | Zabbly channel: `lts-7.0`, `lts-6.0` or `stable` |
| `CEPH_IMAGE` | `quay.io/benjamin_holmes/ceph-aio:v20` | The Ceph container image |
| `OSD_SIZE` | `10G` | Size of the Ceph disk, on the first run |
| `INCUSDEV_USER` | who called `sudo` | The user for `incus-admin` and Podman |

```sh
sudo OSD_SIZE=20G provision/ceph.sh
```

Lima runs the scripts with the defaults. To change one for the VM, change it
at the top of the script before `task up`.

## How it is built

```
provision/incus.sh      installs Incus; runs on a Debian host or in the VM
provision/ceph.sh       installs Ceph and joins it to Incus; same
provision/check.sh      the end-to-end test; same
provision/tor.sh        the simulated ToR, a namespace with Bird2; same
provision/bird.sh       Bird2 peering with a ToR; same
lima.yaml               the VM: image, size, the scripts, port forwards
Taskfile.yml            the tasks; each one calls a script in bin/
bin/                    one script per task, for the Lima VM
share/incusdev-vm/      the functions that the scripts in bin/ share
Brewfile                the tools
renovate.json           lets Renovate propose newer versions
docs/                   the details
```

| Document | Content |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Diagram of the services, networks, ports and flows |
| [docs/access.md](docs/access.md) | Log in to each service |
| [docs/updates.md](docs/updates.md) | How newer versions get in, and how to check one before merging |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Where to look, known behaviour, why it is built this way, what is not tested |
