---
name: pack
description: Turns an image, or a machine already provisioned, into a single self-contained artifact that runs on another compatible host. Use when shipping a prepared environment as one file, when a packed artifact runs but the state installed into it is missing, when pack create --from-vm fails with a ready timeout that names nothing, when an export is refused because the machine is a fork clone, or when deciding whether to pack from an image or from a machine. Do not use it to keep a machine you re-enter, which is the dev-env packet, or to run untrusted code, which is the sandbox packet.
---

# Packing a machine into a portable artifact

Verified on **smolvm v1.18.2** on macOS arm64, 2026-09-24, and on **v1.14.6** on Linux aarch64,
2026-09-11; the Linux host could not run the packing steps on v1.18.2, for the reason in
"Re-verified on v1.18.2". Done means the
artifact runs a command in a real VM and, for a machine pack, **the state you installed is still
inside it**.

**The assertion that matters is a value, not a boot.** A pack that lost its rootfs still boots,
still prints a guest kernel and still exits zero. The only thing that separates a good artifact
from an empty one is a marker written into the source machine before packing and read back out of
the artifact afterwards, which is what `pack-machine.sh` and `verify-pack.sh` do between them.

## Procedure

**1. Preflight.** Read-only: starts no VM, packs nothing.

```bash
scripts/preflight.sh
```

The line to read is `exporter_memory_ok`. `pack create --from-vm` starts an exporter VM whose
memory is **hardcoded to 8192 MiB** with no flag and no environment variable, and on a host that
cannot give it that the export fails as `agent did not become ready within 30 seconds`, which
mentions neither memory nor the exporter. **This preflight is the only place that failure has a
name.** It is a warning and not a gate, because the figure is a cap rather than a reservation: see
"What the memory line does and does not promise". **On v1.16.1 it misfires more often than it
fires**: `pack create --from-vm` now prints `Reusing the machine's cached image layers...` and on
macOS arm64 completed in 1.2 s with `exporter_memory_ok=no` reported by the same preflight
moments earlier, 2026-09-15.

**2. Pack from an image**, when you want a runnable artifact of a stock image.

```bash
scripts/pack-image.sh                       # alpine, ./from-image
scripts/pack-image.sh python:3.12-alpine ./mypack
```

This path starts no exporter, so the memory line does not apply to it. **If you pass a custom
output, pass it to the verify step too** (`verify-pack.sh --image ./mypack`), or that step finds
nothing at its defaults and tells you so rather than passing.

**3. Pack from a machine you provisioned**, when the point is the state in it.

```bash
scripts/pack-machine.sh                     # smolskill-golden, ./from-vm
```

It creates the machine with a workload that stays up, waits for a value from it, writes a marker,
**asserts the marker on the source**, stops the machine and exports it. The source assertion is
not ceremony: packing a machine whose provisioning silently failed produces an artifact that runs
perfectly and contains nothing, and nothing downstream will tell you.

**Packing a machine that already exists**, the user's own rather than one `pack-machine.sh` made:
the script refuses any name without the `smolskill-` prefix, so run its sequence by hand. The
machine has to be stopped, since `--from-vm` packs a stopped machine's snapshot.

```bash
smolvm machine exec --name myapp -- sh -c 'echo PACKED_STATE_PRESENT > /marker.txt'
smolvm machine exec --name myapp -- cat /marker.txt          # assert it on the source first
smolvm machine stop --name myapp
smolvm pack create --from-vm myapp --output ./myapp-portable --single-file   # one file, no sidecar
scripts/verify-pack.sh --machine ./myapp-portable            # reads /marker.txt back out of it
smolvm machine start --name myapp && smolvm machine exec --name myapp -- rm -f /marker.txt
```

`verify-pack.sh --machine` works on a `--single-file` artifact as it does on a stub with a sidecar.
A stranger given only this packet and "ship this provisioned machine as one file" took this route
on v1.18.2, and the 58.8 MiB artifact printed the machine's own `/root/PROOF.txt` on another run.

**4. Verify.** Both halves.

```bash
scripts/verify-pack.sh
```

```
image_pack_is_a_vm=ok (Linux)
image_pack_second_run=ok (SECOND_RUN_OK)
pack_cache_entries=2
image_pack_reused_cache=ok (2)
machine_pack_carried_rootfs=ok (PACKED_STATE_PRESENT)
machine_pack_is_a_vm=ok (Linux)
result=artifacts_good (2 of 2 artifacts)
```

`machine_pack_carried_rootfs` is the load-bearing line. The rest is context.

**Verifying nothing is not a pass.** Point it at artifacts that are not there and it says
`result=nothing_verified` and exits non-zero, because a green line over zero artifacts is the same
false clean the marker exists to prevent.

**5. Clean up.**

```bash
scripts/cleanup.sh --purge --artifacts ./from-image ./from-vm
```

It prunes each recorded machine while it still exists, deletes it, removes both stubs and their
sidecars, and runs `pack prune`. **`smolvm machine prune` with no argument does not run on this
release**; the form is `--name <NAME>`.

## Forwarding the SSH agent to an artifact

From v1.18.1 the artifact's own `run` and `start` take `--ssh-agent`, the same bridge `machine
run` has: the guest gets `SSH_AUTH_SOCK=/tmp/ssh-agent.sock` and the host agent signs, so no key
enters the artifact or the VM.

```bash
./from-image run --net --ssh-agent -- sh -c 'apk add -q openssh-client; ssh-add -l'
./from-image start --net --ssh-agent
./from-image exec -- ssh-add -l
```

Measured on macOS arm64 on v1.18.2 with a throwaway key in a throwaway agent: both forms listed
that key's fingerprint from inside the guest, a `run` without the flag had `SSH_AUTH_SOCK` unset,
and with the host variable empty the flag stops before booting with
`--ssh-agent: SSH_AUTH_SOCK is not set. Start an SSH agent with: eval $(ssh-agent) && ssh-add`.
**Forward the agent only to an artifact you trust**: the guest can ask for signatures for as long
as it runs, and an artifact is a filesystem somebody else prepared.

## What an artifact is, and what it carries

A pack is **two files**: a stub binary and a `<stub>.smolmachine` sidecar. `--output` names the
**stub**; the sidecar is created for you. Keep them together.

```
Mode:       container
Image:      python:3.12-alpine
Platform:   linux/arm64
CPUs:       4
Memory:     8192 MiB
Checksum:   94baf297
```

That `Memory` is the **packed artifact's** runtime memory, which `pack create --mem` can set. It
is not the exporter's, which nothing can set.

## What the memory line does and does not promise

The exporter's 8192 MiB is a **cap, not a reservation**, so a host reporting less available memory
can still export. Measured on this release: the export succeeded on a Mac whose preflight reported
`free_memory_mib=4990`, well under the figure, and it is the binding constraint on a small Linux
box where it fails with the unnamed ready timeout. So the preflight **warns and does not block**,
and `result=ready` with `exporter_memory_ok=no` means "this may work, and if it does not, here is
why".

## Traps

Full detail with the evidence in `references/traps.md`. The ones that cost the most:

- **`--output` names the stub, not the sidecar.** Passing `--output foo.smolmachine` fails; the
  scripts refuse it before the CLI does.
- **"One file" needs `--single-file`, and the default is two.** By default `pack create` writes the
  stub plus a `.smolmachine` sidecar and the CLI says `Note: Keep the .smolmachine file alongside
  the binary`; the stub on its own prints smolvm's usage and exits. `--single-file` writes one
  executable with no sidecar, and its own help warns it `may have issues with macOS notarization`.
  Verified on macOS arm64 on v1.16.1: the default stub alone failed in a fresh directory and
  printed `CARRIED` once the sidecar was beside it; the `--single-file` artifact, 59806048 bytes,
  printed `CARRIED` alone.
- **The stub takes a subcommand, and a bare `--` is rejected** with a tip that does not mention
  `run`. The working form is `./from-vm run -- sh -c '...'`.
- **`pack run` takes `--sidecar <PATH>`, not a positional path**, and getting it wrong reports
  that your sidecar is not an executable in `$PATH`.
- **Reported sizes understate the stub on disk**, by about 8.4 MB on Linux aarch64 and about
  10 MB on macOS arm64, where an extra signing step runs. The sidecar figure is accurate.
- **A branched machine packs on v1.16.1, and carries both states.** This was refused at export on
  v1.14.6; #1251 closed it. Verified on macOS arm64 on 2026-09-15: start the source
  `--branchable`, `machine branch --from <src> --name <child>`, write a marker in the child, stop
  it, `pack create --from-vm <child>`, and the artifact prints the source's `BASE_STATE` and the
  child's `CHILD_ONLY`. The branch must be stopped before it will pack.
- **Branchability is decided at `machine start`, not at `create`.** `machine branch` against a
  machine started without it refuses with `was not started as branchable, so it has no
  copy-on-write memory to branch from ... branchability is decided at start time and cannot be
  turned on for an already-running machine`, and `machine create --branchable` is not a flag.
- **A checkpoint restore packs and carries its rootfs**, and the restore path is
  `machine create --from`. There is no `machine restore` subcommand. **Taking the checkpoint needs
  `--branchable` on macOS**: without it v1.16.1 and v1.18.2 fail with `guest RAM has no
  file-backed regions`, which names neither the flag nor the precondition. Linux aarch64 took one
  without it on v1.18.2. A machine created from a pack can be checkpointed from v1.18.0, and
  `create --from` restores the newest generation a checkpoint carries; `--at ~N` picks an earlier
  one, which `branch-and-checkpoint` covers.
- **On Linux, `SMOLVM_DATA_DIR` moves where the agent rootfs is looked up and the installer does
  not write it there**, so an isolated data root needs the rootfs copied in before the first boot.

## Security defaults, and why they are the defaults

- **An artifact is a filesystem you are handing to someone else.** Whatever was in the source
  machine's rootfs is in the sidecar, including anything a provisioning step left in a shell
  history, a cache, or a file under `/root`. The marker this packet writes is deliberately inert;
  treat anything else you put in the source as published.
- **Packing does not narrow what the artifact may do.** The recorded entrypoint, network setting
  and memory come from the source, so a machine created with `--net` produces an artifact that
  expects a network. Decide that on the source, not afterwards.
- **The scripts pack only a machine they created**, named under the `smolskill-` prefix and
  recorded in a state file, and cleanup deletes only those. A machine you or another session made
  by hand is never exported and never deleted.
- **`pack run` takes the forked boot path**, so a cancelled run leaves a VM the CLI cannot see.
  `cleanup.sh` is the way to stop one, and its process scan catches both VM shapes. Ctrl-C is not.
- **Nothing here escalates privilege**, edits smolvm configuration or touches `~/.smolvm`.

## Platform arms

- **macOS arm64**: verified on v1.18.2, including the SSH agent forwarding and a pack of a
  restored machine. An extra `Signing binary with hypervisor entitlements` step runs here that
  does not on Linux.
- **Linux aarch64**: verified on v1.14.6. Not re-run on v1.18.2: the host could not boot the pull
  helper in time, see below.
- **Linux x86_64**: verified in the material behind this packet on v1.14.6, including the branched
  and restored cases. Not re-run here.

**Both hosts run here produce `linux/arm64` artifacts**, so two hosts is two hosts and not two
artifact architectures. The `linux/amd64` side rests on the x86_64 run above.
- **Windows x86_64**: `references/windows.md`, **re-run on 2026-09-11 against v1.14.6** on
  Windows 11 Home build 10.0.26200.0 UBR 9445. Both paths work: the image pack, and `--from-vm`
  for the first time there, with the marker read back out of the artifact. The stub is written
  without `.exe` and will not run until it and its sidecar are renamed.

## Eval prompts, and what they produced

Run 2026-09-11 PT against v1.14.6 from the published release, on macOS 26.6.2 arm64 and Lima
`linux-kvm` (Ubuntu 24.04 aarch64). Output is verbatim.

**1. "Ship this provisioned machine to another host as one file."**

Both hosts, through `pack-machine.sh` then `verify-pack.sh`:

```
source_marker=PACKED_STATE_PRESENT
result=packed

machine_pack_carried_rootfs=ok (PACKED_STATE_PRESENT)
machine_pack_is_a_vm=ok (Linux)
result=artifacts_good
```

macOS produced a 31572 KB sidecar in 3 s, Linux aarch64 a 31491 KB sidecar in 32 s.

**2. "The artifact runs fine but the thing I installed is not in it."**

That is the failure this packet is shaped against, and the answer is that running proves nothing.
`verify-pack.sh` asserts the marker rather than the boot, and `pack-machine.sh` refuses to export
at all if the marker is not on the source first:

```
result=FAILED the source does not carry the marker, so packing it would produce an empty artifact
```

The image pack is the control: it runs and does not carry the machine's state.

**3. "`pack create --from-vm` fails with `agent did not become ready within 30 seconds` and says
nothing else."**

Run the preflight, which is the only place that failure is named:

```
exporter_memory_mib=8192
free_memory_mib=4990
exporter_memory_ok=no
note=free memory is below the exporter's fixed 8192 MiB. If pack create --from-vm fails with
'agent did not become ready within 30 seconds', that is this, and the message will not mention
memory. Packing from an image starts no exporter and is unaffected.
```

On the hosts here the export then **succeeded anyway**, on the Mac reporting 4990 MiB, which is
why that line warns rather than blocks.

## Re-verified on v1.18.2

Run 2026-09-24 PT against v1.18.2 from the published release, under an isolated `HOME`, on macOS
26.6.2 arm64 and Lima `linux-kvm` (Ubuntu 24.04 aarch64).

**macOS: full pass.**

```
exporter_memory_ok=no                   (free_memory_mib=2707, a warning and not a gate)
result=packed                           (image, 4.5 s; stub_understated_kb=10516)
source_marker=PACKED_STATE_PRESENT
  Reusing the machine's cached image layers...
result=packed                           (machine, 1 s of export)
image_pack_is_a_vm=ok (Linux)
image_pack_second_run=ok (SECOND_RUN_OK)
machine_pack_carried_rootfs=ok (PACKED_STATE_PRESENT)
result=artifacts_good (2 of 2 artifacts)
```

The SSH agent forwarding in the section above was measured in the same session. So was a
restore: a machine created from `from-vm.smolmachine`, started `--branchable`, a marker written,
`Checkpointed ... (43 MiB written, 4.043s total, 0.652s source pause)`, restored with
`machine create --from <file>.smolcheckpoint`, started, the marker read back, and
`pack create --from-vm` of the restored machine finished in 2.3 s with an artifact that printed the
marker.

**Linux aarch64: not run, for a host reason.** `pack create --image alpine` failed with `agent did
not become ready within 30 seconds`, with or without `--mem 1024`, because the pull helper does not
take `--mem`; the golden machine's start failed the same way. That box could not boot guests above
2048 MiB in time that day, on v1.16.1 as well, which the `install` packet's traps record. The
preflight reported `exporter_memory_ok=yes` there, since the host had 10386 MiB free: free memory
is not what failed, so read that line as a hint about the exporter only.

## What was not run

- **Cross-platform rehydration**, except for one pair. An arm64 stub built on macOS was carried to
  x86_64 Windows on 2026-09-11 and **the OS loader refuses it before any smolvm code runs**, so an
  artifact has to be built on the platform it will run on. Nothing tests the reverse direction, or
  two hosts of the same architecture on different operating systems.
- **`pack push`, `pack pull` and `pack inspect` against a registry.** Nothing here touched a
  registry.
- **Windows through these scripts.** `scripts/*.sh` are POSIX shell and do not run there; the
  2026-09-11 v1.14.6 run on Windows issued the CLI by hand. `references/windows.md` has it.
- **The branched source on aarch64**, and the restored source on Linux aarch64. The restored
  source was run on macOS on v1.18.2 and the branched one on v1.16.1; both are answered on Linux
  x86_64 in the material behind this packet.
- **SSH agent forwarding on Linux.** Measured on macOS only.
- **Linux aarch64 on v1.18.2**, as above.

## Related packets

- `dev-env` for producing the machine that gets packed, and for the `init`-runs-once semantics
  its provisioning depends on.
- `install` for the boot this assumes, and `teardown` for the wider cleanup.
