# GPU traps

Vulkan first, then CUDA. Each path has its own section because they share nothing but the word.

## Vulkan

### `--gpu` boots on a host that cannot run Vulkan, and says nothing

Observed on v1.33.0 on Lima `linux-kvm` (Ubuntu 24.04 aarch64, no GPU, no `/dev/dri` on the host).
`machine run --gpu` exits 0, the guest has `/dev/dri/card0` and `renderD128` and `dmesg` has
`Initialized virtio_gpu 0.1.0`, and only then does Vulkan fail, on Alpine and on Debian 12:

```
vkCreateInstance failed with ERROR_OUT_OF_HOST_MEMORY
```

The error is not about memory. On v1.14.2 on macOS it read the same at `--mem 8192` and at
`--gpu-vram 8192`. Assert the device, never the node.

### A `cap set` line with `max-version 0` is not the failure

On the M4 on v1.33.0, with Venus working, `dmesg` says `cap set 0: id 4, max-version 0, max-size
156`. Lima says the same for id 4 with Vulkan failing, so the line does not separate them. The
probe does.

### WebGL through Chromium does not work on the M4

Chromium 156 on v1.33.0, on `alpine` with the guest's Mesa and on `debian:trixie-slim` with
smolvm's driver, with `--use-gl=angle --use-angle=vulkan`, and with `--ignore-gpu-blocklist` added:
`getContext("webgl")` returned null and the GPU process exited at start.

```
eglCreateContext: Requested version is not supported
eglCreateContext ES 3.0 failed with error EGL_BAD_ATTRIBUTE. ES version fallback is disabled.
CollectGraphicsInfo failed.
```

The cause was not isolated. **The same command with `--screenshot` exits 0 and writes a PNG**, so a
screenshot is no check of the GPU; read the WebGL renderer in the page, which on the M4 printed
`webgl=unavailable`:

```sh
apk add --no-cache chromium chromium-angle mesa-vulkan-virtio vulkan-loader
chromium --headless=new --no-sandbox --disable-dev-shm-usage --use-gl=angle --use-angle=vulkan \
  --virtual-time-budget=5000 --dump-dom \
  "data:text/html,<script>const g=document.createElement('canvas').getContext('webgl');document.write('webgl='+(g?g.getParameter(g.getExtension('WEBGL_debug_renderer_info').UNMASKED_RENDERER_WEBGL):'unavailable'))</script>" 2>/dev/null | grep -o 'webgl=[^<]*' | tail -1
```

`docs/gpu.md`'s ANGLE line is from Linux with an Intel GPU, which this packet has not repeated.

### OpenGL in a guest on a Mac is software

`eglinfo -B` in a `--gpu` guest on the M4 names `llvmpipe (LLVM 22.1.3, 128 bits)` for every OpenGL
profile. The renderer bundled on macOS is Venus only (`src/agent/mod.rs`), and `dmesg` has one
capset where Lima has five. Use Vulkan directly.

### Features a Mac guest's device does not have

`vulkaninfo` on the M4 reports `geometryShader = false` and `logicOp = false`, so a workload
needing them fails on this device, though it would pass the probe. Read `vulkaninfo` for your
features before relying on them.

### A software device runs the work and gets the right answer

With `mesa-vulkan-swrast` in the guest and no `--gpu`, on the M4: `device=llvmpipe (LLVM 22.1.3, 128
bits)`, `values_wrong=0`, `compute=ok`. So the probe tests the name as well, and says
`device_kind=software`. Venus names the host device in brackets, so a software host device would
still read as Venus; the probe checks for that first. vkmark crashed with a segmentation fault on
llvmpipe in that run, which reads as `graphics=FAIL`.

### `virglrenderer0` is not a package

`docs/gpu.md` and the `--gpu` error message name it. `apt-cache policy` in the guest on 2026-11-06:

| Distro | `virglrenderer0` | `libvirglrenderer1` |
|---|---|---|
| Ubuntu 24.04 | none | 1.0.0-1ubuntu2 |
| Debian 12 | none | 0.10.4-1 |
| Debian 13 | none | 1.1.0-2 |

An NVIDIA host needs 1.2.0 or newer, so on all three that host needs a build from source.

### An NVIDIA host needs virglrenderer 1.2.0 or newer

`docs/gpu.md`: older render servers preload Vulkan in a way NVIDIA's driver rejects, so the guest's
`vkCreateDevice` fails with `VK_ERROR_INITIALIZATION_FAILED`. The preflight blocks when a dpkg
package owns the library the loader finds and is older. It was tested with a stand-in `nvidia-smi`
script. **No NVIDIA host ran it.**

### A working NVIDIA compute driver does not imply a graphics stack

On v1.14.2 a Lambda A10 with CUDA working had no `libEGL.so.1`, and `--gpu` died with `SIGABRT (a
crash in the VMM or a library it loaded)` until `libegl1` was installed. A missing
`libvirglrenderer.so.1` gives a clean message instead. The preflight checks for both. Not re-run on
v1.33.0.

### `vulkaninfo` prints an error that means nothing

`error: XDG_RUNTIME_DIR is invalid or not set in the environment.` came after a good summary on the
M4. The summary above it stands.

## CUDA

### A zero exit code proves nothing on a remoted API

**This is the trap the whole packet is shaped around.** CUDA in smolvm is remoted, not passed
through: the guest gets no NVIDIA driver and no `/dev/nvidia*`, and a compatibility `libcuda.so.1`
forwards driver calls over vsock to a host daemon that owns the device. A program can therefore
start, link against `libcuda.so.1`, and exit zero without a GPU ever being reached.

Assert a **device name** and a **computed or copied result**. `scripts/cuda-probe.py` asserts both:
`cuDeviceGetName` returning a real name, and a 1 MiB host to device to host round trip whose first
16 bytes come back as sent.

### `nvidia-smi` is absent inside a `--cuda` guest, and that is correct

So is `/dev/nvidia*`. Both are the documented remoting design, not a fault, and neither is a useful
check. Use the driver API.

### Use a glibc image, and load the shim by absolute path

The injected shim is glibc, so an Alpine (musl) guest cannot load it. `python:3.12-slim` is small
and already has Python.

Load it as `/opt/smolvm-cuda/libcuda.so.1` rather than by soname: relying on the loader path picks
up whatever the image happens to carry, and the shim is at a fixed location.

**CUDA base images do not ship `python3`**, so `nvidia/cuda:...-base-...` needs
`apt-get install -y python3` in the guest first, or a `-devel` image. That is a reason to prefer a
small glibc image over a CUDA one for a probe.

### A fresh GPU cloud instance does not have KVM access for your user

`/dev/kvm` is `crw-rw---- root:kvm` and your account is not in the `kvm` group. The installer warns
and continues, so the install succeeds and the first VM fails. Apply the group without logging out:

```bash
sudo usermod -aG kvm "$USER"
sg kvm -c 'smolvm machine run --mem 2048 --net --image alpine -- echo OK'
```

### "agent did not become ready within 30 seconds" with `--cuda` was the guest's size, not the GPU

Observed on Ubuntu 24.04 aarch64 on 2026-09-07, running `machine run --cuda` on a host with no
NVIDIA hardware:

```
Starting ephemeral machine (vm-5d98e4be)...
Error: agent operation failed: start machine: agent operation failed: wait for ready:
agent did not become ready within 30 seconds
```

**Re-measured on v1.18.2, 2026-09-24, and the missing GPU was not the cause.** On the same kind of
host, Lima `linux-kvm` with no NVIDIA hardware, `scripts/run-cuda-probe.sh` at its `--mem 8192`
failed with the message above; the same probe at `--mem 1024` reached `smolvm CPU emulation
device` and returned `result=cpu_emulation_not_gpu`; and `machine run --mem 8192 --net --image
alpine` with no `--cuda` failed with the same message. That host booted 2048 MiB and not 2560 on
2026-09-24. So the timeout is the guest's size on that host, and a host that cannot load the driver
library answers `--cuda` with the emulation device instead.

### Large CUDA images may not pull

`nvidia/cuda:12.4.1-base-ubuntu22.04` failed after 582 s with `crane blob failed ... unexpected
EOF` on the Windows host's network. That is a transfer failure, not a CUDA one, but it is another
reason to prefer a small image.

### Memory: give the machine real headroom

The Linux GPU runs used `--mem 8192`, and the Windows probe line in `references/windows.md` uses
`--mem 6144`. On a small host, see the ready-timeout trap in the `install` packet: the 30 s limit is
a hard-coded constant and no flag raises it for `machine run` or `machine start`.

### `--cuda` changes nothing on the host

The remoting shim is injected at `/opt/smolvm-cuda` **inside the guest only**, and no host NVIDIA
state is touched. Verified after a series of CUDA runs plus a Kubernetes install and teardown on
the same host: `nvidia-smi` still reported the device, and a whole-filesystem sweep for
`*smolvm*` came back empty.

### `--cuda` and `--gpu` are different features

`--cuda` is compute over vsock. `--gpu` is Vulkan graphics over virtio-gpu; on the hosts tested
through v1.16.1 the host renderer reported the Venus capset at version 0, and on v1.18.2 on macOS
arm64 a guest reached `Virtio-GPU Venus (Apple M4)`. `docs/gpu.md` in the repository covers it. They share nothing
but the word GPU. On Windows, on v1.14.6 and v1.22.2, `--gpu` boots and the guest has no GPU
device; nothing reports that the flag was dropped.
