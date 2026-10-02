# incusdev-vm

A testbed for [Incus](https://linuxcontainers.org/incus/) with virtual
machines and Ceph storage, on Debian 13 (trixie). Two scripts install it.
Run them on a Debian host yourself, or let [Lima](https://lima-vm.io) run
them in a VM on your computer.

## What you get

- Incus 7.0 LTS with its web UI, running virtual machines and containers.
- A one-node Ceph cluster with block storage (RBD), an S3 API and a dashboard.
- Two Incus storage pools: `default` on local disk and `ceph` on RBD.
- These services:

| Service | Port | Login |
|---|---|---|
| Incus API and web UI | 8443 | a client certificate |
| Ceph dashboard | 8444 | `admin` / `admin@ceph123` |
| S3 API | 8000 | keys of the user `incusdev` |
| RadosGW admin API, under `/admin` | 8000 | keys of the user `incusdev-admin` |

## In a VM on your computer

You need [Homebrew](https://brew.sh) and a computer that can run a virtual
machine inside a virtual machine:

- Linux with `/dev/kvm` and nested KVM on, or
- a Mac with Apple silicon M3 or newer, on macOS 15 or newer.

The VM takes 2 CPUs, 2 GiB of memory and a 20 GiB disk. The ports 8443, 8444
and 8000 must be free on `127.0.0.1`.

```sh
brew bundle        # install the tools
task up            # create the VM; returns at once, the install runs on
task status        # follow the install: about 7 minutes, then the services
task check         # run the end-to-end test: 1 to 2 minutes
```

`task up` starts the work in the background. `task status` prints the install
steps as they happen, and ends with the services and whether each one
answers:

```
>>> Services on this computer:
  Incus API          https://127.0.0.1:8443      up    task dashboard adds the incus remote
  Incus web UI       https://127.0.0.1:8443/ui/  up    task dashboard -- incus
  Ceph dashboard     https://127.0.0.1:8444      up    task dashboard -- ceph
  S3 API             http://127.0.0.1:8000       up    task s3-credentials
  RadosGW admin API  http://127.0.0.1:8000/admin up    task s3-credentials -- admin
```

| Task | What it does |
|---|---|
| `task up` | Create the VM, or start it, in the background |
| `task status` | Show the VM and its services; while it starts, follow the steps |
| `task check` | Run the end-to-end test |
| `task dashboard` | Open the Incus web UI, logged in, and the Ceph dashboard. One of them: `-- incus` or `-- ceph` |
| `task s3-credentials` | Print the S3 endpoint and keys; `-- admin` for the RadosGW admin user |
| `task reset` | Put the VM back to how it was right after the install |
| `task down` | Stop the VM and keep its disk |
| `task destroy` | Delete the VM and the copy saved for `task reset` |
| `task lint` | Run shellcheck and validate `lima.yaml` |

After `task down`, `task up` and `task status` have the VM back in about
30 seconds.
Everything is kept: instances, images, the Ceph cluster and its data.

To start over, `task reset` replaces the VM with a copy that `task up` saved
right after the install. It takes about 30 seconds, where a new install takes
7 minutes. The copy uses up to 6 GiB of disk; on a filesystem that can share
blocks it uses almost none. `task destroy` followed by `task up` builds a new
VM, and a new copy, from what is current.

For a larger VM, give the size when you create it. What follows `--` goes to
`limactl start`:

```sh
task up -- --cpus 4 --memory 8 --disk 40
```

## Directly on a Debian host

On a Debian 13 host with `/dev/kvm`, 2 CPUs and 4 GiB of memory or more:

```sh
sudo provision/incus.sh     # Incus, its network, local pool and profiles
sudo provision/ceph.sh      # Ceph in Podman, its client, keys and the ceph pool
sudo reboot                 # once: ceph.sh installed a newer kernel
sudo provision/check.sh     # the end-to-end test
```

The scripts can run again; they only change what is missing. The user who
calls `sudo` gets the `incus-admin` group and runs the Ceph container.

`ceph.sh` installs Linux 7 from trixie-backports, because Debian 13's own
kernel cannot use Ceph's keys. The scripts never reboot the machine; you do,
once. In the Lima VM, `task up` does that restart for you.

On a host, the three services listen on all of its addresses, not only on
`127.0.0.1`. The Ceph dashboard has a password that everyone knows, so keep
port 8444 behind a firewall.

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
provision/incus.sh    installs Incus; runs on a Debian host or in the VM
provision/ceph.sh     installs Ceph and joins it to Incus; same
provision/check.sh    the end-to-end test; same
lima.yaml             the VM: image, size, the two scripts, port forwards
Taskfile.yml          the tasks; each one calls a script in bin/
bin/                  one script per task, for the Lima VM
Brewfile              the tools
renovate.json         lets Renovate propose newer versions
docs/                 the details
```

| Document | Content |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Diagram of the services, networks, ports and flows |
| [docs/access.md](docs/access.md) | Log in to each service |
| [docs/updates.md](docs/updates.md) | How newer versions get in, and how to check one before merging |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Where to look, known behaviour, why it is built this way, what is not tested |
