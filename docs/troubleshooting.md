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
| Why did Lima not start? | `/tmp/incusdev-up.log`, and `~/.lima/incusdev/ha.stderr.log` |

## Known behaviour

**The pool `ceph` is `UNAVAILABLE` after a start.** Incus starts before Ceph.
It tries the pool again every minute and finds it. Wait a minute or two;
the end-to-end test waits for it.

**The test says the kernel is too old.** `ceph.sh` installed Linux 7, and the
machine still runs the old kernel. Reboot it. In the Lima VM, run `task down`
and `task up`.

**No `/dev/kvm`.** The install still works and Incus runs containers, but no
virtual machines, and the test fails at its first step. On Linux, nested KVM
must be on for a VM to have it:

```sh
cat /sys/module/kvm_*/parameters/nested    # 1 or Y
```

On macOS it needs Apple silicon M3 or newer and macOS 15 or newer.

**A scripted `incus` command hangs.** `incus` reads YAML from stdin whenever
stdin is not a terminal. Close stdin: `incus launch ... </dev/null`.

**The first `task up` is slow.** Lima runs the two scripts inside the first
start, so that start is the install. Later starts run them again, and they
find nothing to change.

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

**Telemetry on, but sending nothing.** The dashboard shows a "please activate
Telemetry" banner for as long as the telemetry module is off, and has no
setting to hide it. The scripts turn the module on with every channel off and
with report addresses that nothing listens on (`http://127.0.0.1:9`), so no
data leaves the machine.

**The Ceph client from Proxmox.** The cluster is Ceph 20 (Tentacle). Debian
13 ships Ceph 18. Proxmox publishes Ceph 20 for trixie, for amd64 only; on
arm64 the scripts install Debian's client. The repository is named in
`provision/ceph.sh` and has to follow the image's release.

**Linux 7 from backports.** Ceph makes its keys with the cipher `aes256k`.
The kernel's RBD client, which Incus maps images with, knows that cipher from
Linux 7.0 on. Debian 13's kernel is 6.12; there `rbd map` fails with
`Invalid argument` and the kernel logs `libceph: secret too big 32`. So
`ceph.sh` installs the kernel from trixie-backports. The other way is to
allow the old cipher `aes` on the monitors and make the key with
`--key-type aes`; that works on 6.12, and leaves Ceph in `HEALTH_WARN` for
good.

**The scripts do not reboot.** A reboot in the middle of an install is a
surprise on a host. `ceph.sh` finishes on the old kernel and says that a
reboot is needed; `check.sh` refuses to run until it has happened. `task up`
restarts the Lima VM once, when the running kernel is not the newest one
installed.

**The scripts wait for apt.** Right after a first boot, something else often
runs `apt-get`. The scripts wait for it instead of failing on the lock.

**Root disks in their own profiles.** The profile `default` has no root disk.
`root-local` and `root-ceph` each have one, so the storage pool is chosen per
instance.

**Alpine virtual machines without secure boot.** Alpine's image is not signed
for it: launch with `--config security.secureboot=false`.

## Not tested yet

- macOS.
- arm64, on macOS or Linux: Debian's Ceph 18 client against the Ceph 20
  cluster, and the arm64 ceph-aio image.

Everything else is tested on Linux x86_64: the Lima VM with `task check`, and
the three scripts run by hand on a plain Debian 13 machine.
