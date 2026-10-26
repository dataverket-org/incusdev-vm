# incusdev-vm

A testbed for [Incus](https://linuxcontainers.org/incus/) with virtual
machines and Ceph storage, on Debian 13 (trixie). Two scripts install it.
Run them on a Debian host yourself, or let [Lima](https://lima-vm.io) run
them in a VM on your computer.

## What you get

- Incus 7.0 LTS with its web UI, running virtual machines and containers.
- A one-node Ceph cluster with block storage (RBD), an S3 API and a dashboard.
- Two Incus storage pools: `default` on local disk and `ceph` on RBD.
- On macOS, if you ask for it: a simulated top-of-rack switch, a second VM
  with Bird2, and Bird2 in the VM, peering over an unnumbered IPv6
  link-local BGP session. Instances with a routed NIC are announced to it.
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
| `task up` | Create the VM, or start it, in the background; `-- --tor` creates it with a ToR, see [A top-of-rack switch](#a-top-of-rack-switch-with-bgp) |
| `task status` | Show the VM and its services; while it starts, follow the steps |
| `task check` | Run the end-to-end test, with a container; `-- --vm` launches a virtual machine instead, which needs nested virtualization |
| `task dashboard` | Open the Incus web UI, logged in, and the Ceph dashboard, and print its password. One of them: `-- incus` or `-- ceph` |
| `task s3-credentials` | Print the S3 endpoint and keys; `-- admin` for the RadosGW admin user |
| `task p2p` | Lay the link to the ToR, with sudo; again after a restart of the Mac |
| `task tor` | Show the BGP session and the routes on both ends; `-- shell` opens a shell on the ToR |
| `task routed` | Deploy a test instance with a routed NIC, announced to the ToR: a container, or with `--vm` a virtual machine; `-- 2`, `--delete` |
| `task reset` | Put the VM back to how it was right after the install |
| `task down` | Stop the VM, and the ToR, and keep their disks |
| `task destroy` | Delete the VM, the copy saved for `task reset`, and the ToR |
| `task lint` | Run shellcheck and validate `lima.yaml` and `tor.yaml` |

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

On macOS the VM can have a simulated top-of-rack switch (ToR): a second,
small VM, `incusdev-tor`, running Bird2. It is joined to `incusdev` by a
point-to-point link of its own, a pair of `feth` interfaces, and Bird2 in
`incusdev` holds a BGP session with it across that link. Instances with a
routed NIC are announced to the switch, over IPv4 and IPv6.

```
incusdev, AS 65001                          incusdev-tor, AS 65000
  Bird2: incusbr0, routed NICs                Bird2: the fabric
  lima0: link-local only   ── feth4 ⇄ feth5 ──  lima0: fe80::1
  BGP to fe80::1%lima0                         fabric0: 198.51.100.1/24
                                                        2001:db8:100::1/64
```

The session is unnumbered: the link has no addresses but IPv6 link-local
ones. The switch's port has the fixed `fe80::1` and accepts any server that
connects from a link-local address in an AS other than its own; `incusdev`
connects to it. IPv4 routes travel with IPv6 next hops (RFC 8950), and land
in the kernel as `via inet6 fe80::…`.

| Announced by | What | Prefixes |
|---|---|---|
| `incusdev` | the Incus networks | `incusbr0`'s subnets |
| `incusdev` | routed NICs, learned from the host routes Incus adds | `/32`s in `203.0.113.0/24`, `/128`s in `2001:db8:200::/48` |
| the ToR | the fabric, a dummy interface for the rest of the data centre | `198.51.100.0/24`, `2001:db8:100::/64` |

`incusdev` never takes a default route from the switch; its internet stays on
`eth0`. The addresses are documentation ranges, so nothing collides with a
real network.

### Create it

The ToR is chosen when the VM is created. The link needs root once, for the
`feth` pair, two Lima networks bridged on its ends, and the sudoers file that
lets Lima start them. `task p2p` does that and asks for sudo; run it in your
own terminal. The `feth` pair is gone after a restart of the Mac, and
`task up` asks for `task p2p` again then.

```sh
task p2p            # the link: feth4 ⇄ feth5, the networks incusdev-p2p
                    # and incusdev-p2p-tor in ~/.lima/_config/networks.yaml
task up -- --tor    # the ToR first, then incusdev, about 8 minutes
task status         # the services, and the BGP session
task tor            # the session, and the routes on both ends
task check          # also pings incusdev and a routed NIC from the fabric
```

A VM made without `--tor` stays without one: run `task destroy` and
`task up -- --tor`. After that `task up`, `task down` and `task reset` handle
both VMs; `task destroy` deletes both, and leaves the link.

### An instance with a routed NIC

`task routed` deploys a test instance whose NIC is routed: Incus gives it the
addresses `203.0.113.N` and `2001:db8:200::N` and a host route for each, Bird
in `incusdev` learns those routes from the kernel and announces them, and the
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
routed2:       default via inet6 fe80::1 dev eth0
incusdev:      198.51.100.0/24 via inet6 fe80::1 dev lima0
incusdev-tor:  203.0.113.2 via inet6 fe80::5055:… dev lima0
```

`task check` checks the link to the ToR so: no IPv4 address on `lima0`, and
no IPv4 route over it without an IPv6 next hop.

Any instance can have a routed NIC with addresses from those ranges. A
container gets its addresses and routes from Incus; a virtual machine
configures them itself, as `task routed` does.

```sh
incus config device add v1 eth0 nic nictype=routed \
	ipv4.address=203.0.113.20 ipv6.address=2001:db8:200::20
```

From the ToR, `task tor -- shell`, ping one from the fabric:
`ping -I 198.51.100.1 203.0.113.1`.

### Settings

The ranges, AS numbers and interfaces are settings of the two scripts, read
from the environment; Lima runs them with the defaults. On a Debian host
`provision/bird.sh` peers with a real switch: set `BGP_IFACE` to the NIC
that faces it, and run it after `incus.sh`. Without that interface it does
nothing.

| Script | Variable | Default |
|---|---|---|
| `bird.sh` | `BGP_IFACE`, `BGP_ASN` | `lima0`, `65001` |
| `bird.sh` | `BGP_PEER`, `BGP_PEER_ASN` | `fe80::1`, `65000` |
| `bird.sh` | `BGP_NETWORKS`, the interfaces whose subnets it announces | `incusbr0` |
| `bird.sh` | `BGP_ROUTED4`, `BGP_ROUTED6` | `203.0.113.0/24`, `2001:db8:200::/48` |
| `tor.sh` | `TOR_IFACE`, `TOR_ADDRESS`, `TOR_ASN` | `lima0`, `fe80::1`, `65000` |
| `tor.sh` | `TOR_FABRIC4`, `TOR_FABRIC6` | `198.51.100.1/24`, `2001:db8:100::1/64` |

The first boot of each VM waits about two minutes for DHCP on `lima0`, which
Lima asks for and the link does not have; the scripts turn it off, and later
boots take seconds.

## Directly on a Debian host

On a Debian 13 host with `/dev/kvm`, 2 CPUs and 4 GiB of memory or more:

```sh
sudo provision/incus.sh     # Incus, its network, local pool and profiles
sudo provision/ceph.sh      # Ceph in Podman, its client, keys and the ceph pool
sudo provision/check.sh     # the end-to-end test
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
provision/bird.sh       Bird2 peering with a ToR; same, with BGP_IFACE
provision/tor.sh        the simulated ToR, in its own VM
lima.yaml               the VM: image, size, the scripts, port forwards
tor.yaml                the ToR's VM
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
