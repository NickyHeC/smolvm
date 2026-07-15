#!/usr/bin/env bash
# Assert every committed Linux libkrun.so has a glibc symbol floor <= MAX
# (default 2.35). A libkrun built on a newer distro (e.g. Ubuntu 24.04 / glibc
# 2.39) loads fine there but dies on 22.04 / Debian 12 / RHEL 9 with
# "GLIBC_2.39 not found", bricking `machine run` before the agent is ready.
#
# The release ships the committed lib/linux-<arch>/libkrun.so as-is (no rebuild),
# so the floor of what's in git IS the floor users get. build-libkrun.yml asserts
# this on the rebuild path; this script gates the committed binary in CI so a
# high-floor lib can never be merged/tagged (regression that shipped in v1.6.0,
# issue #636).
#
# Arch-independent: GLIBC_x.y version strings live in .dynstr, so grepping the
# ELF works for both x86_64 and aarch64 on one runner — no cross-arch objdump.
#
#   PASS  → every committed Linux libkrun.so floor <= MAX
#   FAIL  → a lib exceeds MAX (rebuild on 22.04) or LFS wasn't pulled
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MAX="${SMOLVM_GLIBC_FLOOR_MAX:-2.35}"
# Default: every committed Linux libkrun. Override (space-separated) to scope to a
# single arch, e.g. from build-libkrun.yml which rebuilds one arch per matrix job.
read -r -a LIBS <<<"${SMOLVM_GLIBC_FLOOR_LIBS:-lib/linux-x86_64/libkrun.so lib/linux-aarch64/libkrun.so}"

fail=0
for so in "${LIBS[@]}"; do
  if [[ ! -f "$so" ]]; then
    echo "FAIL  $so: missing (git lfs not pulled?)"
    fail=1
    continue
  fi
  # LFS pointer instead of the real binary → no GLIBC strings; catch it.
  if head -c 64 "$so" | grep -q 'git-lfs'; then
    echo "FAIL  $so: LFS pointer, not the binary — run 'git lfs pull'"
    fail=1
    continue
  fi
  maxv="$(grep -aoE 'GLIBC_[0-9]+\.[0-9]+' "$so" | sed 's/GLIBC_//' | sort -V | tail -1)"
  if [[ -n "$maxv" && "$(printf '%s\n%s\n' "$maxv" "$MAX" | sort -V | tail -1)" != "$MAX" ]]; then
    echo "FAIL  $so: requires glibc $maxv (> $MAX)"
    fail=1
  else
    echo "OK    $so (max GLIBC ${maxv:-none} <= $MAX)"
  fi
done

if [[ "$fail" != "0" ]]; then
  cat >&2 <<EOF

Committed libkrun exceeds the glibc floor ($MAX). Rebuild on a matching-floor host:
  x86_64:  ./scripts/build-libkrun-linux.sh          # on ubuntu-22.04
  aarch64: ./scripts/build-libkrun-linux.sh          # on ubuntu-22.04-arm
  (or dispatch .github/workflows/build-libkrun.yml, which builds both on 22.04)
then commit the updated lib/linux-<arch>/ (binary + libkrun.provenance).
EOF
  exit 1
fi
echo "All committed libkrun binaries meet the glibc floor (<= $MAX)."
