#!/usr/bin/env bash
#
# Assert that the disk-template filenames build-dist.sh writes into a
# distribution are exactly the ones install.sh looks for when it unpacks one.
#
# These two scripts are the only place the names are coupled, and nothing at
# runtime can catch them drifting apart: an installer that matches no filename
# simply installs no template and says nothing. Renaming the templates in the
# build script without updating the installer is the change this rejects, and
# the pull request making that rename is the only moment it is cheap to catch.
#
# Parsed from the real scripts, so there is no fixture here to drift as well.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIST="$ROOT/scripts/build-dist.sh"
INSTALL="$ROOT/scripts/install.sh"

fail() { echo "error: $1" >&2; exit 1; }

# Template files build-dist.sh creates in the distribution directory.
produced=$(grep -oE '\$DIST_DIR/[A-Za-z0-9_-]+-template\.ext4' "$BUILD_DIST" \
    | sed 's|.*/||' | sort -u)
# Template files install.sh reads back out of an extracted distribution, with
# any compression suffix removed: the build compresses when it can and ships
# the plain file when it cannot, so both spell the same template.
expected=$(grep -oE '\$extracted_dir/[A-Za-z0-9_-]+-template\.ext4(\.zst)?' "$INSTALL" \
    | sed 's|.*/||; s|\.zst$||' | sort -u)

[[ -n "$produced" ]] || fail "found no disk templates in scripts/build-dist.sh"
[[ -n "$expected" ]] || fail "found no disk templates in scripts/install.sh"

if [[ "$produced" != "$expected" ]]; then
    echo "error: build-dist.sh and install.sh disagree on the disk-template names" >&2
    echo "build-dist.sh produces:" >&2
    echo "$produced" | sed 's/^/  /' >&2
    echo "install.sh installs:" >&2
    echo "$expected" | sed 's/^/  /' >&2
    exit 1
fi

# The build ships each template compressed when zstd is available and plain
# when it is not, so the installer has to accept either spelling of every one.
while IFS= read -r name; do
    grep -q "\$extracted_dir/$name\"" "$INSTALL" \
        || fail "install.sh never installs an uncompressed $name"
    grep -q "\$extracted_dir/$name.zst\"" "$INSTALL" \
        || fail "install.sh never installs a compressed $name.zst"
done <<< "$produced"

echo "disk-template names agree between build-dist.sh and install.sh:"
echo "$produced" | sed 's/^/  /'
