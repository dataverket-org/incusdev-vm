# A top-of-rack switch, with BGP

`task up -- --bgp` gives the testbed a simulated top-of-rack switch (ToR)
and Bird2 peering with it, so that instances with a routed NIC are announced
over BGP, IPv4 and IPv6. All of it is inside the VM: nothing is set up on
your computer, and nothing asks for sudo.

| If you want to | Go to |
|---|---|
| Make a VM with the switch | [Create it](#create-it) |
| Know every command and file it adds | [What it sets up](#what-it-sets-up) |
| Announce an instance | [An instance with a routed NIC](#an-instance-with-a-routed-nic) |
| Change names, ranges or AS numbers, or peer with a real switch | [Settings](#settings) |

## How it works

The testbed has two modes, chosen when it is made:

| Mode | With | What you get |
|---|---|---|
| default | `task up` | Incus and Ceph, no BGP |
| BGP | `task up -- --bgp` | also a simulated top-of-rack switch (ToR), and Bird2 on the Incus host peering with it |

The switch is a network namespace on the Incus host, `incusdev-tor`, with a
Bird2 of its own in it, joined to the host by a pair of veth interfaces.
With Lima all of it is inside the VM: nothing is set up on your computer,
there is no second VM, and nothing asks for sudo. It is the same on macOS,
on Linux and [on a Debian host](debian-host.md).

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

## Create it

```sh
task up -- --bgp    # the VM, with the ToR in it: about 6 minutes
task status         # the services, and the BGP session
task tor            # the session, and the routes on both ends
task check          # also pings incusbr0 and a routed NIC from the fabric
```

A VM made without `--bgp` stays without it: run `task destroy` and
`task up -- --bgp`. After that `task up`, `task down` and `task reset` keep
the mode.

## What it sets up

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

## An instance with a routed NIC

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

## Settings

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
