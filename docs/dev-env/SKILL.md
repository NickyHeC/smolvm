---
name: dev-env
description: Keeps a persistent smolvm machine with its dependencies already installed and re-enters it cheaply across sessions. Use when a project needs an isolated development environment that survives stop and start; when deciding what belongs in a Smolfile's init versus what has to run on every boot; when a package installed in a machine has vanished after a restart; or when exec answers "the container smolvm-<hash> is not running". Do not use it for untrusted code, which needs a machine that leaves nothing behind (see the sandbox packet), or for running a Docker daemon inside the machine (see docker-in-machine).
---

# A persistent dev machine

Verified on **smolvm v1.18.2** on macOS arm64 and Linux aarch64, 2026-09-24; the Linux run used
the Smolfile with `memory = 1024`, for the host reason in "Re-verified on v1.18.2". Done means a second `start` is fast, skips provisioning, and the packages installed in
the first session are still there.

The whole use case turns on one fact: **`init` runs once, not on every start.** The docs now say
so, under their own "When init runs" heading, but `smolvm machine create --help` still reads
"Run command on every VM start" at v1.18.2. The CLI is where the wrong promise survives, and
provisioning designed around it comes up missing on the second boot.

## Procedure

**1. Preflight.**

```bash
scripts/preflight.sh
```

Read-only. `restart_after_stop=verified` on macOS and Linux, and on Windows too as of v1.14.6.
The script covers macOS and Linux only, so its Windows note points at `references/windows.md`.

**2. Declare the machine.** `assets/dev.smolfile` is a working starting point, and the one
`verify-persistence.sh` is written against: it asserts the `app` user and the `/app` workdir that
file sets. `assets/python.smolfile` and `node.smolfile` are plainer examples without them.

```toml
image = "python:3.12-alpine"
net = true
cpus = 2
memory = 2048
volumes = ["./src:/app"]
init = ["sh -c \"id -un > /init-ran-as.txt\"", "adduser -D app"]
user = "app"
workdir = "/app"
```

**3. Create and bring it up.**

```bash
scripts/create-dev-machine.sh              # name defaults to smolskill-dev
scripts/create-dev-machine.sh smolskill-myproj ./my.smolfile
```

It creates the machine **with an explicit long-lived workload command**, records the name for
cleanup, starts it, waits for the workload container to answer with a value, and then reports what
actually happened rather than that nothing errored:

```
init_ran=yes
machine_running=yes
workload_ready_after_s=0
workload_ready=yes
init_ran_as=root
exec_user=app
workdir=/app
result=up
```

`init_ran_as=root` with `exec_user=app` is the correct outcome, not a bug: `init` provisions the
machine and runs as root regardless of `user`, while `exec` and `shell` run as `user`.

**4. Work in it.**

```bash
smolvm machine exec  --name smolskill-dev -- pip install --user requests
smolvm machine exec  --name smolskill-dev --user root -- sh -c 'mkdir -p /storage/keep'
smolvm machine shell --name smolskill-dev            # interactive, lands in workdir as `user`
```

**5. Prove it is worth keeping.**

```bash
scripts/verify-persistence.sh
```

It installs a package and records its **version**, seeds one file per filesystem, stops, starts,
and then asserts each value against what it recorded. A version comparison is the point: an import
that does not crash can be satisfied by a system copy and says nothing about your install.

**6. Clean up, when the machine is no longer wanted.** Not at the end of a setup: the machine is the
deliverable, so leave it stopped and tell the user its name.

```bash
scripts/cleanup.sh --purge
```

## What `init` and `user` actually do at v1.14.2

Observed, not inferred:

| question | observed |
|---|---|
| when does `init` run? | on the **first `start`**, not on `create`, and not again |
| second start | prints `Init already completed, skipping N command(s)` |
| which user runs `init`? | **root**, even with `user = "app"` set |
| which user runs `exec` and `shell`? | the Smolfile `user` |
| override per command | `machine exec --user root` works |
| is there `machine start --init`? | **no** |

## What survives a stop and start

| location | survives | why |
|---|---|---|
| pip `--user` packages | yes | under `$HOME`, on the overlay |
| `$HOME/...` files | yes | overlay |
| files written at `/` | yes | overlay |
| `/tmp` | **no** | `tmpfs` |
| `/storage/...` | yes | the ext4 disk itself |

The root filesystem is an overlay whose upper layer lives on the machine's ext4 disk, which is why
writes to `/` persist while `tmpfs` mounts do not.

## Traps

Full detail in `references/traps.md`. The three that cost the most:

- **`init` runs once.** `smolvm machine create --help` still says "Run command on every VM start"
  at v1.18.2 while `machine run --help` says the right thing, so the CLI contradicts itself in its
  own help output. The docs have been corrected and now say once. Anything that must be true on
  every boot, a bind mount above all, has to run in the command that needs it.
- **`exec` right after `start` can answer with a message rather than running.** If you see
  ``the container `smolvm-<hash>` is not running``, **check first whether the machine has a
  workload at all**: without a command, `create` uses the image's own CMD as the persistent
  workload, and for an interpreter image that exits at once, so there is no container to exec into
  and waiting will not help. Only when a long-lived workload is configured is this a readiness
  race, and then a short retry loop is the fix. Measured on a nested-virt aarch64 host on v1.14.6:
  1 exec in 20 failed that way with no command, 0 in 20 with an explicit long-lived one.
  **Re-measured on v1.16.1 on 2026-09-15 and it did not reproduce**: 0 of 20 with no command and
  0 of 20 with one, on macOS arm64 and on Lima aarch64 alike. **On v1.18.2 it is back on Linux**:
  1 of 20 with no command on Lima aarch64, 0 of 20 on macOS. Give a machine you intend to `exec`
  into a long-lived workload.
- **`machine shell` does not start a stopped machine**, despite its own help text saying it does.
  Still true on v1.18.2.
- **A machine that runs Tailscale or another carrier NAT VPN inside needs `--guest-subnet` at
  create.** Its default virtio-net link sits inside `100.64.0.0/10`, the VPN routes the gateway
  and resolver away, and every lookup fails. A Smolfile has no key for it at v1.18.2 and
  `machine update` cannot add it, so pass it on `create` next to `-s`:
  `smolvm machine create --name smolskill-dev -s dev.smolfile --guest-subnet 10.200.0.0/30`.

Two smaller ones: `create` is instant and proves nothing, because every failure lands on the first
`start`; and a host `volumes` mount is not writable by a non-root `user`, so build output has to go
somewhere else.

## Security defaults, and why they are the defaults

- **`user` in the Smolfile is what your workload runs as, and it is not root.** `init` running as
  root is the provisioning step, deliberately separated from the workload's identity. Keep them
  separate rather than setting `user = "root"` to make a mount writable: the mount carries host
  ownership, and running the workload as root to reach it hands root in the guest everything the
  mount exposes on the host.
- **A `volumes` mount is host authority handed to the guest**, so mount the narrowest directory
  that works and prefer `:ro` for anything the machine only reads. Treat root in the guest as
  untrusted: the VM boundary limits its direct access to the host, while every forwarded mount,
  port and network permission becomes part of the workload's authority.
- **`net = true` is outbound access for the whole machine.** A dev machine that only needs a
  package index does not need general egress; `--allow-host` scopes it.
- **These scripts wrap the public CLI only.** They edit no smolvm configuration and nothing under
  `~/.smolvm`, and cleanup deletes only names it recorded under the `smolskill-` prefix.

## Platform arms

- **Linux aarch64**: the scripts were run here on v1.18.2 with the Smolfile's memory at 1024 MiB,
  and on v1.14.6 at the Smolfile's 2048. **At 2048 on v1.18.2 the restart timed out**, for a host
  reason: see the re-verification section below.
- **macOS arm64**: the scripts were run here on v1.18.2 as shipped, and every check passed.
- **Linux x86_64**: verified in the material behind this packet, not re-run here.
- **Windows x86_64**: `references/windows.md`, **re-run on 2026-09-11 against v1.14.6** on
  Windows 11 Home build 10.0.26200.0 UBR 9445. Create, two stops and two starts, with a marker
  read back after each start: **a stopped machine starts again and its state survives**, where on
  v1.14.2 it did not. That page also carries the WHP device ceiling a Windows preflight needs:
  four `-v` mounts, three when a port is published.
- **`init` after a checkpoint restore**: not verified anywhere.

## Eval prompts, and what they produced

Run on 2026-09-07 PT against v1.14.2 from the published release, under an isolated `HOME`. Output
is verbatim.

**1. "Set me up a Python dev machine I can come back to, and prove the packages survive a
restart."**

macOS 26.6.2 arm64 and Lima `linux-kvm` (Ubuntu 24.04 aarch64) gave identical results:

```
init_ran=yes
machine_running=yes
workload_ready_after_s=0
workload_ready=yes
init_ran_as=root
exec_user=app
workdir=/app
result=up

workload_ready_after_s=0
installed_version=2.34.2
  Starting machine 'smolskill-dev' with 1 mount(s)...
  Init already completed, skipping 3 command(s)
  Machine 'smolskill-dev' running (PID: 58513)
init_ran_once=ok (yes)
package_version=ok (2.34.2)
home_file=ok (SURVIVES)
storage_file=ok (SURVIVES)
tmp_file=ok (WIPED)
exec_user=ok (app)
workdir=ok (/app)
result=persistent
```

**2. "My bind mount is gone after I restarted the machine. It is right there in `init`."**

`init` ran once. The Linux run shows the machine's own report of it:

```
Init already completed, skipping 3 command(s)
```

There is no `machine start --init`, so the mount has to be re-applied by the command that needs
it. `docker-in-machine` is the packet built entirely around this.

**3. "`smolvm machine exec` just told me the container is not running, but the machine is
running."**

Reproduced deliberately by creating the same machine without a workload command, then running 20
execs, on Lima:

```
 3: the container `smolvm-e51bb94127b751bf` is not running
failures=1/20
 4: the container `smolvm-32edffb50eaf0d20` is not running
failures_after_restart=1/20
```

and with the explicit long-lived workload `scripts/create-dev-machine.sh` passes:

```
failures=0/20
failures_after_restart=0/20
```

The changing hash is the tell: the workload container is being relaunched between execs.

## Re-verified on v1.18.2

Run 2026-09-24 PT against v1.18.2 from the published release, under an isolated `HOME`, on macOS
26.6.2 arm64 and Lima `linux-kvm` (Ubuntu 24.04 aarch64).

**macOS, as shipped: full pass.**

```
init_ran=yes / machine_running=yes / workload_ready=yes
init_ran_as=root / exec_user=app / workdir=/app / result=up
  Init already completed, skipping 3 command(s)
init_ran_once=ok (yes)
package_version=ok (2.34.2)
home_file=ok (SURVIVES) / storage_file=ok (SURVIVES) / tmp_file=ok (WIPED)
exec_user=ok (app) / workdir=ok (/app)
result=persistent
```

**Linux aarch64: the same values with `memory = 1024`.** With the shipped `memory = 2048` the
first start passed and the restart failed with `agent did not become ready within 30 seconds`, and
every check after it failed on `machine ... is not running`. That box could not boot guests above
2048 MiB in time that day and was borderline at 2048, on v1.16.1 as well, so the cause is the
host; the `install` packet's traps have the numbers. If a restart times out on a small or busy
host, lower `memory` before looking for a product fault.

**Also re-checked:** `machine create --help` still says `--init` runs "on every VM start";
`machine shell` against a stopped machine still answers `machine 'smolskill-dev' is not running.
Use 'smolvm machine start --name smolskill-dev' first.`; the no-command exec race was 0 of 20 on
macOS and 1 of 20 on Linux (``the container `smolvm-36c8a04bc9168bd1` is not running``).

**`--guest-subnet` on a persistent machine**, macOS: created with `-s dev.smolfile --guest-subnet
10.200.0.0/30`, the guest was `10.200.0.2/30` and reached `pypi.org`, and after a stop and start
still `10.200.0.2/30`. A Smolfile with `guest_subnet` under `[network]` is rejected with
``unknown field `guest_subnet`, expected one of `allow_hosts`, `allow_cidrs`, `credentials` ``.

## Re-verified on v1.14.6

Run 2026-09-10 PT against v1.14.6 on macOS 26.6.2 arm64 and Lima `linux-kvm` (Ubuntu 24.04
aarch64). **Full pass on both**, restart included:

```
init_ran=yes / machine_running=yes / workload_ready=yes
init_ran_as=root / exec_user=app / workdir=/app / result=up
init_ran_once=ok (yes)
package_version=ok (2.34.2)
home_file=ok (SURVIVES) / storage_file=ok (SURVIVES) / tmp_file=ok (WIPED)
result=persistent
```

The Linux arm was unconfirmed on v1.14.3 because that host was failing one plain boot in ten. It
is confirmed here.

## What was not run

- **Windows beyond the restart.** The 2026-09-11 v1.14.6 run covered create, stop and start and
  the marker. The WHP device ceiling and the scripted-driving pattern on that page are still from
  the earlier run.
- **Linux x86_64.**
- **`init` after a checkpoint restore.** Nowhere, on any platform.
- **The `USER` interaction still settling.** `init` runs as root at v1.14.2, and whether the
  image's own `USER` still governs it in some paths is open as
  [smolvm#1189](https://github.com/smol-machines/smolvm/issues/1189). Nothing here tested an image
  with a `USER` line.

## Related packets

- `install` for the boot this assumes, and `teardown` for the cleanup script.
- `docker-in-machine` for the clearest case of the `init`-runs-once trap.
- `pack` for turning the machine this packet builds into a portable artifact.
