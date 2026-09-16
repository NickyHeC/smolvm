# Vulkan graphics in a guest

smolvm exposes the host GPU to a guest through **virtio-gpu and Venus**, Vulkan over virtio, with
`--gpu` on `machine run` or `machine create`, or `gpu = true` in a Smolfile. A guest workload sees a
real Vulkan device.

**There is no `SKILL.md` for this topic yet.** Through v1.16.1, `--gpu` worked on no host tested
here: the host renderer reported the Venus capset at version 0, the flag was accepted and the guest
got no `/dev/dri` and no `virtio_gpu` lines in `dmesg`, with no error and no warning that the flag
was dropped. **On v1.18.2 it reached a device on macOS arm64**, 2026-09-24, on an Apple M4:

```console
$ smolvm machine run --net --gpu --image alpine -- sh -c '
    apk add -q --no-cache mesa-vulkan-virtio vulkan-loader vulkan-tools
    ls /dev/dri; vulkaninfo --summary | grep -E "deviceName|driverName"'
card0
renderD128
	deviceName         = Virtio-GPU Venus (Apple M4)
	driverName         = venus
```

That is one run on one host, not a procedure run end to end, so a `SKILL.md` waits for one. Linux
was not re-tested. `--cuda` is a separate feature with its own topic at `docs/gpu-cuda/`; they
share nothing but the word GPU.

## Host requirements

**macOS**: virglrenderer and MoltenVK ship in the distribution, and nothing else is needed.

**Linux**: virglrenderer and a host Vulkan driver come from the system package manager.

| Distro | Packages |
|---|---|
| Alpine | `apk add virglrenderer mesa-vulkan-intel`, or `mesa-vulkan-ati` for AMD |
| Debian and Ubuntu | `apt install virglrenderer0 mesa-vulkan-drivers` |
| Nix and NixOS | the flake does not put virglrenderer on the loader path: export `LD_LIBRARY_PATH` with the nixpkgs `virglrenderer` and `libepoxy` library directories, and `/run/opengl-driver/lib` on NixOS |

virglrenderer depends on libEGL and libdrm from the host GPU driver stack. Those are
hardware-specific and cannot be bundled, and any GPU-capable Linux host already has them.

## The guest needs no ICD path

Nothing needs to set `VK_ICD_FILENAMES`. The guest's Mesa installs an ICD manifest where the Vulkan
loader already looks, and on a glibc image the agent also bind-mounts its own Venus driver and pins
the loader to it with `VK_DRIVER_FILES` when neither variable is set. The run above set neither.

Setting the variable overrides that pin, and the manifest's name carries the guest architecture,
`virtio_icd.aarch64.json` on an Apple Silicon host's guest and `virtio_icd.x86_64.json` on an x86_64
one, so a hardcoded path is wrong on the other architecture. Older documentation gave the `x86_64`
path with no architecture note, which names a file an arm64 guest does not have.

## Windows

Vulkan is documented as unavailable on Windows, and `--gpu` is accepted there and silently does
nothing.

## Assets

`assets/gpu-chrome.smolfile` is a headless Chrome machine, and `assets/desktop/` holds the desktop
recipe, its Mesa and Zink build script for aarch64 and its patches.
