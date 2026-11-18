# Using the testbed

Everything goes through `task`: one task creates the VM, and the others
show it, test it, open its services, reset it and remove it. Inside it you
use `incus` as on any Incus host.

## The tasks

`task` alone lists them. An option follows `--`, and `-h` shows what a task
takes: `task up -- -h`.

| Task | What it does |
|---|---|
| `task up` | Create the VM, or start it, in the background; `-- --bgp` creates it with a ToR, see [A top-of-rack switch](bgp.md); `-- --stable` creates it with Incus from Zabbly's stable channel in place of the LTS, for the VM's life |
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

## Follow the install

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

## Stop, start and start over

After `task down`, `task up` and `task status` have the VM back in about
30 seconds. Everything is kept: instances, images, the Ceph cluster and its
data.

To start over, `task reset` replaces the VM with a copy that `task up` saved
right after the install. It takes about 30 seconds, where a new install takes
6 minutes. The copy uses up to 6 GiB of disk; on a filesystem that can share
blocks it uses almost none. `task destroy` followed by `task up` builds a new
VM, and a new copy, from what is current.

## A larger VM, a newer Incus

For a larger VM, give the size when you create it. Other options of
`limactl start` follow a `--` of their own:

```sh
task up -- --cpus 4 --memory 8 --disk 40
task up -- --cpus 4 -- --video
```

The Incus release is chosen then too. `--stable` takes Zabbly's stable
channel, the newest feature release, in place of the LTS, and
`--channel NAME` any channel. The choice holds for the VM's life:

```sh
task up -- --stable
```

## Launch instances

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
