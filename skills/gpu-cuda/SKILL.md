---
name: gpu-cuda
description: Runs CUDA compute workloads inside a smolvm microVM against a real host NVIDIA GPU, using smolvm's --cuda API remoting. Use when a workload in a machine needs a GPU; when nvidia-smi or /dev/nvidia* is missing inside a --cuda guest; when a CUDA program in a machine exits zero but seems not to touch the device; when the shim will not load in an Alpine image; or when checking whether CUDA is available on a given platform, including Windows. Do not use it for Vulkan graphics (--gpu), which is a separate feature that works on no tested host, and do not expect it on a Mac, which has no NVIDIA hardware.
---

# CUDA inside a machine

Built on a verified run of **smolvm v1.14.2** against an **NVIDIA A10** (Linux x86_64) and an
**NVIDIA GeForce RTX 4050** (Windows x86_64). Done means a program in the VM opens the device,
creates a context, and moves data to and from it.

> **Read this before trusting a step here.** **No GPU host was available when this packet was
> written**, so every step that needs one is written from those earlier runs and **was not
> re-run**. What was re-run, on macOS arm64 and Ubuntu 24.04 aarch64, is `scripts/preflight.sh`
> and the failure path of `scripts/run-cuda-probe.sh` on a host with no NVIDIA hardware. The
> section "What was not run" lists every step individually.

## How this works, and why the checks are shaped this way

The guest gets **no NVIDIA driver and no `/dev/nvidia*`**. A compatibility `libcuda.so.1` is
injected at `/opt/smolvm-cuda` inside the guest and forwards CUDA driver calls over vsock to a host
daemon that owns the device. Nothing is needed on the host beyond a working NVIDIA driver: no extra
packages, no container toolkit, no device plugin.

Because the API is **remoted rather than passed through**, a program can start, link against
`libcuda.so.1` and exit zero without a GPU ever being reached. **Assert a device name and a
transferred result, never an exit code.**

## Procedure

**1. Preflight.**

```bash
scripts/preflight.sh
```

Read-only: it starts no VM and touches no NVIDIA state. It reports the GPU and driver version,
whether your user can open `/dev/kvm`, and the host's own `libcuda` count. `result=blocked` with
`gpu_present=no` is the answer that saves the most time, because the failure without it names
neither CUDA nor the GPU.

**2. Run the probe.**

```bash
scripts/run-cuda-probe.sh                     # python:3.12-slim
scripts/run-cuda-probe.sh <other glibc image>
```

It mounts `scripts/` into the guest and runs `cuda-probe.py` under `--cuda`, then asserts two
values from the output:

```
device_named=ok
data_roundtrip=ok
result=cuda_ok
```

On the A10, `cuda-probe.py`'s own output was:

```
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

`roundtrip ... True` is the one that matters. It is the only line that proves bytes reached the
device.

**3. Clean up.** CUDA images are large.

```bash
scripts/cleanup.sh --purge
smolvm machine prune
```

`--cuda` changes nothing on the host: the shim is injected inside the guest only. Verified after a
full session of CUDA runs plus a Kubernetes install and teardown on the same box, where
`nvidia-smi` still reported the device and a whole-filesystem sweep for `*smolvm*` came back empty.

## Traps

Full detail in `references/traps.md`.

- **A zero exit code proves nothing.** The remoted API is why.
- **`nvidia-smi` is absent inside the guest and that is correct.** So is `/dev/nvidia*`. Neither is
  a useful check.
- **Use a glibc image and load the shim by absolute path.** The shim is glibc, so an Alpine guest
  cannot load it, and relying on the loader path picks up whatever the image carries.
- **A fresh GPU cloud instance does not have KVM access for your user**, and the installer says the
  install succeeded anyway. `sg kvm -c` applies the group without a logout.
- **On a host with no NVIDIA GPU the error names neither CUDA nor the GPU.** Observed on Ubuntu
  24.04 aarch64: `agent did not become ready within 30 seconds`, which reads exactly like host
  load. The preflight is the only thing that tells the two apart.
- **`--cuda` and `--gpu` are different features.** `--cuda` is compute over vsock and works;
  `--gpu` is Vulkan over virtio-gpu and works on no host tested. On Windows `--gpu` is accepted and
  silently does nothing.

## Security defaults, and why they are the defaults

- **The guest never gets the device, and that is the isolation.** No `/dev/nvidia*` is passed
  through, so a workload in the machine cannot reach the driver directly, reprogram it, or see
  another VM's device state through it. What it gets is a forwarded API surface.
- **What that surface exposes is still real.** A remoted CUDA call runs against the host's driver
  and the host's memory allocator, so treat a `--cuda` machine as having a channel to a privileged
  host component. The VM boundary is what makes that acceptable; it is not zero authority.
- **Nothing here needs root or a container toolkit on the host.** If a procedure asks you to
  install a device plugin or run the CLI as root to get CUDA working, it is not this procedure.
- **The scripts wrap the public CLI only**, mount only this packet's own `scripts/` directory into
  the guest, and cleanup deletes only names it recorded under the `smolskill-` prefix.

## Platform arms

- **Linux x86_64 with an NVIDIA GPU**: **verified on an A10**, in the run this packet is built
  from. Not re-run.
- **Windows x86_64 with an NVIDIA GPU**: **verified on an RTX 4050**, including a 1 MiB device
  round trip. Not re-run. `references/windows.md`. **This contradicts three documentation pages**,
  which this branch corrects.
- **macOS arm64 and Intel**: **not applicable.** No Mac has an NVIDIA GPU, so `--cuda` has nothing
  to reach. The preflight says so rather than letting a run time out.
- **Linux aarch64**: no NVIDIA hardware on the hosts available here. Only the preflight and the
  failure path were run.
- **Multi-GPU, GPU forks and clones, and a real training or inference workload**: not run anywhere.

## Eval prompts, and what they produced

The first two need a GPU host and are recorded from the earlier runs; the third was run in this
session. Which is which is stated per prompt.

**1. "Run a CUDA workload in a smolvm machine and prove it reached the GPU." (not re-run; from the
A10 run, v1.14.2)**

```
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

**2. "`nvidia-smi` is not in my `--cuda` guest and there is no `/dev/nvidia0`. Is the GPU
working?" (not re-run; from the A10 run)**

Both absences are correct. The guest showed `/opt/smolvm-cuda/libcuda.so`,
`/opt/smolvm-cuda/libcuda.so.1` and `SMOLVM_CUDA_ZEROCOPY=1` in the environment, while
`ls /dev/nvidia*` returned `No such file or directory` and `nvidia-smi` was not present in the base
image. The driver API is the check.

**3. "Can this machine run CUDA?" (run in this session, 2026-09-07 PT, on two hosts with no NVIDIA
hardware)**

macOS 26.6.2 arm64:

```
platform=darwin-aarch64
gpu_present=no
unsupported=cuda,vulkan
note=no Apple Silicon or Intel Mac has an NVIDIA GPU, so --cuda has nothing to reach here. This is a hardware fact, not a smolvm limitation.
result=blocked
```

Lima `linux-kvm`, Ubuntu 24.04 aarch64:

```
platform=linux-aarch64
accel_access=ok
gpu_present=no
note=no nvidia-smi on this host, so there is no GPU for the remoting daemon to own
host_libcuda=0
result=blocked
```

and running the probe anyway, to record what a user sees when they skip the preflight:

```
Starting ephemeral machine (vm-5d98e4be)...
Error: agent operation failed: start machine: agent operation failed: wait for ready:
agent did not become ready within 30 seconds
device_named=FAIL
data_roundtrip=FAIL
result=FAILED
```

The error names neither CUDA nor the missing device.

## Re-verified on v1.14.3

Run 2026-09-08 PT against v1.14.3 on macOS 26.6.2 arm64 and Lima `linux-kvm` (Ubuntu 24.04
aarch64). Only `preflight.sh` could run, and on both hosts it correctly reports `gpu_present=no`
and `result=blocked`. **No GPU host was available for this release either**, so every step in the
list below is still unrun.

## What was not run

**No GPU host was available for this packet.** Every step below is written from the earlier
verified runs and was not repeated:

- The probe against a real device, on Linux x86_64 and on Windows.
- `--cuda` with a CUDA base image (`nvidia/cuda:...`), and the `apt-get install -y python3` those
  images need.
- The observation that `--cuda` leaves no host NVIDIA state behind.
- The `sg kvm -c` remedy on a fresh GPU cloud instance.
- Everything in `references/windows.md`.

Never run anywhere, then or now:

- **GPU forks and clones.** `introduction/concepts/gpu.md` sells this as a reason for the remoting
  design, and a CUDA clone has its own shorter 10 s ready timeout.
- **Multi-GPU**, and contention between two machines sharing one device.
- **A real workload.** These are driver-API assertions, not a training or inference run, and say
  nothing about throughput or how much of the CUDA API surface is implemented.

## Related packets

- `install` for the KVM group precondition, which a fresh GPU instance fails.
- `teardown` for the cleanup script. CUDA images are large enough that `machine prune` is worth it.
