# Plan: Incus from its main branch, and your own builds

Built, all phases in one pull request, and tested on macOS on Apple silicon:
see [Results](#results). How to use it is in
[Work on Incus itself](incus-development.md); this plan keeps the reasons
and the findings.

The goal: the VM's own `incusd` runs Incus from its `main` branch, or from
your own changes, so that you test them against everything the testbed
has: virtual machines, Ceph, BGP and the end-to-end test. Before, the VM
ran the packaged Incus, and Incus was built only to run its test suite
beside it.

Three ways in, from the least work to the most:

| Way | With | Incus is |
|---|---|---|
| The daily build | `task up -- --daily` | Zabbly's `daily` package, built from `main` every night |
| A clone | `task up -- --source [REF]` | built in the VM from a clone of `INCUS_GIT` at `REF` |
| Your checkout | `INCUS_SRC=DIR task up -- --source` | built in the VM from `DIR` on your computer, mounted |

After that `task build` rebuilds and restarts `incusd`, and with a ref
switches the clone to it first. `task debug` attaches Delve to the running
`incusd`, for a debugger on your computer, and `task incus` sets up the
`incus` client on your computer for the VM.

## What upstream says

The plan follows upstream wherever it can, and links to it rather than
copying it.

- [Zabbly's packages](https://github.com/zabbly/incus) have four
  repositories: `lts-6.0`, `lts-7.0`, `stable` and `daily`, "untested daily
  builds". `daily` is the same `.sources` file with another URI, and has
  Debian 13 for amd64 and arm64.
- [Install Incus from source](https://linuxcontainers.org/incus/docs/main/installing/#install-incus-from-source):
  the Debian build and runtime packages, a Go at least as new as `go.mod`
  asks (`main` asks 1.26, Debian 13 has 1.24), `git clone`, `make deps`
  for cowsql and raft in `$(go env GOPATH)/deps`, the environment it prints,
  `make`; then `incusd --group …` run with that `LD_LIBRARY_PATH`. 2 GiB
  of memory at the least for the build. Sub-ids for root, which the VM's
  boot step already gives.
- [Upgrade Incus](https://linuxcontainers.org/incus/docs/main/installing/#upgrade-incus):
  a newer `incusd` updates the database schema, keeps a backup in
  `/var/lib/incus/database`, and an older one may then find the database
  invalid. Going back means that backup, or here `task reset`.
- [The test suite](https://github.com/lxc/incus/blob/main/test/README.md):
  `sudo -E make check`, or `test/main.sh`, with `INCUS_BACKEND` and the
  other variables. The CI runs it on Ubuntu 24.04, amd64 and arm64, with
  MicroCeph for the `ceph` backend.
- [The devcontainer](https://github.com/lxc/incus/tree/main/.devcontainer)
  installs Delve with `go install github.com/go-delve/delve/cmd/dlv@latest`.
  The Makefile's `debug` target builds with the `logdebug` tag and passes
  `DEBUG` on to `go install`, so `make debug DEBUG='-gcflags=all="-N -l"'`
  gives a build without optimizations, which a debugger can step through.

## The approach: the package underneath, your incusd on top

The VM keeps Zabbly's package, and with `--source` its `daily` channel, for
everything but `incusd`: QEMU, the firmware, lxcfs, the agent, the web UI
and the LXC hooks, under `/opt/incus`. A systemd drop-in,
`/etc/systemd/system/incus.service.d/incusdev-source.conf`, starts the
built `incusd` in place of the package's, as upstream runs it: with the
`LD_LIBRARY_PATH` of `make deps`, and the paths that the package's wrapper,
`/opt/incus/lib/systemd/incusd`, gives (`INCUS_EDK2_PATH`,
`INCUS_AGENT_PATH`, `INCUS_UI`, `INCUS_LXC_HOOK`, `PATH` with
`/opt/incus/bin`).

The drop-in is the whole change to the package. Removing it brings the
package's `incusd` back, and an `apt upgrade` does not overwrite the build.

Not chosen: Incus from source alone, with Debian's QEMU, AAVMF and lxcfs.
That is closer to upstream's page, but a second way to install the whole
testbed, with an older QEMU.

## Decisions

| Question | Decision |
|---|---|
| The package underneath, or upstream alone | the package, `daily` |
| The task that rebuilds | `task build` |
| A clone of a fork | yes: `INCUS_GIT` takes any URL, `REF` any branch, tag, commit or `refs/pull/N/head` |
| When it builds | at `task up` with `--source`, and at `task build` |
| A debugger | Delve with `--source`; a debug build with `task build -- --debug`; `task debug` for one on your computer |
| The client on your computer | `task incus`, apart from `task dashboard` |
| btrfs, LVM, ZFS | not part of this plan |

## Phases

All phases go into one pull request, each tested on real VMs before the
next.

### 0. A spike, by hand

In a running VM, upstream's steps by hand, then the drop-in, then
`task check` and `task check -- --vm`. It answers what the rest depends on:

- Does a built `incusd` run with Zabbly's QEMU and lxcfs? Which comes first
  in `LD_LIBRARY_PATH`, the deps or `/opt/incus/lib`, and does Debian's
  liblxc or Zabbly's serve?
- Does the package's agent do for virtual machines, or must the build's?
- How long `make deps` and `make` take, and how much memory they need: on
  2 GiB, on 4 GiB.
- Does Delve attach to the running `incusd`, and through a Lima port
  forward from a debugger on macOS?
- Does `make client` build on macOS?

The answers go into this plan before phase 2.

**Findings, 2026-11-18,** in a VM made with `--bgp` on the 7.0 LTS, on
macOS on Apple silicon (M5), resized to 6 CPUs and 8 GiB:

- Upstream's packages install in 25 s. Debian's Go 1.24 with
  `GOTOOLCHAIN=auto` fetches the 1.26.9 that `go.mod` asks.
- `make deps` takes 18 s, `make` 46 s, on 6 CPUs. The largest single
  process, the Go linker, peaks at 1.1 GB. `~/go` holds 1.2 GB and the
  build cache 0.9 GB. `main` was `v7.6.0-330-g8101d95ef8`, Incus 7.6.
- `make deps` prints its `export` lines without the `#` that upstream's
  page shows; the script sets the same variables from the paths itself.
- The built `incusd` links Debian's liblxc and the deps' cowsql and raft.
  The client and the agent link no LXC; the agent is static.
- It runs as the VM's service through the drop-in: `systemctl restart
  incus` takes 2 s, and running instances stay up. With
  `LD_LIBRARY_PATH=/opt/incusdev/lib/:/opt/incus/lib/` it loads the deps'
  cowsql and raft and Zabbly's liblxc, which goes with the package's LXC
  hooks. The 7.6 build took over the 7.0 database.
- The drop-in, and the wrappers for `incusd`, `incus-startup` and the
  client, are made from the package's own with `sed`, so they follow it:
  `PATH` and `LD_LIBRARY_PATH` get `/opt/incusdev` in front, and
  `INCUS_AGENT_PATH` points to a copy of the package's agents with the
  build's for this architecture.
- `task check` and `task check -- --vm` pass on the build, with Ceph and
  the ToR: the virtual machine runs the built agent.
- Delve v1.27.2 installs in 17 s. `dlv attach PID --headless
  --accept-multiclient --continue`, as a transient unit, leaves `incusd`
  serving; stopping the unit detaches, and `incusd` runs on with the same
  PID. The server takes clients of its own user only (Delve's
  `--only-same-user`): root in the VM. Whether Lima's port forward
  arrives as root is tested with phase 5.
- The client for macOS builds in the VM in 8 s, with `GOOS=darwin
  CGO_ENABLED=0 go build ./cmd/incus`, and runs on the Mac. No Go is
  needed on your computer, and it works for a clone too.
- Sizes: the user asked for 6 CPUs and 8 GiB as the default with
  `--source` only. Measured at the end, see [Results](#results): 2 CPUs
  and 2 GiB build as well, once Go's temporary files are on the disk.

### 1. The daily channel

- `bin/up`: `--daily`, short for `--channel daily`, and `daily` allowed in
  `check_requirements`.
- `provision/incus.sh`: `daily` in the header.
- Docs: the options in `docs/usage.md` and the README; in
  `docs/updates.md` that `daily` changes every night and is untested.

### 2. provision/incus-source.sh

A new provision script, in the style of the others, that also runs by hand
on a Debian host. In order:

1. Upstream's Debian packages, the test suite's, and `ceph-common`.
2. Go: Debian's, with `GOTOOLCHAIN=auto` to fetch the one `go.mod` asks.
3. The source: `INCUS_SRC` where it is mounted; else a clone of
   `INCUS_GIT` (default `https://github.com/lxc/incus`) at `INCUS_REF`
   (default `main`) in the VM user's home.
4. `make deps` and `make`, as that user.
5. Delve, as the devcontainer installs it, but at a version pinned in the
   script for Renovate to raise, not `@latest`.
6. The drop-in, `systemctl restart incus`, `incus admin waitready`.

Safe to run again, as Lima runs it on every start: with a build and the
drop-in in place it does nothing, so a restart does not rebuild. It does
nothing in a VM made without `--source`.

### 3. task up -- --source

- `bin/up`: `--source [REF]`, a `SOURCE` setting in `lima.yaml` kept for
  the VM's life, like `CEPH`; `INCUS_GIT` and `INCUS_REF` passed in.
  `--source` takes `daily` unless a channel is given, and a larger default
  size, from what the spike measured.
- With `INCUS_SRC` set, `--source` builds the mounted checkout, and a
  `REF` is an error.
- The copy for `task reset` is saved after the first build: a reset goes
  back to it. A mounted checkout keeps your edits; a clone goes back too.
- `lima.yaml`: `provision/incus-source.sh` after `incus.sh`.

### 4. task build

- `task build`: in the VM, `make`, restart `incusd`, print
  `incus version` and `git describe --always --dirty`.
- `task build -- REF`: in a clone, `git fetch` and check out `REF` first.
- `task build -- --debug`: upstream's `make debug`, with
  `DEBUG='-gcflags=all="-N -l"'` (the Makefile puts it into a shell
  command as it is, so the quotes are needed), so that Delve can step through every line
  and see every variable. A plain `task build` goes back to the optimized
  build. `task status` says which one runs.
- `task build -- --package`: remove the drop-in and go back to the
  package's `incusd`. It refuses when the build's schema is newer than the
  package's, and points to `task reset` or the backup.
- On a VM made without `--source`, it says so.
- `task status`: one row for where `incusd` comes from, such as
  `Incus  7.1-dev from source, abc1234-dirty` or `Incus  7.0.2, lts-7.0`.

### 5. task debug

- `task debug`: in the VM, `dlv attach --headless --accept-multiclient
  --listen :2345` to the running `incusd`, as root; `-- --stop` detaches
  and leaves `incusd` running. A VM made without `--source` says so.
- `lima.yaml`: a port forward, `2345` to `127.0.0.1:26873`, the next in the
  block, kept in step with `print_services`.
- Docs: a launch configuration for VS Code and the settings for GoLand, to
  attach from your computer, with the path mapping: the same path for a
  mounted checkout, the VM's clone for a clone.
- Without `--debug` it still attaches; the docs say why stepping is then
  unreliable.

### 6. task incus

Today `task dashboard -- incus` adds the remote `incusdev` to the `incus`
client on your computer, as a side effect of opening the web UI. This
phase makes it a task of its own, and does not depend on `--source`:

- `ensure_remote` and `trust_token` move from `bin/dash-incus` to
  `share/incusdev-vm/`, for both.
- `task incus`: adds the remote `incusdev`, or replaces it when it no
  longer answers, and prints `incus remote list`.
- `task incus -- --default`: also makes it your default remote;
  `-- --remove` removes it, and its certificate in the VM.
- `task status`: the hint on the Incus API row points to `task incus`.
- If possible, `task incus -- --client`: builds the client from the same
  source for your computer, as `make client` does, so that a client and a
  server from `main` match. The client is pure Go and builds on macOS; the
  spike checks that, and where the binary goes without touching Homebrew's.

### 7. docs/incus-development.md

Rewritten around the three ways, with upstream's pages linked for the
packages and the Go version: the edit, `task build`, test loop; the test
suite as now; Delve and `task debug`; downgrades and how `task reset` and
the backup cover them. `task incus` goes into [Access](access.md).
This plan stays beside it, for the reasons and the findings.

### 8. Testing

For each way: a new VM, `task check` with a container and with `--vm`,
and `task build` after an edit. Then `--source` with `--ceph` and `--bgp`,
`task reset`, and `task build -- --package`. `task build -- --debug` and a
breakpoint hit from VS Code through `task debug`. `task incus` on a new VM
and after `task destroy`, and `--client` on macOS.

## Results

Tested on 2026-11-18, macOS on Apple silicon (M5), Lima with `vz`, each on
a new VM:

| VM | Tested |
|---|---|
| `--source --ceph --bgp`, a clone of `main` | ready in 5.5 min; `task check` with a container and with `--vm`; `task build` after no change, a daemon edit and a new API extension; `-- --debug`; `-- --package` and back; `-- v7.5.0` and `-- main`; `task debug` and a breakpoint hit through `127.0.0.1:26873`; `task build` while attached; `task incus` with `--default`, `--remove`, `--client`; `task routed`; `task reset`, then `task check` |
| `INCUS_SRC` and `--source`, a mounted checkout | ready in 3.5 min; a REF refused; an edit on the Mac built as `-dirty`; `task check` with a container and with `--vm`, on the local pool; Delve's client on the Mac: a breakpoint, the source from the Mac's checkout, `print r.URL.Path`; a cold build measured |
| `--daily` | ready in 1.5 min; `task check`; `task build`, `task debug`, `task incus -- --client` and `task up -- --source` refused; `task incus` and `--remove` |
| `task up`, the default | ready in 1.5 min, on `lts-7.0`; `task check`; `task incus` |
| `INCUS_GIT` a fork, `--source storage`, `--cpus 2 --memory 4` | the fork's branch at its commit; a cold build measured; `task check`; `-- --package` and a restart, `task build` and a restart; upstream's test suite, `certificate_edit`, with the command in the docs |
| `--source --bgp`, the final code | ready in 3 min; `task check` and `task check -- --vm`, with the ToR; `task routed -- --vm`; `task debug` with the Debug Adapter Protocol, as VS Code attaches with `mode: remote`: a breakpoint by source line verified and hit, `continue`, `disconnect` without ending `incusd`; then resized to 2 CPUs and 2 GiB, a cold build measured, and `task check` |

Cold builds, `make deps` and `make` with an empty cache:

| VM | Time | Memory in use, at the most |
|---|---|---|
| 6 CPUs, 8 GiB | 59 s | 2.7 GiB, from 0.4 |
| 2 CPUs, 4 GiB | 73 s | 1.8 GiB, from 0.3 |
| 2 CPUs, 2 GiB, with `GOTMPDIR` on the disk | 78 s | 1.1 GiB, from 0.3 |

Found and fixed on the way:

- `make debug DEBUG=…` needs shell quotes inside the value: the Makefile
  puts it into a shell command as it is.
- `go install dlv@…` fetches another Go unless `GOTOOLCHAIN` is the one
  Incus builds with.
- `check.sh` took the `ceph` command for Ceph, but `incus-source.sh`
  installs `ceph-common` without a cluster: it now looks for the pool.
- `git describe --dirty` on a mounted checkout can fail while the mount
  catches up with an edit: `--no-optional-locks` leaves the index alone.
- On 2 GiB the build failed: the linker filled `/tmp`, a tmpfs of half the
  memory. `GOTMPDIR` now points to the disk, and 2 GiB builds.
- `jq` was missing on a VM without Ceph, so `task dashboard` never removed
  old certificates; `incus.sh` installs it now.
- Delve halts the process before it sets a breakpoint; a client must ask
  for that, which Delve's own client and the editors do.
- The 7.0.2 package's `incusd` and a v7.5.0 build both started on a
  database that `main` had used: no schema downgrade between them. The
  fallback in `--package` stays for when there is one.
