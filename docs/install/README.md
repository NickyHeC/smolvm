# Installing smolvm

One command on macOS and Linux, then a boot you can prove. A version number alone proves nothing:
on every platform there is at least one way for the install to succeed and every VM start to fail,
which is why this topic ships a preflight and a boot check rather than a download link.

`SKILL.md` is the procedure an agent follows. `references/packaged-installs.md` has the
distribution packages, `references/layout.md` says where the files land, `references/traps.md`
carries the failures that cost the most time, and `references/windows.md` is the Windows route.

## Install

```bash
curl -sSL https://smolmachines.com/install.sh | bash

# for coding agents: install, then read the full reference
curl -sSL https://smolmachines.com/install.sh | bash && smolvm --help
```

The installer takes the newest published release. A later release is expected to work with these
pages; `SKILL.md` records the version each claim was last verified on.

## Where it puts things

| Path | What |
|---|---|
| `~/.smolvm` | the binary and its bundled libraries (`INSTALL_PREFIX`) |
| `~/.local/bin/smolvm` | the launcher on your `PATH` (`BIN_DIR`) |
| `~/Library/Application Support/smolvm` (macOS), `~/.local/share/smolvm` (Linux) | the agent rootfs and the machine registry |
| `~/Library/Caches/smolvm` (macOS), `~/.cache/smolvm` (Linux) | per machine disks and pulled layers |

Downloading a release by hand puts the binary wherever you choose, and `~/.local/bin` is the
directory the installer uses and the one already on most `PATH`s. `references/layout.md` has the
full tree, including what an uninstall leaves behind on purpose.

**To install without touching an existing copy**, point `HOME` at a scratch directory: every path
above moves with it on macOS and Linux. Keep that directory shallow on macOS, because a VM's agent
socket path has about 100 bytes to work with and a deep `HOME` fails every boot with an error that
blames disks.

## Windows

Download the `windows-x86_64` release, which bundles `krun.dll` and `libkrunfw.dll`, unzip it and
run `smolvm.exe`. It needs the Windows Hypervisor Platform feature enabled. State cannot be
relocated on Windows; `references/windows.md` has the three differences that break a Unix-shaped
script.

## Packaged installs

Arch, Debian and Ubuntu, Fedora, Nix and NixOS have packaged trees in
`references/packaged-installs.md`. They are not the supported route and they lag the release.

## Prove it works

```bash
scripts/preflight.sh      # expect result=ready
scripts/verify-boot.sh    # expect result=boot_ok
scripts/cleanup.sh        # expect machines=clean
```

The preflight is read-only and names the two blockers that do not announce themselves later: a user
who cannot open `/dev/kvm` on Linux, and a `HOME` too deep for a VM socket on macOS.
