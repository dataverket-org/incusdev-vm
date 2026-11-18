# Work on Incus itself

The VM is also a place to build and test Incus from source, the way the
[Incus documentation][from-source] describes, with its Ceph cluster for the
storage tests if you make it with `--ceph`. You edit on your computer and
build in the VM: set `INCUS_SRC` to your checkout before you create the VM,
and `task up` mounts it into the VM, writable and at the same path.

```sh
export INCUS_SRC=~/kode/incus         # in your shell profile
task up -- --ceph --cpus 4 --memory 6
cd ~/kode/incus && limactl shell incusdev
```

## Why build in the VM

`incusd` links liblxc, cowsql and raft from the Linux system it is built
on: macOS cannot build it, and a build from another Linux does not match
the VM's libraries. A rebuild in the VM takes seconds. The mount is
writable because the test suite writes into the source tree.

## Set up the VM, once

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

## Build and test

Build, and run a test against the Ceph cluster, in a VM made with
`--ceph`. `main.sh` takes the
name of a test in `test/suites`; without one it runs all of them. Its
daemons run beside the VM's own Incus and keep their state on a tmpfs. They
find no QEMU, so they cannot run virtual machines.

```sh
make
cd test && sudo -E env "PATH=$PATH:$HOME/go/bin" "GOPATH=$HOME/go" \
	"LD_LIBRARY_PATH=$LD_LIBRARY_PATH" INCUS_BACKEND=ceph \
	INCUS_CEPH_CLUSTER=ceph INCUS_TMPFS=1 ./main.sh storage_driver_ceph
```

## An existing VM

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
