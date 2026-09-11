# Packing on Windows

## Contents

- What was verified
- The template requirement the caveats describe is already satisfied
- The trap that makes `pack run` look broken
- What was never run here

**Not re-run by this packet.** Everything below was executed once on Windows 11 Home build 26200
x86_64 against smolvm v1.14.2 and is reproduced unchanged. The Windows host was not available when
this packet was written, and `scripts/*.sh` are POSIX shell and do not run there.

## What was verified

The image path works.

```powershell
& $exe pack create --image alpine --output "$dir\wpack"
& $exe pack run --sidecar "$dir\wpack.smolmachine" -- sh -c "echo PACK_RAN_OK"
& $exe pack run --sidecar "$dir\wpack.smolmachine" --info
```

Observed:

```
pack create  in 12.9s
Creating storage template...
Packed: ...\wpack (stub: 31615KB, total: 49851KB)
Assets: ...\wpack.smolmachine (18234KB compressed)

pack run     exitcode 0   PACK_RAN_OK
pack run --info            Platform: linux/amd64   Memory: 8192 MiB   Checksum: 1f7ced2a
```

## The template requirement the caveats describe is already satisfied

`AGENTS.md` says `pack create` on Windows "needs `storage-template.ext4` /
`overlay-template.ext4` beside `smolvm.exe` (Windows has no host `mkfs.ext4`)". **The release
ships both**, uncompressed at 536870912 bytes each, in the same folder as the exe, so the
requirement is met out of the box and needs no user action.

This is a real platform difference rather than a mistake in the caveat: the Unix releases ship
those templates as `.zst`, and Windows ships them expanded.

## The trap that makes `pack run` look broken

`pack run` returned **no output at all** under `Start-Process -RedirectStandardOutput`, which
reads as a silent failure. The same command through `cmd /c "... > out.txt 2>&1"` exits 0 and
prints `PACK_RAN_OK`.

**Do not conclude `pack run` is broken on Windows from an empty capture.** Check the invocation
first. This is the same captured-output shape that affects `machine start` there, which the
`install` packet's Windows page describes in full.

## What was never run here

- **`pack create --from-vm`.** Only the image path was run on Windows, so the exporter VM, its
  fixed memory and the state-carrying assertion this packet is built around are all unverified on
  that platform.
- **Cross-platform rehydration.** The Windows artifact was produced and run on Windows only.
- **`pack push`, `pack pull` and `pack inspect`** against a registry.
