#!/usr/bin/env bash
# Validate a Linux virglrenderer bundle before release packaging.
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 LIB_DIR" >&2
    exit 2
fi

LIB_DIR="$1"
LIB="$LIB_DIR/libvirglrenderer.so.1"
EPOXY="$LIB_DIR/libepoxy.so.0"
SERVER="$LIB_DIR/virgl_render_server"
PROVENANCE="$LIB_DIR/virglrenderer.provenance"

for command in file objdump readelf; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "error: required command not found: $command" >&2
        exit 1
    }
done

[[ -f "$LIB" ]] || { echo "error: missing $LIB" >&2; exit 1; }
[[ -f "$EPOXY" ]] || { echo "error: missing $EPOXY" >&2; exit 1; }
[[ -x "$SERVER" ]] || { echo "error: missing executable $SERVER" >&2; exit 1; }
[[ -f "$PROVENANCE" ]] || { echo "error: missing $PROVENANCE" >&2; exit 1; }

grep -qx 'version=1.2.0' "$PROVENANCE"
grep -qx 'venus=true' "$PROVENANCE"
grep -qx 'render_server=true' "$PROVENANCE"
grep -qx 'vulkan_preload=false' "$PROVENANCE"

readelf -d "$LIB" | grep -q 'SONAME.*libvirglrenderer.so.1'

if readelf -d "$LIB" "$EPOXY" "$SERVER" | grep -Eqi 'NEEDED.*(libcuda|libnvidia)'; then
    echo "error: bundle unexpectedly links an NVIDIA driver library" >&2
    exit 1
fi

check_glibc_floor() {
    local binary="$1" max_version
    max_version="$(
        objdump -T "$binary" 2>/dev/null \
            | grep -oE 'GLIBC_[0-9]+\.[0-9]+' \
            | sed 's/GLIBC_//' \
            | sort -V \
            | tail -1
    )"
    echo "max GLIBC required by $(basename "$binary"): ${max_version:-none}"
    if [[ -n "$max_version" ]] \
        && [[ "$(printf '%s\n2.35\n' "$max_version" | sort -V | tail -1)" != "2.35" ]]; then
        echo "error: $binary requires glibc $max_version (> 2.35)" >&2
        exit 1
    fi
}

check_glibc_floor "$LIB"
check_glibc_floor "$EPOXY"
check_glibc_floor "$SERVER"

file "$LIB" "$EPOXY" "$SERVER"
echo "virglrenderer bundle validation passed"
