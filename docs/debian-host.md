# Directly on a Debian host

The scripts that build the VM also install the testbed onto a Debian 13
computer, with no VM in between: three commands, as root. Take the VM unless
the computer is there for this, since nothing puts a host back.

```sh
sudo provision/incus.sh     # Incus, its network, local pool and profiles
sudo provision/ceph.sh      # Ceph in Podman, its client, keys and the ceph pool
sudo provision/check.sh     # the end-to-end test
```

## The VM or the host

| | In the Lima VM | On the host |
|---|---|---|
| Runs on | any Linux with KVM, and macOS | Debian 13 only: the scripts use apt and Debian's packages |
| Changes on your computer | the VM's files under `~/.lima`, and three ports on `127.0.0.1` | Incus, Ceph in Podman and their networks, installed on it |
| Undo | `task reset`, `task destroy` | by hand; nothing puts the host back |
| Nested virtualization | needed for virtual machines in Incus | not needed |
| The tasks | all of them | none: you use `incus`, `ceph` and the scripts yourself |

## Install

The host needs Debian 13, `/dev/kvm`, 2 CPUs and 4 GiB of memory or more.
Run the three commands above from the repository. The scripts can run
again; they only change what is missing. The user who calls `sudo` gets the
`incus-admin` group and runs the Ceph container.

The Ceph cluster is newer than Debian 13's Ceph client and kernel. `ceph.sh`
lets the cluster use keys of the older type `aes`, which both know, and mutes
the health checks that Ceph raises about it.
[Troubleshooting](troubleshooting.md) says why.

On a host, the three services listen on all of its addresses, not only on
`127.0.0.1`. The password of the Ceph dashboard is in
`/etc/ceph/dashboard.password`, for root to read.

The tasks are for the Lima VM. On a host you use `incus`, `ceph` and
`radosgw-admin` yourself; [Access](access.md) has the commands.

## With BGP

For the BGP mode, two more, after `incus.sh`.
[What it sets up](bgp.md#what-it-sets-up) lists every command they run, and
how to remove it again:

```sh
sudo provision/tor.sh       # the simulated ToR, in a namespace
sudo provision/bird.sh      # Bird2 on the host, peering with it
sudo birdc show protocols tor                            # the session
sudo ip netns exec incusdev-tor ping -I 198.51.100.1 …   # from the fabric
```

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

Lima runs the scripts with the defaults, but for the channel, which
`task up -- --stable` sets. To change another for the VM, change it at the
top of the script before `task up`.

The settings of the BGP mode are in [A top-of-rack switch](bgp.md#settings).
