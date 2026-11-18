# Install the tools

`brew bundle` installs everything the tasks need, on macOS and on Linux.
Without Homebrew you need four programs on your `PATH`: `limactl`, QEMU on
Linux, `task` and `curl`. The testbed itself is not installed on your
computer; it lives in the VM that `task up` creates.

## What your computer needs

A computer that runs a virtual machine: a Mac with Apple silicon, or Linux
with a `/dev/kvm` that your user may write to.

For Incus to run virtual machines inside that VM as well, and not only
containers, the VM needs nested virtualization:

- Linux with nested KVM on, or
- a Mac with Apple silicon M3 or newer, on macOS 15 or newer.

The end-to-end test uses a container, so it passes without;
`task check -- --vm` asks for a virtual machine.

The VM takes 2 CPUs, 2 GiB of memory and a 20 GiB disk. The ports 26870,
26871 and 26872 must be free on `127.0.0.1`: a block nothing well-known
uses, which is why the VM's own 8443, 8444 and 8000 are not what you reach.

## With Homebrew

With [Homebrew](https://brew.sh), on macOS and on Linux, in the repository:

```sh
brew bundle
```

The `Brewfile` lists the tools. On Linux it includes QEMU.

## Without Homebrew

Install these yourself, from your distribution or from each project:

| Program | Needed for | Note |
|---|---|---|
| `limactl`, from [Lima](https://lima-vm.io/docs/installation/) | the VM | version 2.0 or newer |
| `qemu-system-x86_64` or `qemu-system-aarch64`, and `qemu-img` | the VM, on Linux | macOS uses its own framework |
| `task`, from [Task](https://taskfile.dev/installation/) | the tasks | |
| `bash` and `curl` | the tasks | any bash from 3.2 |
| `incus`, the client | `task dashboard` only | |
| `shellcheck` | `task lint` only | |

Then `task up` works as with Homebrew. Where a task says "Run: brew bundle",
one of these is missing.

## Notes for distributions

### Debian and Ubuntu

Lima is not packaged. Unpack its release archive from
[GitHub](https://github.com/lima-vm/lima/releases) and put its `bin`
directory on your `PATH`; `bin` and `share` stay side by side.

```sh
sudo apt install qemu-system-x86 qemu-utils curl
```

`apt install task` gives Taskwarrior, another program: take Task from its
own site. Your user needs `/dev/kvm`, which membership of the group `kvm`
gives.

### Arch Linux

Lima is in the AUR. Arch names Task's binary `go-task`, and a link makes it
`task`:

```sh
sudo pacman -S go-task incus shellcheck qemu-base
yay -S lima-bin
ln -s /usr/bin/go-task ~/.local/bin/task
```

## What is tested

The Lima release archive with Ubuntu 24.04's QEMU, on x86_64. Homebrew on
Linux and the Arch packages are not: see
[What is tested](troubleshooting.md#what-is-tested).
