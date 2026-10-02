# Updates

How newer versions get in, and how to check one before it is merged.

## What Renovate proposes

[Renovate](https://docs.renovatebot.com) reads `renovate.json` and opens a
pull request when one of four versions has a newer release. The goal is that
no version in the project goes stale unnoticed, and that each change arrives
alone, so that a failing test points at one cause.

| Version | Where it is set | Applies | Check with |
|---|---|---|---|
| Debian image build | `lima.yaml` | when the VM is created | a new VM |
| Incus LTS channel | `provision/incus.sh` | when Incus is installed | a new VM |
| Ceph release | `provision/ceph.sh` | when Ceph is installed | a new VM |
| Alpine release of the test | `provision/check.sh` | on every test | the running VM |

The same versions are mentioned in the README, and Renovate changes them
there too.

Renovate has to be running against the repository for any of this to happen.
`renovate.json` is only its configuration.

## Check a pull request

Nothing tests a pull request by itself: the test needs a machine with nested
virtualization. Do it by hand, on the branch of the pull request.

For the Debian image, Incus or Ceph, build a new VM:

```sh
git switch <branch>
task destroy
task up
task status        # follow the install; it ends with the services
task check
```

For Alpine, the running VM is enough:

```sh
git switch <branch>
task check
```

Merge when `task check` ends with `All good on this computer too.`

## A new Ceph release

Renovate proposes a new Ceph release only once Ceph has made a stable version
of it. The pull request changes the image tag and nothing else: the install
asks the cluster which release it is and takes the Ceph client from the
Proxmox repository of that name.

Check it as any other: a new VM and `task check`. If Proxmox has no repository
for the release yet, the install stops and says so. Then wait, and leave the
pull request open.

## What a version does not pin

Three of the four versions choose a stream, not an exact build. What is
installed is decided on the day of the install:

| Set in the project | Installed |
|---|---|
| The Ceph image tag, `v20` | the image behind that tag, which is rebuilt every week |
| The Incus channel, `lts-7.0` | the newest build in that channel |
| nothing | the newest kernel in trixie-backports, Ceph client and Debian packages |

So two VMs built from the same commit a week apart can differ, and no pull
request says so. This is a choice. The Ceph image could be pinned to one
build, by its digest or by its dated tag, and Renovate would then propose
every weekly rebuild. But its maker removes old builds after about four
weeks, so a pin that nobody updates breaks every new install. Pinning is only
right once Renovate runs against the repository and someone merges every
week. Until then the tag stays, and a new VM is checked instead.

## Check a rebuild

To see that a new VM works with whatever is current, and what it got:

```sh
task destroy && task up
task status
task check
limactl shell incusdev sudo ceph versions    # the Ceph release, cluster and client
limactl shell incusdev podman image ls --digests --format '{{.Repository}}:{{.Tag}} {{.Digest}}'
limactl shell incusdev incus version
limactl shell incusdev uname -r
```

`task check` is the test; the four lines after it are the record. Keep them
with the date when a build has to be told apart from another.

`task reset` does not do this. It puts back the copy saved at the last
install, which is as old as that install. Only `task destroy` and `task up`
fetch what is current.

## See what Renovate would do

Without a running Renovate, or to test a change to `renovate.json`:

```sh
npx --package renovate renovate-config-validator renovate.json
RENOVATE_CONFIG_FILE="$PWD/renovate.json" LOG_LEVEL=debug \
	npx renovate --platform=local | grep -E '"(depName|currentValue|newValue)"'
```

The first command checks the file. The second looks every version up and
prints what it found and what it would change; it changes nothing. It needs
`RENOVATE_CONFIG_FILE`, because in this mode Renovate does not read the
file from the repository.

## What nothing updates

- **The tools in the Brewfile.** They are not pinned; `brew upgrade` is yours.
- **The kernel from trixie-backports.** A new VM gets the newest one.
- **Debian itself.** A move to the next release is a change to make by hand:
  the image in `lima.yaml`, the repositories in the scripts.
