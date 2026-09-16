# Where smolvm state lives, and what removes it

Observed on v1.14.2. The install prefix, the agent rootfs, the per-VM state and the pack cache were
at the same paths on v1.18.2, 2026-09-24.

| | macOS | Linux |
|---|---|---|
| install prefix | `$HOME/.smolvm` | `$HOME/.smolvm` |
| launcher symlink | `$HOME/.local/bin/smolvm` | `$HOME/.local/bin/smolvm` |
| agent rootfs | `$HOME/Library/Application Support/smolvm` | `$HOME/.local/share/smolvm` |
| per-VM state | `$HOME/Library/Caches/smolvm/vms` | `$HOME/.cache/smolvm/vms` |
| image cache, once `--oci-cache` has run | `.../smolvm/vms/_shared` | `.../smolvm/vms/_shared` |
| pack cache | `$HOME/Library/Caches/smolvm-pack` | `$HOME/.cache/smolvm-pack` |
| packed-binary lib cache | `$HOME/Library/Caches/smolvm-libs` | `$HOME/.cache/smolvm-libs` |
| registry cache | `$HOME/Library/Caches/smolvm-registry` | not seen |
| registry credentials | `$HOME/.config/smolvm` | `$HOME/.config/smolvm` |
| `PATH` block | your shell profile | your shell profile |

Checkpoints are not in this table because smolvm does not choose where they go: a
`.smolcheckpoint` file or a `--store` directory lives wherever `machine checkpoint -o` was pointed,
the uninstaller does not know about it, and it is removed with `rm -rf` once no machine will be
restored from it. `smolvm machine checkpoint-prune --store <DIR>` drops a store's unreferenced
objects without removing the store.

On macOS the VM cache also holds `_restore-base`, a clone of the last restored checkpoint with its
memory, which stays until removed by hand or by the uninstaller.

The last three are the ones people miss. `smolvm-libs` appears only once a packed `.smolmachine`
stub has run, and the last two are deliberately left by the uninstaller.

`scripts/preflight.sh` reports each of these with its size, so you know what a teardown has to
remove before you remove it.

## Relocating state, for a test run

On macOS and Linux every path above derives from `HOME`, so installing with `HOME` pointed at a
scratch directory keeps a test run entirely inside it. That is how the runs behind this packet
avoided touching a real installation, and `scripts/verify-clean.sh --protected <real prefix>` is
the assertion that proves it.

`SMOLVM_DATA_DIR` moves the data root on **Linux only**: the function that applies it is compiled
in for Linux and does not exist on macOS or Windows. On macOS `HOME` is still enough. On Windows
neither works, which is what makes that platform's teardown a manual removal. See
`references/windows.md`.

## Full removal

```bash
curl -sSL https://smolmachines.com/install.sh | bash -s -- --uninstall
```

Verified complete on macOS against an isolated `HOME` used for a full session of machines, packs
and `--oci-cache` runs:

```
success: Removed <HOME>/.smolvm
success: Removed symlink <HOME>/.local/bin/smolvm
success: Removed data directory <HOME>/Library/Application Support/smolvm
success: Removed cache directory <HOME>/Library/Caches/smolvm
success: Removed pack cache directory <HOME>/Library/Caches/smolvm-pack
warning: You may want to remove the PATH entry from your shell profile.
success: smolvm has been uninstalled
```

Afterwards `find "$HOME" -iname '*smolvm*'` returned nothing. It removes `smolvm-libs` too when
present.

**On v1.18.2 on macOS it also leaves `$HOME/Library/Caches/smolvm-registry`**, the registry cache,
and does not say so: after a full session of pulls, packs and restores the uninstaller printed
`smolvm has been uninstalled` and that directory was the one smolvm path left, found by
`find "$HOME" -iname '*smolvm*'`. Remove it by hand. The same session's uninstall on Linux aarch64
left nothing, and no such directory had been created there.

The two things it deliberately leaves, both of which it warns about:

```bash
# 1. the PATH block it added to your shell profile
sed -i.bak '/# smolvm/,+1d' ~/.zshrc     # or ~/.bashrc; read the file before running this

# 2. registry credentials, if you ever logged in to a registry
rm -rf ~/.config/smolvm
```

`--uninstall` is documented only in `scripts/install.sh --help`, not in the README or on the docs
site.

## Reclaiming space without uninstalling

```bash
smolvm machine prune --name <NAME>   # one machine's unreferenced layers; --all drops its cached images
smolvm pack prune                    # cached pack extractions
```
