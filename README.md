# incusdev-vm

**A complete [Incus](https://linuxcontainers.org/incus/) testbed in one VM
on your computer: virtual machines and containers, and Ceph storage with an
S3 API and BGP if you ask for them.** One command builds it in about 6 minutes;
another puts it back to new in 30 seconds.

```sh
brew bundle    # the tools
task up        # the VM; returns at once
task status    # follows the install, then lists the services
```

## What you get

- **Incus 7.0 LTS with its web UI.** It runs containers and virtual
  machines. `task up -- --stable` gives the newest feature release instead.
- **A one-node Ceph cluster, if you ask.** `task up -- --ceph` adds block
  storage (RBD) that Incus uses as the storage pool `ceph`, an S3 API and a
  dashboard.
- **A top-of-rack switch, if you ask.** `task up -- --bgp` adds a simulated
  switch inside the VM and Bird2 peering with it over BGP. Instances with a
  routed NIC are announced to it.
- **A way back.** `task reset` replaces the VM with a copy saved right
  after the install. `task destroy` removes all of it.
- **Little on your computer.** The testbed is the VM, on Debian 13: Lima's
  files, and one port on `127.0.0.1`, three with Ceph. The same scripts install it
  straight onto a Debian host instead, if you would rather have no VM.

## Quick start

You need a Mac with Apple silicon, or Linux with `/dev/kvm`, and
[Homebrew](https://brew.sh). Without Homebrew, see
[Install the tools](docs/install.md).

1. **Install the tools**, in this repository:

   ```sh
   brew bundle
   ```

2. **Create the VM.** `task up` returns at once and the install runs on;
   `task status` follows it and ends with the services. Add `-- --ceph` for
   Ceph, `-- --bgp` for a switch, or both: `-- --ceph --bgp`.

   ```sh
   task up
   task status
   ```

3. **Check that it works**, end to end, in 1 to 2 minutes:

   ```sh
   task check
   ```

4. **Use it.** Open the dashboards, or launch an instance in the VM:

   ```sh
   task dashboard             # the Incus web UI, and with Ceph its dashboard
   limactl shell incusdev     # a shell in the VM; there:
   incus launch images:debian/13 c1 --profile default --profile root-local
   ```

   With Ceph, `--profile root-ceph` puts the root disk on the pool `ceph`.

The services are on `127.0.0.1` on your computer, the last three with Ceph:

| Service | Address | Login |
|---|---|---|
| Incus API and web UI | `https://127.0.0.1:26870` | a client certificate; `task dashboard` sets it up |
| Ceph dashboard | `https://127.0.0.1:26871` | `admin` and a password made at install |
| S3 API | `http://127.0.0.1:26872` | keys of the user `incusdev`; `task s3-credentials` |
| RadosGW admin API | `http://127.0.0.1:26872/admin` | keys of the user `incusdev-admin` |

## The tasks

`task` alone lists them, and `task up -- -h` shows a task's options.

| Task | What it does |
|---|---|
| `task up` | Create the VM, or start it; `-- --ceph`, `-- --bgp`, `-- --stable` |
| `task status` | Show the VM and its services; follow a start |
| `task check` | Run the end-to-end test; `-- --vm` with a virtual machine |
| `task dashboard` | Open the Incus web UI, and with `--ceph` the Ceph dashboard |
| `task s3-credentials` | With `--ceph`: print the S3 endpoint and keys |
| `task tor`, `task routed` | With `--bgp`: show the BGP session; deploy an instance with a routed NIC |
| `task reset` | Put the VM back to how it was right after the install |
| `task down` | Stop the VM and keep its disk |
| `task destroy` | Delete the VM and the saved copy |

## Documentation

| If you want to | Read |
|---|---|
| Install the tools without Homebrew, or know what your computer needs | [Install the tools](docs/install.md) |
| Start, stop and reset the VM, size it, and launch instances | [Using the testbed](docs/usage.md) |
| Add Ceph: RBD storage for Incus, an S3 API and a dashboard | [Using the testbed](docs/usage.md#ceph) |
| Log in to the web UI, the Ceph dashboard and the S3 API | [Access](docs/access.md) |
| Announce instances over BGP to a top-of-rack switch | [A top-of-rack switch, with BGP](docs/bgp.md) |
| Install onto a Debian 13 host, with no VM | [Directly on a Debian host](docs/debian-host.md) |
| Build and test Incus from source in the VM | [Work on Incus itself](docs/incus-development.md) |
| Understand the services, networks, ports and files | [Architecture](docs/architecture.md) |
| Find out why something fails, or why it is built this way | [Troubleshooting](docs/troubleshooting.md) |
| Take in newer versions of Debian, Incus and Ceph | [Updates](docs/updates.md) |

## Status

It works on Linux x86_64 and on macOS on Apple silicon, which is where the
current version is tested: a new VM with and without `--bgp`, and the
end-to-end test in both. Not yet tried in this version:

- the tools from Homebrew on Linux, and the scripts run by hand on a
  Debian host.

[What is tested](docs/troubleshooting.md#what-is-tested) has the whole
list.
