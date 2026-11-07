#!/bin/sh
# Inside a --gpu guest: install the tools, name the device, dispatch a compute
# shader and read back what it wrote, then render frames offscreen.
# run-vulkan-probe.sh runs this and asserts the values it prints.

set -u

if command -v apk >/dev/null 2>&1; then
    apk add --no-cache mesa-vulkan-virtio vulkan-loader vulkan-loader-dev vulkan-headers \
        vulkan-tools glslang gcc musl-dev vkmark >/dev/null 2>&1
    echo "packages=$?"
elif command -v apt-get >/dev/null 2>&1; then
    # smolvm supplies the Venus driver on a glibc image, so no Mesa package here.
    { apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        vulkan-tools libvulkan-dev glslang-tools gcc libc6-dev; } >/dev/null 2>&1
    echo "packages=$?"
    # Debian 12 does not package vkmark; Debian 13 and Ubuntu 24.04 do.
    apt-get install -y -qq --no-install-recommends vkmark >/dev/null 2>&1
else
    echo "packages=no apk or apt-get in this image"
    exit 2
fi

vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|deviceType|driverName|driverInfo'

cd /tmp || exit 2
cat > vulkan-compute.comp <<'SHADER'
#version 450
layout(local_size_x = 64) in;
layout(std430, binding = 0) buffer Out { uint data[]; };
void main() { data[gl_GlobalInvocationID.x] = gl_GlobalInvocationID.x * 3u + 7u; }
SHADER
glslangValidator -V vulkan-compute.comp -o vulkan-compute.spv >/dev/null &&
    gcc -O1 -o vulkan-compute /probe/vulkan-compute.c -lvulkan &&
    ./vulkan-compute vulkan-compute.spv

# vkmark draws to an offscreen image, so no window system is needed.
if command -v vkmark >/dev/null 2>&1; then
    vkmark --winsys headless -b vertex:duration=1 -b shading:duration=1 2>&1 |
        grep -E 'Device Name|FPS|Score'
else
    echo "graphics=vkmark is not packaged for this image"
fi
