# Troubleshooting and design notes

## Where to look

In the Lima VM, put `limactl shell incusdev` in front of the commands.

| Question | Command |
|---|---|
| Does everything work end to end? | `task check`, or `sudo provision/check.sh` on a host |
| Is Ceph healthy? | `sudo ceph -s` |
| Is the Ceph container up? | `podman ps`, as the user that runs it |
| What does Incus say? | `sudo tail /var/log/incus/incusd.log` |
| What did the install do in the VM? | `sudo grep -E '>>>\|!!!' /var/log/cloud-init-output.log` |
| What is the VM doing? | `task status` |
| Why did Lima not start? | `/tmp/incusdev-up.log`, and `~/.lima/incusdev/ha.stderr.log` |

## Known behaviour

**The pool `ceph` is `UNAVAILABLE` after a start.** Incus starts before Ceph.
It tries the pool again every minute and finds it. Wait a minute or two;
the end-to-end test waits for it.

**Ceph has four muted health checks.** `sudo ceph health detail` lists them
as `(MUTED, STICKY)`; their names begin with `AUTH_INSECURE_`. They say that
the cluster allows keys of the type `aes`. `ceph.sh` set that up and muted
them, see below. `ceph health` says `HEALTH_OK` with them.

**No `/dev/kvm`.** The install still works and Incus runs containers, but no
virtual machines, and the test fails at its first step. On Linux, nested KVM
must be on for a VM to have it:

```sh
cat /sys/module/kvm_*/parameters/nested    # 1 or Y
```

On macOS it needs Apple silicon M3 or newer and macOS 15 or newer.

**A scripted `incus` command hangs.** `incus` reads YAML from stdin whenever
stdin is not a terminal. Close stdin: `incus launch ... </dev/null`.

**The first start is slow.** Lima runs the two scripts inside the first
start, so that start is the install. Later starts run them again, and they
find nothing to change. `task up` only begins the start and returns;
`task status` follows it. The tasks that need the VM say so while it is still
starting.

## Why it is built this way

**The same scripts for a host and for the VM.** `lima.yaml` names
`provision/incus.sh` and `provision/ceph.sh` under `provision`. Nothing else
installs anything, so the VM is a Debian host that had the two scripts run.

**The VM's user is in `incus-admin` from the first login.** Lima connects to
the VM before the scripts run, and a login only has the groups that existed
when it began. So `lima.yaml` makes the group a default for new users in the
VM, before Lima creates its user.

**Incus from Zabbly.** Debian 13 ships Incus 6.0. The Zabbly packages give the
current LTS, and they carry their own QEMU and firmware, so no `qemu-*`
package is needed for virtual machines.

**Rootless Podman with a user session.** Podman without root needs a D-Bus
user session and a user manager that runs without a login. The scripts
install `dbus-user-session`, run `loginctl enable-linger`, and start
`dbus.socket` in a user manager that was already running.

**Ceph on the host network.** The kernel must reach the Ceph monitor on the
address the monitor advertises. With a container network that address only
exists inside the container.

**The Ceph dashboard on port 8444.** Its default is 8443, which Incus uses.
Left alone, the dashboard module fails and puts Ceph in `HEALTH_ERR`.

**Keys of the type `aes`.** The cluster is Ceph 20 (Tentacle), and makes its
keys with the cipher `aes256k`. Debian 13 has the Ceph 18 client and Linux
6.12: the client cannot read such a key, and the kernel's RBD client, which
Incus maps images with, knows the cipher only from Linux 7.0 on. So `ceph.sh`
allows the older cipher `aes` on the monitors, makes the admin key anew with
it, and makes the key `client.incus` with it. Ceph calls that insecure and
raises four health checks, one of them an error; `ceph.sh` mutes them. The
cluster's own daemons keep their `aes256k` keys.

**Not a newer kernel or client.** Linux 7 from trixie-backports and the
Ceph 20 client that Proxmox publishes for Debian 13 would do without `aes`.
But a Lima VM on Apple silicon that runs Linux 7.1 or newer cannot start
virtual machines in Incus: they hang before their kernel starts. Linux 6.12
can, and it needs `aes`. So every install uses `aes`, with Debian's own
kernel and client, and is the same on both architectures.

**A saved copy for `task reset`.** A new VM is stopped once after the install.
While it is stopped, `task up` clones it with `limactl clone`, as
`incusdev-base`. That copy is never started. `task reset` deletes the VM and
clones the copy again.

**The bridge's subnet on macOS.** Incus picks a subnet for `incusbr0` that
nothing answers on. In a Lima VM on macOS every address answers a ping, and
Incus gives up. Then `incus.sh` creates the bridge with `10.158.42.1/24`.

**The scripts wait for apt.** Right after a first boot, something else often
runs `apt-get`. The scripts wait for it instead of failing on the lock.

**Root disks in their own profiles.** The profile `default` has no root disk.
`root-local` and `root-ceph` each have one, so the storage pool is chosen per
instance.

**Alpine virtual machines without secure boot.** Alpine's image is not signed
for it: launch with `--config security.secureboot=false`.

## What is tested

The Lima VM is tested on Linux x86_64 and on macOS with Apple silicon (M5,
macOS 26): a new VM, `task check`, `task down` and `task up`, `task reset`
and `task s3-credentials`.

Not tested:

- `task dashboard` on macOS.
- arm64 on Linux.
- The three scripts run by hand on a plain Debian 13 machine, since they
  changed to keys of the type `aes`.
