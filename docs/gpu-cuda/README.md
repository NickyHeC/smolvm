# CUDA inside a machine

`--cuda` remotes the guest's CUDA **Driver API** calls to the host's NVIDIA GPU over vsock. It is a
different feature from `--gpu`, which is Vulkan graphics; they share nothing but the word GPU.

`SKILL.md` is the procedure and carries the version stamps and the per-platform results.

## What the host and the guest need

The host needs a working NVIDIA driver, meaning `libcuda.so.1` and a loaded kernel module. **No
CUDA toolkit is required on either side**, and nothing needs installing beyond that: no container
toolkit, no device plugin, no root. Enable it with `--cuda` on `machine run` or `machine create`,
or `cuda = true` in a Smolfile.

The guest gets **no NVIDIA driver and no `/dev/nvidia*`**. A compatibility `libcuda.so.1` is
injected at `/opt/smolvm-cuda` and forwards Driver API calls to a host daemon that owns the device.
`nvidia-smi` is absent inside the guest and that is correct; neither its absence nor the absence of
`/dev/nvidia*` tells you anything about whether the GPU is reachable.

## Because the API is remoted, an exit code proves nothing

A program can start, link against `libcuda.so.1` and exit zero without a GPU ever being reached.
The topic's probe asserts a device name and a transferred result instead.

**From v1.16.1 on, a device name and a passing round trip are not enough either.** On a host with no
NVIDIA hardware the shim answers with a CPU emulation device: `cuDeviceGetName` returns
`smolvm CPU emulation device`, memory is reported as 1024 MiB, and a 1 MiB round trip comes back
byte for byte. The device **name** is what tells them apart, and `scripts/run-cuda-probe.sh`
reports `device_kind=cpu_emulation` and `result=cpu_emulation_not_gpu` rather than a pass.

**To answer "can this machine run CUDA", run the preflight and nothing else.** It reports
`gpu_present`, the driver version and whether your user can open `/dev/kvm`, and it starts no VM.
Reaching for the probe on a GPU-less host starts a machine and comes back with something that reads
like a yes.

## What is covered

Init and device queries, contexts including the primary-context flow the CUDA runtime uses, module
load and unload for PTX, cubin and fatbin, allocation and copies in both directions, kernel launch,
streams, events and `cuGetProcAddress`. Work executes synchronously on the host, and `*Async` calls
complete before returning, which the CUDA contract permits. This covers programs written against
the Driver API, the `cu*` C functions.

## Use a glibc image, and load the shim by path

The shim is glibc, so an Alpine guest cannot load it. Load it as
`/opt/smolvm-cuda/libcuda.so.1` rather than relying on the loader path, which picks up whatever the
image carries.

## Isolation, and the host kernel

The VM boundary still isolates the workload's CPU, memory and filesystem. GPU access is mediated by
host processes and the shared host GPU, so GPU isolation remains process-level rather than a
hardware or VM boundary. Do not treat CUDA remoting as a hardened multi-tenant GPU isolation
boundary.

Fork-heavy Linux hosts should use a kernel containing upstream KVM fix
[`916b7f4`](https://github.com/torvalds/linux/commit/916b7f42b3b3b539a71c204a9b49fdc4ca92cd82).
Affected kernels can intermittently report `ENOMEM` on the first `KVM_RUN` even with ample host
memory; smolvm reduces exposure and replaces a failed worker, but the kernel update is the
definitive fix.

The design, its trade-offs and a comparison with passthrough:
[GPU access by API remoting: how a driverless microVM runs CUDA](https://smolmachines.com/engineering/gpu-over-vsock).

## Platforms

No Mac has NVIDIA hardware, so `--cuda` has nothing to reach there; that is a hardware fact, not a
smolvm limitation. CUDA does work on Windows, against an RTX 4050 including a device round trip,
which three documentation pages used to deny. `references/windows.md` has that run.
