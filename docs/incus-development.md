# Work on Incus itself

The VM runs Incus from its `main` branch, or from your own changes, so that
you test them against everything the testbed has: virtual machines, Ceph,
BGP and `task check`. Three ways in, from the least work to the most:

| Way | With | The VM's incusd is |
|---|---|---|
| The daily build | `task up -- --daily` | Zabbly's `daily` package, built from `main` every night |
| A clone | `task up -- --source [REF]` | built in the VM from a clone of `INCUS_GIT`, upstream's unless you say, at `REF`, `main` unless you say |
| Your checkout | `INCUS_SRC=DIR task up -- --source` | built in the VM from `DIR` on your computer, mounted |

The other options go with all three: `--ceph`, `--bgp`, a channel and a
size. The building follows upstream's
[Install Incus from source][from-source].

```sh
task up -- --source --ceph                     # main, with Ceph
task up -- --source refs/pull/1234/head        # a pull request
INCUS_GIT=https://github.com/you/incus task up -- --source my-branch
INCUS_SRC=~/src/incus task up -- --source      # your checkout
```

## The daily build

`--daily` is the `daily` channel of [Zabbly's packages][zabbly], untested
builds of `main` from every night. It needs no build and updates with
`apt`, as the other channels do. It is the quickest way to try what `main`
has; for a change of your own, build it.

## How a build runs

`task up -- --source` makes a VM of the usual size, 2 CPUs and 2 GiB,
unless you give one, on the `daily` channel, unless you give one. While
the VM is made,
`provision/incus-source.sh`:

1. installs upstream's Debian packages for the build, the test suite's,
   and `ceph-common`;
2. takes Debian's Go with `GOTOOLCHAIN=auto`, which fetches the Go that
   `go.mod` asks for;
3. clones `INCUS_GIT` at `REF` into `~/incus`, or takes the mounted
   checkout as it is;
4. runs `make deps`, for raft and cowsql, and `make`, as your user in the
   VM;
5. installs Delve, for `task debug`;
6. copies the build to `/opt/incusdev`, and starts it in place of the
   package's `incusd`.

The package stays for everything but `incusd`: QEMU, the firmware, lxcfs,
the agents for other systems, the web UI and the LXC hooks. Two systemd
drop-ins, `incusdev-source.conf` for `incus.service` and
`incus-startup.service`, start the build with the package's own wrappers,
which get `/opt/incusdev` in front of `/opt/incus`. In the VM, `incus` is
the build's client too.

The default size builds Incus: on 2 CPUs and 2 GiB a first build, with
`make deps`, takes 78 s and needs about 1.1 GiB of memory. More CPUs make it
faster, 48 s on 6: `task up -- --source --cpus 6 --memory 4`. Go's
temporary files go to the disk, since `/tmp` is a tmpfs of half the memory.
A rebuild only compiles what changed; measured on 6 CPUs:

| `task build` after | Takes, with the restart |
|---|---|
| no change | 7 s |
| an edit in `cmd/incusd` | 12 s |
| a new API extension in `internal/version` | 14 s |
| `-- --debug`, from an optimized build | 24 s |

`task status` says which `incusd` runs:

```
>>> Incus in the VM:
  incusd             7.6, from source                  v7.6.0-330-g8101d95ef8
```

## The loop: edit, build, test

```sh
task build                       # make, and restart incusd from it
task build -- refs/pull/1234/head    # a clone: check out a ref first
task check                       # the end-to-end test, on the build
```

`task build` builds what the VM builds from: your checkout as it is, with
your edits, or the clone. It restarts `incusd`, and running instances stay
up. A build that fails leaves the running one in place and prints the end
of the log, which is in `/opt/incusdev/build.log` in the VM.

`task build -- --package` goes back to the package's `incusd`, and
`task build` comes back to the build. A restart of the VM keeps the
choice.

## Downgrades

A newer `incusd` may update the database schema when it starts; upstream
[warns][upgrade] that an older one may then find the database invalid, and
that going back needs the backup it kept in `/var/lib/incus/database`.
`task build -- --package`, and a build of an older ref, can be such a
downgrade. `task build -- --package` tries the package's `incusd`, and goes
back to the build when it does not start. `task reset` is the way back in
any case: the copy it starts from was saved after the first build.

## A debugger

`task build -- --debug` builds without optimizations, with upstream's
`make debug`, so that Delve can step through every line and see every
variable. `task debug` attaches Delve to the running `incusd`, in the VM,
and Lima forwards it to `127.0.0.1:26873` on your computer. `incusd` goes
on serving until the debugger stops it; `task debug -- --stop` detaches,
and so does a `task build`.

```sh
task build -- --debug
task debug
```

Then attach from your editor. The source path in the build is the one in
the VM: your checkout's own path with `INCUS_SRC`, which is mounted at the
same path, so no mapping is needed. For a clone, map `~/incus` in the VM,
`$(limactl shell incusdev sh -c 'echo $HOME')/incus`, to a checkout of the
same commit on your computer.

VS Code, in `.vscode/launch.json` of the checkout:

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "incusd in incusdev",
      "type": "go",
      "request": "attach",
      "mode": "remote",
      "host": "127.0.0.1",
      "port": 26873
    }
  ]
}
```

GoLand: Run, Edit Configurations, Go Remote, host `127.0.0.1`, port
`26873`.

Leave a debugging session by disconnecting, and do not let the editor kill
the process it is attached to: that is `incusd`, which systemd then starts
again, without Delve.

## The client on your computer

`task incus` adds the remote `incusdev` to the `incus` client on your
computer; see [Access](access.md). Homebrew's client may be older than the
build. `task incus -- --client` builds the client from the VM's source for
your computer, in the VM, so no Go is needed here, and puts it in
`~/.local/bin/incus-dev`, beside the `incus` you have:

```sh
task incus -- --client
incus-dev list incusdev:
```

## The test suite

The VM has upstream's test suite's packages. Its daemons run beside the
VM's own `incusd` and keep their state on a tmpfs; they find no QEMU, so
they run no virtual machines. In the VM, in the source, with the
environment of the build:

```sh
limactl shell incusdev
cd ~/incus          # or your checkout's path
export GOTOOLCHAIN=auto
export LD_LIBRARY_PATH="$HOME/go/deps/raft/.libs/:$HOME/go/deps/cowsql/.libs/"
cd test && sudo -E env "PATH=$PATH:$HOME/go/bin" "GOPATH=$HOME/go" \
	"LD_LIBRARY_PATH=$LD_LIBRARY_PATH" INCUS_BACKEND=ceph \
	INCUS_CEPH_CLUSTER=ceph INCUS_TMPFS=1 ./main.sh storage_driver_ceph
```

`main.sh` takes the name of a test in `test/suites`; without one it runs
all of them. `INCUS_BACKEND=ceph` needs a VM made with `--ceph`;
[the suite's README][test-readme] lists its other settings.

## Why build in the VM

`incusd` links liblxc, cowsql and raft from the Linux system it is built
on: macOS cannot build it, and a build from another Linux does not match
the VM's libraries. The mount is writable because the test suite writes
into the source tree.

## An existing VM

`--source` is chosen when the VM is made; for a VM made without it, run
`task destroy` and `task up -- --source`. `task reset` keeps the mount, and
goes back to the first build. For a VM made before `INCUS_SRC` was set,
without `--source`, add the mount for the test suite to it and to the copy
that `task reset` starts from:

```sh
task down
limactl edit --tty=false incusdev --mount "$INCUS_SRC:w"
limactl edit --tty=false incusdev-base --mount "$INCUS_SRC:w"
task up
```

[from-source]: https://linuxcontainers.org/incus/docs/main/installing/#install-incus-from-source
[upgrade]: https://linuxcontainers.org/incus/docs/main/installing/#upgrade-incus
[zabbly]: https://github.com/zabbly/incus
[test-readme]: https://github.com/lxc/incus/blob/main/test/README.md
