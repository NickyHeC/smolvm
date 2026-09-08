# CUDA on Windows: it works, and the documentation says it does not

**Not re-run by this packet.** Executed once on Windows 11 Home build 26200 x86_64 with an
**NVIDIA GeForce RTX 4050 Laptop GPU** (driver 566.26, 6141 MiB) against smolvm v1.14.2.

`--cuda` injects the same remoting shim as on Linux and the guest reaches the real device:

```powershell
& $exe machine run --cuda --net --mem 6144 -v "$probe:/probe" --image python:3.12-slim -- python3 /probe/probe.py
```

Observed, 13.4 s:

```
cuInit -> 0
cuDeviceGetCount -> 0 count = 1
cuDeviceGetName -> 0 name = NVIDIA GeForce RTX 4050 Laptop GPU
cuCtxCreate -> 0
cuMemGetInfo -> 0 total MiB = 6140
cuMemAlloc -> 0
cuMemcpyHtoD -> 0
cuMemcpyDtoH -> 0
roundtrip 16 bytes match: True
```

**The 1 MiB round trip is the assertion that matters**: bytes went to the device and came back
unchanged, so this is not a stub.

The shim is present even in a non-CUDA image: `machine run --cuda --image alpine` shows
`/opt/smolvm-cuda` containing `libcuda.so.1`, `libcudart`, `libcublas*` and `libcudnn*`. As on
Linux, the guest gets no `/dev/nvidia*` and `nvidia-smi` is absent, which is the documented
remoting design.

## Windows-specific notes

- **Use a glibc image.** The shim is glibc and an Alpine guest cannot load it. `python:3.12-slim`
  is small and already has Python.
- **Load the shim by absolute path**, `/opt/smolvm-cuda/libcuda.so.1`, rather than by soname.
- **Large CUDA images may not pull.** `nvidia/cuda:12.4.1-base-ubuntu22.04` failed after 582 s
  with `crane blob failed ... unexpected EOF` on this host's network. A transfer failure, not a
  CUDA one, but another reason to prefer a small image.
- **Do not capture `machine run` output in PowerShell.** See the `install` packet's Windows page.
- **Vulkan is a different story.** `machine run --gpu` boots and exits 0, and in the guest
  `/dev/dri` does not exist and `dmesg` has zero `virtio_gpu` lines. No error, no warning, no
  mention that the flag was dropped.

## What the docs say, and which one is right

At v1.14.2 three places state that Windows has no GPU acceleration, and **all three are wrong for
CUDA**:

- `AGENTS.md:13`, "no GPU acceleration"
- `README.md:300`, "Not yet available on Windows: GPU acceleration"
- the shipped `README.txt`, "NOT YET SUPPORTED ON WINDOWS: GPU acceleration"

The accurate page is `introduction/concepts/supported-platforms.md:29`, which says Windows "lacks
**Vulkan** GPU acceleration, VM fork, and snapshots". Saying Vulkan specifically is exactly right.

This branch corrects the first three to say Vulkan rather than GPU.
