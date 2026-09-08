# A dev machine on Windows

**Not re-run by this packet**, and the honest summary is short: **do not promise that a dev
machine on Windows survives a stop and a start.** Creating one and using it in a single session
works. Coming back to it did not.

Everything below was executed once on Windows 11 Home build 26200 x86_64 against smolvm v1.14.2.

## What works, and matches Unix exactly

```
create                  in 0.5s   Created machine: wd   Init commands: 2
first start             in 4.9s   Running 2 init command(s)...
init user / exec user   initran=root   execuser=app   workdir=/tmp
install requests        in 9.1s   2.34.2
stop                    in 0.4s   Stopped machine: wd
```

So `init` runs as root while the workload runs as the Smolfile `user`, identical to Linux and
macOS, and `init` runs once: the second start printed
`Init already completed, skipping 2 command(s)`.

## Where it stops

The second start then failed:

```
===== second start =====  in 1.2s
Init already completed, skipping 2 command(s)
Error: agent operation failed: start background CMD: agent operation failed:
pull image: Bad message (os error 74)
```

and the machine was left stopped, so package survival could not be checked at all:

```
Error: agent operation failed: connect: machine 'wd' is not running.
```

**Root cause, from `RUST_LOG=debug` with the state verified at each step:**

```
INFO agent VM is ready pid=21400 boot_ms=617.6924
INFO cached image is no longer usable; pulling it again before launching machine="wr" image=alpine
INFO stopping agent VM
DEBUG command failed error=... start background CMD: ... pull image: Bad message (os error 74)
```

Two linked faults. After a stop, smolvm decides the cached image is no longer usable and re-pulls
it, which it should not need to do. That re-pull then fails with `Bad message` even though the
identical pull succeeded minutes earlier on the first start. The agent VM itself boots in 617 ms,
so this is not a boot failure.

This is open as [smolvm#1196](https://github.com/smol-machines/smolvm/issues/1196), a follow-up to
[#1097](https://github.com/smol-machines/smolvm/issues/1097), which was closed as fixed in v1.14.0
and reproduces on v1.14.2. The reproduction depends on how much has been written to `/workspace`:
ubuntu restarts after 1 MiB or less and fails after 64 MiB, alpine fails after 512 MiB, and
`debian:bookworm-slim` fails with nothing written at all.

**So on Windows, treat a dev machine as a single-session machine.** If work has to survive, keep
it on the host through a `-v` mount rather than inside the machine.

## The device ceiling belongs in a Windows preflight

WHP gives the guest an eleven-IRQ budget, the same as Linux. Measured on the tested host:
**four `-v` mounts boot and five fail** with `no more IRQs are available`, and **any published
port costs one of those slots**, so four mounts plus two ports fails while two plus two boots.

A dev machine that mounts a source tree, a cache, a build output directory and a config directory
is already at the limit before it publishes a dev server's port.

## Driving it from a script

`machine start` never returns to a caller that captures its output: the background VM inherits
the parent's stdout handle. Use `Start-Process -RedirectStandardOutput` and poll `HasExited`. The
full measurement and the working pattern are in the `install` packet's `references/windows.md`.

State cannot be relocated on Windows, so a dev machine's disks land in `%LOCALAPPDATA%\smolvm`
and have to be removed by hand. See the `teardown` packet.
