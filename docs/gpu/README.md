# A GPU inside a machine

Two flags, two different features. They share nothing but the word GPU.

| You want | Flag | How it reaches the GPU |
|---|---|---|
| Graphics, or compute shaders | `--gpu` | Vulkan calls cross virtio-gpu through the Venus driver to a host renderer |
| A CUDA program | `--cuda` | CUDA calls cross vsock through a guest shim to a host process that owns the NVIDIA device |

`--gpu` does not provide CUDA and `--cuda` does not provide Vulkan. `SKILL.md` is the procedure for
each and carries the status per platform. [GPU acceleration](../gpu.md) is the reference for both.

## Vulkan: a listed device is not a working one

`--gpu` boots a machine and gives it `/dev/dri` on a host that cannot run Vulkan at all, and exits
0. So the packet's probe asks the device to do work: a compute shader writes 1024 values and the
guest reads each one back, then `vkmark` renders frames offscreen. The device name is checked too,
because a guest can also run all of that on `llvmpipe`, a software device.

macOS needs nothing installed, because the release bundles virglrenderer and MoltenVK. Linux needs
virglrenderer and a Vulkan driver from the system packages, and an NVIDIA host needs virglrenderer
1.2.0 or newer. **No NVIDIA or other Linux GPU host has run this packet's Vulkan path**; `SKILL.md`
says what has.

What a Mac gives a guest is Vulkan. On the M4 on v1.33.0, WebGL through Chromium was unavailable
and OpenGL in the guest was software.

## CUDA: because the API is remoted, an exit code proves nothing

The host needs a working NVIDIA driver, meaning `libcuda.so.1` and a loaded kernel module. **No
CUDA toolkit is required on either side for the Driver API**, and nothing needs installing beyond
that: no container toolkit, no device plugin, no root. Enable it with `--cuda` on `machine run` or
`machine create`, or `cuda = true` in a Smolfile.

The guest gets **no NVIDIA driver and no `/dev/nvidia*`**. A compatibility `libcuda.so.1` is
injected at `/opt/smolvm-cuda` and forwards Driver API calls to a host daemon that owns the device.
`nvidia-smi` is absent inside the guest and that is correct; neither its absence nor the absence of
`/dev/nvidia*` tells you anything about whether the GPU is reachable.

A program can start, link against `libcuda.so.1` and exit zero without a GPU ever being reached.
The packet's probe asserts a device name and a transferred result instead.

**A device name and a passing round trip are not enough either.** When the host cannot load the
NVIDIA driver library (`libcuda.so.1` on Linux), the host side answers with a CPU emulation device:
`cuDeviceGetName` returns `smolvm CPU emulation device`, memory is reported as 1024 MiB, and the
first 16 bytes of a 1 MiB round trip come back as sent. The device **name** is what tells them
apart, and `scripts/run-cuda-probe.sh` reports `device_kind=cpu_emulation` and
`result=cpu_emulation_not_gpu` rather than a pass. Seen on macOS arm64 on v1.16.1, v1.18.2, v1.22.2
and v1.33.0 and on Linux aarch64 on v1.18.2 and v1.33.0.

**To answer "can this machine run CUDA", run `scripts/preflight.sh cuda` and nothing else.** It
reports `gpu_present`, the driver version and whether your user can open `/dev/kvm`, and it starts
no VM. Reaching for the probe on a GPU-less host starts a machine and comes back with something
that reads like a yes.

[GPU acceleration](../gpu.md#cuda-api-remoting) lists the Driver API surface and the Runtime API
shim (`libcudart`, cuBLAS, cuBLASLt, cuDNN) that lowers onto it. This packet's probe exercises the
Driver API, the `cu*` C functions. The shim is glibc, so an Alpine guest cannot load it. Load it as
`/opt/smolvm-cuda/libcuda.so.1` rather than relying on the loader path, which picks up whatever the
image carries.

macOS has no CUDA driver, so `--cuda` has nothing to load there. CUDA remoting was verified on
Windows on v1.34.0 against an RTX 4050, including a device round trip and a vector add; where the project's pages
say GPU acceleration is unavailable on Windows, they mean the Vulkan `--gpu` path, a different
feature. `references/windows.md` has that run.

## Isolation, and the host kernel

[GPU acceleration](../gpu.md) is the reference for both: GPU isolation under remoting is
process-level rather than a VM boundary, and Linux hosts that branch many machines want the KVM fix
it names. It also links the design write-up.
