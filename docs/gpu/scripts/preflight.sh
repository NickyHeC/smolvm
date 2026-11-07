#!/usr/bin/env bash
# Report whether this host can run one GPU path inside a smolvm machine.
# Read-only: starts no VM, touches no GPU state, changes no group membership.
#
# usage: preflight.sh vulkan|cuda
#
# Output is one key=value per line. The last line is always result=ready or
# result=blocked.

set -uo pipefail

path="${1:-}"
case "$path" in
    vulkan|cuda) ;;
    *) printf 'usage: preflight.sh vulkan|cuda\n' >&2; exit 2 ;;
esac

# The release each path last ran on, per platform. On Linux, Vulkan has only run
# on a host with no GPU, and CUDA's GPU run is the older one.
case "$path-$(uname -s)" in
    cuda-Linux) VERIFIED_VERSION="1.14.6" ;;
    *)          VERIFIED_VERSION="1.33.0" ;;
esac

emit() { printf '%s=%s\n' "$1" "$2"; }
note() { printf 'note=%s\n' "$1"; }

blocked=0
pkg_version=""

SMOLVM="${SMOLVM:-$(command -v smolvm 2>/dev/null)}"
if [ -z "$SMOLVM" ]; then
    emit smolvm_installed no
    blocked=1
else
    emit smolvm_installed yes
    version="$("$SMOLVM" --version 2>/dev/null | awk '{print $NF}')"
    emit smolvm_version "${version:-unknown}"
fi

emit verified_version "$VERIFIED_VERSION"
if [ -n "${version:-}" ] && [ "$version" != "unknown" ]; then
    if [ "$version" = "$VERIFIED_VERSION" ]; then
        emit version_status match
    else
        newest="$(printf '%s\n%s\n' "$version" "$VERIFIED_VERSION" | sort -V | tail -1)"
        if [ "$newest" = "$version" ]; then
            emit version_status newer
            note "this path was verified on $VERIFIED_VERSION on this platform and the binary is $version, so check each step's output against the binary"
        else
            emit version_status older
        fi
    fi
else
    emit version_status unknown
fi

kernel="$(uname -s)"
arch="$(uname -m)"
case "$arch" in aarch64|arm64) arch=aarch64 ;; esac
emit platform "$(printf '%s' "$kernel" | tr '[:upper:]' '[:lower:]')-$arch"

case "$kernel" in
    Darwin)
        emit accel hvf
        if [ "$(sysctl -n kern.hv_support 2>/dev/null)" = "1" ]; then emit accel_access ok; else emit accel_access denied; fi
        ;;
    Linux)
        emit accel kvm
        # A fresh cloud GPU instance fails this, and the installer warns and
        # continues, so the install succeeds and the first VM fails.
        if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
            emit accel_access ok
        else
            emit accel_access denied
            blocked=1
            note "your user cannot open /dev/kvm. Fix without logging out: sudo usermod -aG kvm \$USER, then run the next command through sg kvm -c '...'"
        fi
        ;;
    *)
        emit accel unknown
        emit accel_access unknown
        blocked=1
        ;;
esac

# ldconfig is often in /sbin, off a user's PATH.
loader_cache() {
    ldc="$(command -v ldconfig 2>/dev/null)"
    for c in /sbin/ldconfig /usr/sbin/ldconfig; do [ -n "$ldc" ] || { [ -x "$c" ] && ldc="$c"; }; done
    [ -n "$ldc" ] && "$ldc" -p 2>/dev/null
}

nvidia_gpu() { command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1; }

check_vulkan_linux() {
    if ! cache="$(loader_cache)"; then
        emit host_virglrenderer unknown
        note "could not read the loader cache with ldconfig -p, so whether libvirglrenderer.so.1 loads was not checked"
        return
    fi
    # The Linux release bundles no renderer, and --gpu refuses to start without one.
    lib="$(awk '/libvirglrenderer\.so\.1 / {print $NF; exit}' <<<"$cache")"
    if [ -z "$lib" ]; then
        emit host_virglrenderer no
        blocked=1
        note "libvirglrenderer.so.1 is not in this host's loader cache; docs/gpu.md lists the packages per distro"
    else
        emit host_virglrenderer yes
        # Only when a package owns the library the loader finds: a build from source
        # is what docs/gpu.md asks of an NVIDIA host, and it leaves the package installed.
        if command -v dpkg-query >/dev/null 2>&1 && dpkg-query -S "$(readlink -f "$lib")" >/dev/null 2>&1; then
            pkg_version="$(dpkg-query -W -f='${Version}' libvirglrenderer1 2>/dev/null)"
        fi
        emit host_virglrenderer_version "${pkg_version:-unknown}"
    fi
    if ! grep -q 'libEGL\.so\.1 ' <<<"$cache"; then
        emit host_libegl no
        blocked=1
        note "libEGL.so.1 is not in this host's loader cache; on v1.14.2 a --gpu machine died with SIGABRT without it"
    fi

    gpu="$(nvidia_gpu)"
    if [ -n "$gpu" ]; then
        emit gpu "$gpu"
        if [ -n "$pkg_version" ] && [ "$(printf '%s\n1.2.0\n' "$pkg_version" | sort -V | head -1)" != "1.2.0" ]; then
            blocked=1
            note "an NVIDIA host needs virglrenderer 1.2.0 or newer and this host's package is $pkg_version, so the guest's vkCreateDevice would fail; docs/gpu.md says what to do"
        elif [ -z "$pkg_version" ]; then
            note "an NVIDIA host needs virglrenderer 1.2.0 or newer, and no package reports this host's version"
        fi
    fi

    if compgen -G '/dev/dri/renderD*' >/dev/null; then
        emit render_node yes
    else
        emit render_node no
        if [ -z "$gpu" ]; then
            blocked=1
            note "no /dev/dri render node and no NVIDIA GPU; on such a host on v1.33.0 the machine boots and the guest's vkCreateInstance fails with ERROR_OUT_OF_HOST_MEMORY"
        fi
    fi

    if command -v vulkaninfo >/dev/null 2>&1; then
        emit host_vulkan_device "$(vulkaninfo --summary 2>/dev/null | sed -n 's/.*deviceName *= *//p' | paste -sd, -)"
    else
        emit host_vulkan_device unknown
        note "no vulkaninfo on this host, so its Vulkan driver was not checked"
    fi
}

check_vulkan() {
    case "$kernel" in
        Darwin)
            real="$(readlink -f "$SMOLVM" 2>/dev/null || printf '%s' "$SMOLVM")"
            if [ -e "$(dirname "$real")/lib/libvirglrenderer.1.dylib" ] && [ -e "$(dirname "$real")/lib/libMoltenVK.dylib" ]; then
                emit host_renderer bundled
            else
                emit host_renderer missing
                blocked=1
                note "the release bundles libvirglrenderer and libMoltenVK beside smolvm and they are not there"
            fi
            ;;
        Linux) check_vulkan_linux ;;
        *)
            emit unsupported vulkan
            note "this script covers macOS and Linux, and on Windows --gpu has no effect."
            ;;
    esac
}

check_cuda() {
    case "$kernel" in
        Darwin)
            emit gpu_present no
            emit unsupported "cuda"
            blocked=1
            note "macOS has no CUDA driver, so --cuda has nothing to reach here."
            ;;
        Linux) ;;
        *) note "this script covers macOS and Linux. CUDA was verified on Windows by hand on v1.22.2; see references/windows.md." ;;
    esac

    if command -v nvidia-smi >/dev/null 2>&1; then
        gpu="$(nvidia_gpu)"
        if [ -n "$gpu" ]; then
            emit gpu_present yes
            emit gpu "$gpu"
        else
            emit gpu_present no
            blocked=1
            note "nvidia-smi is installed but reported no device"
        fi
    elif [ "$kernel" = "Linux" ]; then
        emit gpu_present no
        blocked=1
        note "no nvidia-smi on this host; --cuda needs the driver library libcuda.so.1, which host_libcuda reports"
    fi

    # The host's own libcuda is what the remoting daemon forwards to. The guest gets
    # none, and that is the design.
    if [ "$kernel" = "Linux" ]; then
        if cache="$(loader_cache)"; then
            host_libcuda="$(grep -c 'libcuda\.so\.1' <<<"$cache")"
            emit host_libcuda "$host_libcuda"
            if [ "$host_libcuda" -eq 0 ]; then
                blocked=1
                note "libcuda.so.1 is not in this host's loader cache; --cuda loads it on the host, and without it the guest reaches the CPU emulation device"
            fi
        else
            emit host_libcuda unknown
            note "could not read the loader cache with ldconfig -p, so whether libcuda.so.1 loads was not checked"
        fi
    fi

    emit guest_needs_glibc_image yes
    emit guest_shim_path /opt/smolvm-cuda/libcuda.so.1
}

"check_$path"

if [ "$blocked" -eq 0 ]; then emit result ready; else emit result blocked; fi
