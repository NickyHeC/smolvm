# CUDA runs, as recorded

The eval prompts and the end-to-end re-verifications behind `SKILL.md`. The block "under step 2
above" is the A10 output in `SKILL.md`.

## Eval prompts, and what they produced

**1. "Run a CUDA workload in a smolvm machine and prove it reached the GPU." (re-run on v1.14.6
on the A10)**

`cuda-probe.py`'s output is the block under step 2 above, from this run.

**2. "`nvidia-smi` is not in my `--cuda` guest and there is no `/dev/nvidia0`. Is the GPU
working?" (re-run on v1.14.6 on the A10)**

Both absences are correct. Inside a `--cuda` guest on `python:3.12-slim`:

```
--- /opt/smolvm-cuda ---
libcublas.so.11
libcublas.so.12
libcublas.so.13
libcublasLt.so.11
libcublasLt.so.12
libcublasLt.so.13
libcuda.so
libcuda.so.1
--- /dev/nvidia* ---
ls: cannot access '/dev/nvidia*': No such file or directory
--- nvidia-smi ---
nvidia-smi: not present in the image
--- SMOLVM_CUDA env ---
SMOLVM_CUDA_ZEROCOPY=1
```

The driver API is the check, and the probe above is what runs it.

**3. "Can this machine run CUDA?"**

On the A10 on v1.14.6, where the answer is yes:

```
platform=linux-x86_64
accel=kvm
accel_access=ok
gpu_present=yes
gpu=NVIDIA A10, 580.105.08
host_libcuda=1
guest_needs_glibc_image=yes
guest_shim_path=/opt/smolvm-cuda/libcuda.so.1
result=ready
```

And where it is no:

macOS 27.0.1 arm64 on v1.22.2:

```
platform=darwin-aarch64
gpu_present=no
unsupported=cuda
note=macOS has no CUDA driver, so --cuda has nothing to reach here.
result=blocked
```

Lima `linux-kvm`, Ubuntu 24.04 aarch64, on v1.22.2:

```
platform=linux-aarch64
accel_access=ok
gpu_present=no
note=no nvidia-smi on this host; --cuda needs the driver library libcuda.so.1, which host_libcuda reports
host_libcuda=0
note=libcuda.so.1 is not in this host's loader cache; --cuda loads it on the host, and without it the guest reaches the CPU emulation device
result=blocked
```

## Re-verified on v1.22.2, the no-GPU path

Run 2026-10-03 PT against v1.22.2 from the published release, under an isolated `HOME` on macOS
27.0.1 arm64, twice, the second time from a fresh `HOME`. The preflight said
`gpu_present=no` and `result=blocked` without starting anything. The probe reached the emulation
device, `name = smolvm CPU emulation device` and `roundtrip first 16 bytes match: True`, and
reported `device_kind=cpu_emulation` and `result=cpu_emulation_not_gpu`. In the second pass Docker
Hub refused the default image with `TOOMANYREQUESTS`, the anonymous pull limit, and the probe passed
on `scripts/run-cuda-probe.sh mirror.gcr.io/library/python:3.12-slim`, the same image from a
mirror. A probe that reaches no device now says `device_kind=none`; earlier versions of the script
said `gpu`.

On Lima `linux-kvm` (Ubuntu 24.04 aarch64) the probe's 8192 MiB guest timed out on a host that
booted 2048 MiB and no more on 2026-10-03, and the script named that cause first. Linux aarch64 was
last verified on v1.18.2, where the probe at `--mem 1024` reached the emulation device with the
same lines as macOS.

## Re-verified on v1.14.6

Run 2026-09-11 PT against v1.14.6 from the published release, installed into an isolated data root
on an **NVIDIA A10** cloud instance: 30 vCPU Intel Xeon Platinum 8358, 222 GiB memory, kernel
6.8.0-1046-nvidia, driver 580.105.08, 23028 MiB of device memory.

**The GPU path ran end to end on this release.** preflight, probe, all three eval prompts and
cleanup were executed in the packet's own order:

```
preflight            result=ready, gpu_present=yes, gpu=NVIDIA A10, 580.105.08, host_libcuda=1
probe, default image device_named=ok, data_roundtrip=ok, result=cuda_ok
probe, second image  device_named=ok, data_roundtrip=ok, result=cuda_ok
cleanup --purge      machines=clean, vm_processes=none
```

The probe was run against **two** glibc images, `python:3.12-slim` and `python:3.12-bookworm`, and
both reported `name = NVIDIA A10` and `total MiB = 22587`, and the first 16 bytes of the 1 MiB round
trip came back as sent.

**The host is untouched by `--cuda`, and that is now measured rather than quoted.** After these
runs `nvidia-smi` reported `NVIDIA A10, 580.105.08, 23028 MiB, 0 MiB` used, a whole-filesystem
sweep for `*smolvm*` outside the install prefix and the data root returned nothing, and the eight
NVIDIA kernel modules were still loaded.

**The KVM precondition in the traps reproduced on this instance**: a fresh instance has
`/dev/kvm` as `root:kvm` with the login user outside the group, so the user could not open it until
the group was granted; the preflight, run after that, reported `accel_access=ok`.
