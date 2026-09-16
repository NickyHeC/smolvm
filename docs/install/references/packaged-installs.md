# Packaged installs

The installer at `https://smolmachines.com/install.sh` is the supported route on macOS and Linux
and is what `docs/install/README.md` documents. These are the distribution-packaged trees, kept
because a packager or a NixOS user needs them. Each section is the page that used to live at
`docs/install-<distro>.md`.

## Arch Linux

smolvm ships an **official pacman repository** maintained by the smol-machines
team. It serves prebuilt packages for `x86_64` and `aarch64`, updated
automatically with every release.

> The `smolvm`, `smolvm-bin` and `smolvm-git` packages on the AUR are
> third-party and not maintained by us. As of 1.4.7 they link against the
> stock Arch `libkrun`, which lacks six symbols smolvm needs: disk overlays,
> snapshots and egress policy do not work with those packages. The official
> package bundles the smol-machines libkrun fork and is fully functional.

### Setup

Add the repository to `/etc/pacman.conf`:

```ini
[smol-machines]
SigLevel = Optional TrustAll
Server = https://smol-machines.github.io/smolvm/pacman/$arch
```

Then install:

```sh
sudo pacman -Sy smolvm
```

Upgrades arrive with your normal `pacman -Syu`.

### Notes

- The repository is served from an atomic GitHub Pages deployment; packages are
  built by CI from the release artifacts and published on every release
  (`.github/workflows/pacman-repo.yml`). It is a rolling repo, so the
  latest release only (older versions remain on the GitHub Releases page).
- Package signing (GPG) is planned; until then integrity is provided by
  sha256-pinned sources built in CI and served over HTTPS.
- The package bundles the smol-machines `libkrun`/`libkrunfw` fork under
  `/usr/lib/smolvm/lib`, so it does not conflict with the system `libkrun`
  package, which other software may continue to use.

## Debian and Ubuntu

smolvm ships an **official apt repository** maintained by the smol-machines
team. It serves prebuilt `.deb` packages for `amd64` and `arm64`, updated
automatically with every release.

### Setup

```sh
echo 'deb [trusted=yes] https://smol-machines.github.io/smolvm/apt ./' \
  | sudo tee /etc/apt/sources.list.d/smolvm.list
sudo apt-get update
sudo apt-get install smolvm
```

Upgrades arrive with your normal `apt-get update && apt-get upgrade`.

### Notes

- It is a **flat, unsigned repository** (installed with `[trusted=yes]`), which
  matches the pacman repo's posture: integrity comes from packages built by CI
  from the release artifacts and served over HTTPS. Package signing (GPG) is
  planned; until then keep the `[trusted=yes]` flag.
- Served from an atomic GitHub Pages deployment; packages are built by CI and
  published on every release (`.github/workflows/pacman-repo.yml`). It is a
  rolling repo, the latest release only (older versions remain on the GitHub
  Releases page).
- The package installs the wrapper at `/usr/bin/smolvm` and bundles the
  smol-machines `libkrun`/`libkrunfw` fork under `/usr/lib/smolvm`, so it does not
  conflict with any system `libkrun`.
- Requires `crun` and `jq` (pulled in automatically). `crun` is available in
  Debian 12+ and Ubuntu 22.04+.

## Fedora

smolvm ships an **official dnf/yum repository** maintained by the smol-machines
team. It serves prebuilt `.rpm` packages for `x86_64` and `aarch64`, updated
automatically with every release.

### Setup

```sh
sudo tee /etc/yum.repos.d/smolvm.repo >/dev/null <<'EOF'
[smolvm]
name=smolvm
baseurl=https://smol-machines.github.io/smolvm/yum
enabled=1
gpgcheck=0
EOF
sudo dnf install smolvm
```

Upgrades arrive with your normal `dnf upgrade`.

### Notes

- The repository is **unsigned** (`gpgcheck=0`), which matches the pacman repo's
  posture: integrity comes from packages built by CI from the release artifacts
  and served over HTTPS. Package signing (GPG) is planned; until then keep
  `gpgcheck=0`.
- Served from an atomic GitHub Pages deployment; packages are built by CI and
  published on every release (`.github/workflows/pacman-repo.yml`). It is a
  rolling repo, the latest release only (older versions remain on the GitHub
  Releases page).
- The package installs the wrapper at `/usr/bin/smolvm` and bundles the
  smol-machines `libkrun`/`libkrunfw` fork under `/usr/lib/smolvm`, so it does not
  conflict with any system `libkrun`.
- Requires `crun` and `jq` (pulled in automatically).

## Nix and NixOS

smolvm is packaged as a **Nix flake**. It repackages the official release
binaries (bundling the smol-machines libkrun fork) and patches them for the Nix
store, with the runtime tools (`crun`, `mkfs.ext4`, `jq`, …) wired onto the
wrapper's `PATH`, so it works on NixOS out of the box.

Supported systems: `x86_64-linux`, `aarch64-linux`, `aarch64-darwin`.

### Run it once

```sh
nix run github:smol-machines/smolvm -- --help
```

### Install into a profile

```sh
nix profile install github:smol-machines/smolvm
```

Upgrades: `nix profile upgrade smolvm` (the flake tracks the latest release).

### NixOS / Home Manager

The flake exposes an overlay, so you can add smolvm to your configuration:

```nix
{
  inputs.smolvm.url = "github:smol-machines/smolvm";

  # in your system/home configuration:
  nixpkgs.overlays = [ inputs.smolvm.overlays.default ];
  environment.systemPackages = [ pkgs.smolvm ];   # or home.packages
}
```

Running microVMs needs `/dev/kvm` on Linux; on NixOS enable it with
`virtualisation.kvmgt.enable = true;` (Intel) or ensure the `kvm` module is
loaded and your user is in the `kvm` group.

### Notes

- It is a **binary repackage** (`sourceProvenance = binaryNativeCode`): the same
  release tarball served on the GitHub Releases page, patchelf'd for Nix. The
  bundled libkrun/libkrunfw fork lives under the package's `libexec`, so it does
  not collide with a system `libkrun`.
- The pinned version and hashes in `nix/smolvm.nix` are bumped after every
  release by `.github/workflows/update-nix-flake.yml`, which pushes a
  `nix-bump-<version>` branch and tries to open a PR. **The bump only reaches
  users once that PR is merged**, so check for an unmerged `nix-bump-*` branch
  if the flake lags the latest release. `./scripts/update-nix-hashes.sh VERSION`
  refreshes the hashes by hand from a release's `checksums.sha256`; set
  `version` first, since it rewrites only the hashes.
- A submission to the upstream **nixpkgs** collection is planned so
  `nix profile install nixpkgs#smolvm` works without referencing this flake.
