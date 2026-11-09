---
name: gpu
description: Gives a smolvm microVM a GPU and proves it works, down one of two paths. Vulkan (--gpu) is for graphics and compute shaders, through virtio-gpu and Venus. CUDA (--cuda) is for CUDA programs on a host NVIDIA GPU, through API remoting. Use when a workload in a machine needs a GPU; when asked whether a host can run Vulkan or CUDA in a machine; when vulkaninfo fails or names llvmpipe in a guest; when nvidia-smi or /dev/nvidia* is missing inside a --cuda guest; when a CUDA program exits zero but seems not to touch the device; when the CUDA shim will not load in an Alpine image; or when WebGL is unavailable in a guest on a Mac.
---

# A GPU inside a machine

Two features that share a word. **Want graphics or compute shaders? Take the Vulkan path. Want a
CUDA program to run? Take the CUDA path.** `--gpu` does not provide CUDA, and `--cuda` does not
provide Vulkan. Done means a program in the guest named a real device and handed back what the
device computed or copied. `README.md` says why each path checks what it checks.

| Path | Platform | Status on v1.33.0, 2026-11-06 | Last GPU run |
|---|---|---|---|
| Vulkan | macOS arm64, Apple M4 | **VERIFIED** for device, compute shader and offscreen render; WebGL through Chromium does not work there | v1.33.0 |
| Vulkan | Linux | **PARTIAL**: ran only on an aarch64 host with no GPU, where the preflight blocks and the guest's `vkCreateInstance` fails | none |
| Vulkan | Windows | **N/A**: `--gpu` has no effect | none |
| CUDA | macOS | **N/A**: no CUDA driver. The preflight's refusal and the emulation device were run | none |
| CUDA | Linux with an NVIDIA GPU | **not run** | v1.14.6, A10, 2026-09-11 |
| CUDA | Windows with an NVIDIA GPU | **not run** | v1.22.2, RTX 4050, 2026-10-03 |
| CUDA | Linux aarch64, no NVIDIA GPU | **PARTIAL**: the preflight's refusal, and the emulation device by hand at 1024 MiB; the probe's 8192 MiB did not boot, nor did a plain `machine run` at that size | none |

**Re-run on v1.34.0, 2026-11-09**, from the checksummed release under fresh `HOME`s: on the M4, twice,
`result=vulkan_ok` on `alpine` (Mesa 26.1.6, `vkmark` 2733 and 2154) and on `debian:trixie-slim`
(Mesa 24.2.8), and the CUDA refusal and `result=cpu_emulation_not_gpu`; on Lima once, the same
`result=blocked`, `vkCreateInstance` returning -1, and the 8192 MiB probe not booting. WebGL and the
1024 MiB emulation device on Linux were not re-run.

## Procedure

```
- [ ] 1. preflight.sh vulkan|cuda     can this host take the path, with no VM started
- [ ] 2. run-vulkan-probe.sh          or run-cuda-probe.sh
- [ ] 3. cleanup.sh --purge           nothing left running
```

**1. Preflight, for the path you want.**

```bash
scripts/preflight.sh vulkan
scripts/preflight.sh cuda
```

Read-only: it starts no VM and touches no GPU state. The last line is `result=ready` or
`result=blocked`, and a `note=` says why. **If the question is "can this host do it", the preflight
answers it and nothing else needs to run.** An M4 on v1.33.0:

```
platform=darwin-aarch64
accel=hvf
accel_access=ok
host_renderer=bundled
result=ready
```

Then step 2 of your path.

### The Vulkan path

macOS needs nothing installed: the release bundles virglrenderer and MoltenVK. Linux needs
virglrenderer and a Vulkan driver from the system packages, in [the table in GPU
acceleration](../gpu.md#host-requirements), and the release bundles neither.

**2. Run the probe.**

```bash
scripts/run-vulkan-probe.sh                        # alpine
scripts/run-vulkan-probe.sh debian:trixie-slim     # a glibc image
```

It mounts `scripts/` into a `--gpu` machine and runs `vulkan-guest.sh` there, which installs the
tools, compiles a compute shader and `vulkan-compute.c`, and runs `vkmark`. On the M4 on v1.33.0:

```
  packages=0
    deviceType         = PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU
    deviceName         = Virtio-GPU Venus (Apple M4)
    driverName         = venus
    driverInfo         = Mesa 26.1.6
  device=Virtio-GPU Venus (Apple M4)
  values_checked=1024
  values_wrong=0
  compute=ok
      Device Name:    Virtio-GPU Venus (Apple M4)
  [vertex] duration=1: FPS: 2638 FrameTime: 0.379 ms
  [shading] duration=1: FPS: 2693 FrameTime: 0.371 ms
                                     vkmark Score: 2665
device=Virtio-GPU Venus (Apple M4)
device_kind=venus
compute=ok
graphics=ok vkmark_score=2665
result=vulkan_ok
```

`values_wrong=0` is the line that proves the device ran work: the shader wrote 1024 values and the
guest read them back and compared each one. `vkmark` draws frames offscreen through a graphics
pipeline and counts them; it does not check pixels, so `graphics=ok` means frames were rendered on
the named device, and the frame rates are no benchmark.

`device_kind=software` with `result=software_not_gpu` means the work ran on `llvmpipe`; the script
exits 1 there, though the shader's values come back right. `result=compute_ok_graphics_not_run`
means the image has no `vkmark` package: Debian 12 ran the compute shader that way.

On a glibc image smolvm bind-mounts its own Venus driver at `/opt/smolvm-vulkan` and sets
`VK_DRIVER_FILES` to it, so the image needs no Mesa: Debian 13 reported Mesa 24.2.8. On Alpine the
driver is the `mesa-vulkan-virtio` package, Mesa 26.1.6 here.

### The CUDA path

The guest gets **no NVIDIA driver and no `/dev/nvidia*`**. A compatibility `libcuda.so.1` is
injected at `/opt/smolvm-cuda` and forwards CUDA driver calls over vsock to a host daemon that owns
the device. The host needs a working NVIDIA driver and nothing else: no extra packages, no container
toolkit, no device plugin. `result=blocked` with `gpu_present=no` saves the most time, because on a
host with no NVIDIA GPU the probe starts a VM, reaches a CPU emulation device and returns a passing
round trip, which reads like a yes.

**2. Run the probe.**

```bash
scripts/run-cuda-probe.sh                     # python:3.12-slim
scripts/run-cuda-probe.sh <other glibc image>
```

It mounts `scripts/` into the guest and runs `cuda-probe.py` under `--cuda`, then asserts two
values from the output. On the A10 on v1.14.6, `cuda-probe.py`'s own output was:

```
load_shim -> ok /opt/smolvm-cuda/libcuda.so.1
cuInit -> 0
cuDeviceGetCount -> 0 count = 1
cuDeviceGetName -> 0 name = NVIDIA A10
cuCtxCreate -> 0
cuMemGetInfo -> 0 total MiB = 22587
cuMemAlloc   -> 0
cuMemcpyHtoD -> 0
cuMemcpyDtoH -> 0
roundtrip first 16 bytes match: True
cuMemFree    -> 0
```

and the script's: `device_named=ok`, `data_roundtrip=ok`, `device_kind=gpu`, `result=cuda_ok`.
`roundtrip ... True` proves bytes reached the device, once the device name says it is not
`smolvm CPU emulation device`, which is `device_kind=cpu_emulation` and
`result=cpu_emulation_not_gpu`. The M4 on v1.33.0 returned exactly that.

`references/cuda-runs.md` has the eval prompts and the end-to-end re-verifications.
`references/windows.md` has the Windows run, which goes by hand because `scripts/*.sh` are bash, and
a BLAS call that returns 0 and writes nothing there.

### Both paths

**3. Clean up.**

```bash
scripts/cleanup.sh --purge
smolvm machine prune --name <NAME> --all   # any persistent GPU machine you kept
```

`cleanup.sh` waits up to 20 seconds, polling the machine list, and prints `waiting=up to 20s`
first: an ephemeral machine's entry retires after its run returns. The probe runs are ephemeral and
leave nothing to prune; `machine prune` takes a machine name and is rejected without one.

Neither probe changes the host. `--cuda` was measured: after a series of CUDA runs plus a Kubernetes
install and teardown, `nvidia-smi` still reported the device and a whole-filesystem sweep for
`*smolvm*` came back empty. On Linux the Vulkan path's host packages are yours to remove.

## Traps

Full detail in `references/traps.md`.

**Vulkan**

- **`--gpu` boots on a host that cannot run Vulkan, and says nothing.** The machine exits 0 and has
  `/dev/dri/card0` and `renderD128`. Assert the device, never `ls /dev/dri`.
- **WebGL through Chromium does not work on the M4.** `getContext("webgl")` returns null, while
  `chromium --screenshot` still exits 0 and writes a PNG. A screenshot proves nothing.
- **OpenGL in a guest on a Mac is software**: `eglinfo` names `llvmpipe`. The bundled renderer is
  Venus only, so use Vulkan directly.
- **`ERROR_OUT_OF_HOST_MEMORY` is not about memory.** It is what the guest got on a Linux host with
  no GPU, on Alpine and on Debian 12.
- **`virglrenderer0` is not a package** on Ubuntu 24.04, Debian 12 or Debian 13. `libvirglrenderer1`
  is, at 1.0.0, 0.10.4 and 1.1.0.
- **An NVIDIA host needs virglrenderer 1.2.0 or newer**, and none of those three ships it. No NVIDIA
  host has run this path.

**CUDA**

- **A zero exit code proves nothing, and neither does a device name alone.** See step 2.
- **`nvidia-smi` is absent inside the guest and that is correct.** So is `/dev/nvidia*`.
- **Use a glibc image and load the shim by absolute path.** The shim is glibc, so an Alpine guest
  cannot load it.
- **A fresh GPU cloud instance does not have KVM access for your user**, and the installer says the
  install succeeded anyway. `sg kvm -c` applies the group without a logout.
- **`agent did not become ready within 30 seconds` from the probe is about memory, not the GPU.**
  The probe asks for 8192 MiB.

## Security defaults, and why they are the defaults

- **The guest never gets the NVIDIA device under `--cuda`, and that is the isolation.** No
  `/dev/nvidia*` is passed through, so a workload in the machine cannot reach the driver directly,
  reprogram it, or see another VM's device state through it. What it gets is a forwarded API surface.
- **What each path exposes is still real.** A remoted CUDA call runs against the host's driver and
  memory allocator, and a Venus call reaches the host's renderer and Vulkan driver. Treat a GPU
  machine as having a channel to a privileged host component. The VM boundary is what makes that
  acceptable; it is not zero authority.
- **Nothing here needs root or a container toolkit on the host**, past installing Linux's Vulkan
  packages. If a procedure asks you to install a device plugin or run the CLI as root, it is not
  this procedure.
- **The scripts wrap the public CLI only**, mount only this packet's own `scripts/` directory
  read-only into the guest, and cleanup deletes only names it recorded under the `smolskill-`
  prefix.

## Eval prompts, and what they produced

**1. "Can this Mac run Vulkan shaders in a machine?" (v1.33.0, M4)**

`preflight.sh vulkan` said `result=ready`, and the probe's output is the block under the Vulkan
path's step 2, from this run.

**2. "Can this Linux box run Vulkan in a machine?" (v1.33.0, Lima `linux-kvm`, Ubuntu 24.04 aarch64,
no GPU)**

```
platform=linux-aarch64
accel_access=ok
host_virglrenderer=yes
host_virglrenderer_version=1.0.0-1ubuntu2
render_node=no
note=no /dev/dri render node and no NVIDIA GPU; on such a host on v1.33.0 the machine boots and the guest's vkCreateInstance fails with ERROR_OUT_OF_HOST_MEMORY
host_vulkan_device=unknown
note=no vulkaninfo on this host, so its Vulkan driver was not checked
result=blocked
```

Past the preflight, the probe reported `device_kind=none`, `compute=FAIL` and `result=FAILED`, and
the guest's error was `vkCreateInstance failed with ERROR_OUT_OF_HOST_MEMORY`.

**3. "Can this machine run CUDA?" (v1.33.0, the M4)**

```
platform=darwin-aarch64
gpu_present=no
unsupported=cuda
note=macOS has no CUDA driver, so --cuda has nothing to reach here.
result=blocked
```

## What was not run

**On v1.33.0, no NVIDIA GPU ran either path, and no Linux host with any GPU ran Vulkan.** Linux
x86_64 was not run at all this time. `docs/gpu.md` reports a Venus device on Linux with an Intel GPU;
this packet has not repeated that.

- **WebGL on any Linux host.**
- **This `preflight.sh` on an NVIDIA host.** Its Vulkan check for one ran against a stand-in
  `nvidia-smi`; its CUDA checks are the ones the A10 ran.
- **Vulkan on an Intel Mac**, and any Apple chip but the M4.
- **`--gpu-vram`, a Smolfile's `gpu = true`, and a persistent `--gpu` machine.** The probe uses an
  ephemeral `machine run --gpu`; the flags are in `docs/gpu.md`.
- **The preflight and the cleanup on Windows**, which are bash.
- **`--cuda` with a CUDA base image** (`nvidia/cuda:...`), and the `apt-get install -y python3`
  those images need.
- **The `sg kvm -c` single-command remedy.** The state it addresses, a user who cannot open
  `/dev/kvm`, did reproduce on a fresh instance; the fix applied was a group change and a new
  login session.
- **Branches and restores of a GPU machine.** The docs site's `introduction/concepts/gpu.md`
  (smolmachines.com/docs) gives this as a reason for the remoting design, and a restored CUDA
  machine has its own shorter 10 s ready timeout.
- **Multi-GPU**, and contention between two machines sharing one device.
- **A training or inference workload.** The furthest CUDA run is the vector add on Windows, and the
  furthest Vulkan run is the shader and the frames above. Neither says how much of either API is
  implemented.

## Related packets

- `install` for the KVM group precondition, which a fresh GPU instance fails.
- `teardown` for the cleanup script. CUDA images are large enough that `machine prune` is worth it.
