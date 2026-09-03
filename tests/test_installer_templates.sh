#!/usr/bin/env bash
#
# Installer tests for the disk templates the runtime boots from.
#
# These use a fake release layout and a stubbed download, so they need no
# network, no built smolvm binary, no libkrun and no KVM.

source "$(dirname "$0")/common.sh"

echo ""
echo "=========================================="
echo "  smolvm Installer Template Tests"
echo "=========================================="
echo ""

# Load install.sh's functions without running its `main`.
load_installer() {
    local funcs="$1/installer-funcs.sh"
    sed '$d' "$PROJECT_ROOT/scripts/install.sh" > "$funcs"
    # shellcheck disable=SC1090
    source "$funcs"
}

# Build a release tarball carrying the requested template form.
#   $1 = work dir, $2 = one of: zst | plain | none
make_dist_tarball() {
    local tmp="$1" form="$2"
    local dist="$tmp/smolvm-9.9.9-test-arch"

    mkdir -p "$dist/lib"
    printf '#!/bin/sh\n' > "$dist/smolvm"
    printf '#!/bin/sh\n' > "$dist/smolvm-bin"
    chmod +x "$dist/smolvm" "$dist/smolvm-bin"

    if [[ "$form" != "none" ]]; then
        # Real content, so a byte comparison after install means something.
        head -c 4096 /dev/urandom > "$dist/storage-template.ext4"
        head -c 2048 /dev/urandom > "$dist/overlay-template.ext4"
        if [[ "$form" == "zst" ]]; then
            zstd -q --rm -f "$dist/storage-template.ext4" -o "$dist/storage-template.ext4.zst"
            zstd -q --rm -f "$dist/overlay-template.ext4" -o "$dist/overlay-template.ext4.zst"
        fi
    fi

    tar -czf "$tmp/dist.tar.gz" -C "$tmp" "$(basename "$dist")"
    rm -rf "$dist"
}

# Checksum the first $2 bytes of file $1, so a template that the installer
# also extended to its virtual size can still be compared against its source.
head_sha() {
    head -c "$2" "$1" | shasum | cut -d' ' -f1
}

# Run the real install_smolvm against the fixture tarball in $1, into prefix $2.
run_installer() {
    local tmp="$1" prefix="$2"
    (
        export HOME="$tmp/home"
        mkdir -p "$HOME"
        load_installer "$tmp"
        BIN_DIR="$tmp/bin"
        mkdir -p "$BIN_DIR"
        # The checksums fetch must fail so the installer takes its documented
        # "skipping verification" branch; anything else gets the fixture.
        download() {
            case "$1" in
                *checksums*) return 1 ;;
                *) cp "$tmp/dist.tar.gz" "$2" ;;
            esac
        }
        install_smolvm "9.9.9" "test-arch" "$prefix"
    )
}

test_compressed_templates_are_installed() {
    local tmp prefix
    tmp=$(mktemp -d); prefix="$tmp/home/.smolvm"; mkdir -p "$prefix"
    make_dist_tarball "$tmp" zst
    # Keep a copy of what the distribution carried, to compare bytes against.
    local ref; ref=$(mktemp -d)
    tar -xzf "$tmp/dist.tar.gz" -C "$ref"

    run_installer "$tmp" "$prefix" >/dev/null 2>&1

    local rc=0
    # Releases have shipped the templates only as .zst since the compression
    # change; an installer that copies just the plain names installs nothing at
    # all, which costs pack create and checkpoint on a host without e2fsprogs
    # and the instant-overlay boot path on Linux.
    cmp -s "$prefix/storage-template.ext4.zst" \
           "$ref/smolvm-9.9.9-test-arch/storage-template.ext4.zst" || rc=1
    cmp -s "$prefix/overlay-template.ext4.zst" \
           "$ref/smolvm-9.9.9-test-arch/overlay-template.ext4.zst" || rc=1

    rm -rf "$tmp" "$ref"
    return $rc
}

test_uncompressed_templates_are_installed() {
    local tmp prefix
    tmp=$(mktemp -d); prefix="$tmp/home/.smolvm"; mkdir -p "$prefix"
    make_dist_tarball "$tmp" plain
    local ref; ref=$(mktemp -d)
    tar -xzf "$tmp/dist.tar.gz" -C "$ref"

    run_installer "$tmp" "$prefix" >/dev/null 2>&1

    local rc=0
    # A tarball built on a host without zstd ships the plain files instead, so
    # both forms have to keep working. Compare content only: on Linux the
    # installer also extends the file to its default virtual size.
    [[ "$(head_sha "$prefix/storage-template.ext4" 4096)" \
       == "$(head_sha "$ref/smolvm-9.9.9-test-arch/storage-template.ext4" 4096)" ]] || rc=1
    [[ "$(head_sha "$prefix/overlay-template.ext4" 2048)" \
       == "$(head_sha "$ref/smolvm-9.9.9-test-arch/overlay-template.ext4" 2048)" ]] || rc=1

    rm -rf "$tmp" "$ref"
    return $rc
}

test_upgrade_replaces_templates_instead_of_only_deleting() {
    local tmp prefix
    tmp=$(mktemp -d); prefix="$tmp/home/.smolvm"; mkdir -p "$prefix"
    # An install from before the compression change: plain templates on disk.
    printf 'stale storage\n' > "$prefix/storage-template.ext4"
    printf 'stale overlay\n' > "$prefix/overlay-template.ext4"
    make_dist_tarball "$tmp" zst

    run_installer "$tmp" "$prefix" >/dev/null 2>&1

    local rc=0
    # Upgrading used to remove the old templates and install nothing, so a
    # working install came back with pack create and checkpoint broken.
    [[ -f "$prefix/storage-template.ext4.zst" ]] || rc=1
    [[ -f "$prefix/overlay-template.ext4.zst" ]] || rc=1
    # The stale plain file must not survive: the runtime prefers it over the
    # compressed one, which would pin the upgrade to the old template.
    [[ -f "$prefix/storage-template.ext4" ]] && rc=1
    [[ -f "$prefix/overlay-template.ext4" ]] && rc=1

    rm -rf "$tmp"
    return $rc
}

test_missing_templates_are_reported() {
    local tmp prefix output
    tmp=$(mktemp -d); prefix="$tmp/home/.smolvm"; mkdir -p "$prefix"
    make_dist_tarball "$tmp" none

    output=$(run_installer "$tmp" "$prefix" 2>&1)

    local rc=0
    # The copy is conditional on filenames, so a rename in the build script
    # silently installed nothing for several releases. Say it out loud instead.
    printf '%s\n' "$output" | grep -q "no disk templates" || rc=1

    rm -rf "$tmp"
    return $rc
}

if ! command -v zstd >/dev/null 2>&1; then
    log_skip "installer template tests (zstd not available to build the fixture)"
    print_summary
    exit 0
fi

run_test "compressed templates are installed" test_compressed_templates_are_installed
run_test "uncompressed templates are installed" test_uncompressed_templates_are_installed
run_test "upgrade replaces templates instead of only deleting" test_upgrade_replaces_templates_instead_of_only_deleting
run_test "missing templates are reported" test_missing_templates_are_reported

print_summary
