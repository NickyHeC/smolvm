#!/usr/bin/env bash
# Run the Vulkan probe inside a --gpu machine and assert its values.
#
# usage: run-vulkan-probe.sh [<image>]      (default alpine)
#
# The image needs apk or apt-get. On a glibc image smolvm supplies its own Venus
# driver; on Alpine the guest's Mesa package does.

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${1:-alpine}"

SMOLVM="${SMOLVM:-$(command -v smolvm 2>/dev/null)}"
if [ -z "$SMOLVM" ]; then
    printf 'smolvm not found; set SMOLVM to its path\n' >&2
    exit 2
fi

out="$("$SMOLVM" machine run --gpu --net --mem 2048 \
    -v "$here:/probe:ro" --image "$IMAGE" -- sh /probe/vulkan-guest.sh 2>&1)"
printf '%s\n' "$out" | sed 's/^/  /'

fail=0
device="$(sed -n 's/^device=//p' <<<"$out" | head -1)"

# The name of the device the compute shader ran on. Venus names the host device
# in brackets, and a software host device still reads as Venus, so test that first.
case "$(printf '%s' "$device" | tr '[:upper:]' '[:lower:]')" in
    '')                                 kind=none ;;
    *llvmpipe*|*lavapipe*|*swiftshader*) kind=software ;;
    *venus*)                            kind=venus ;;
    *)                                  kind=other ;;
esac
printf 'device=%s\n' "${device:-none}"
printf 'device_kind=%s\n' "$kind"

# A device being listed is not a device that runs work, so assert what the shader wrote.
if grep -q '^values_wrong=0$' <<<"$out" && grep -q '^compute=ok$' <<<"$out"; then
    printf 'compute=ok\n'
else
    printf 'compute=FAIL\n'
    fail=1
fi

score="$(sed -n 's/.*vkmark Score: *\([0-9][0-9]*\).*/\1/p' <<<"$out" | head -1)"
if [ -n "$score" ] && [ "$score" -gt 0 ]; then
    printf 'graphics=ok vkmark_score=%s\n' "$score"
elif grep -q '^graphics=vkmark is not packaged' <<<"$out"; then
    printf 'graphics=not_run\n'
else
    printf 'graphics=FAIL\n'
    fail=1
fi

if [ "$kind" = software ]; then
    printf 'result=software_not_gpu\n'
    printf 'The guest ran the work on a software Vulkan device, not on a GPU.\n'
    exit 1
fi
[ "$kind" = venus ] || fail=1

if [ "$fail" -eq 0 ] && [ -z "$score" ]; then
    printf 'result=compute_ok_graphics_not_run\n'
elif [ "$fail" -eq 0 ]; then
    printf 'result=vulkan_ok\n'
else
    printf 'result=FAILED\n'
    printf 'Run scripts/preflight.sh vulkan. references/traps.md lists what each guest error has meant.\n'
fi
exit "$fail"
