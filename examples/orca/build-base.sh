#!/usr/bin/env bash
# build-base.sh [OUTPUT]: build orca-base.smolfile into OUTPUT.smolmachine. The default,
# $SMOL_RECIPE_DIR/orca-base, is where create looks for it. Runs apt-get once, here, instead
# of in every create.
source "$(dirname "$0")/smolvm-lib.sh"

out="${1:-$SMOL_RECIPE_DIR/orca-base}"
case "$out" in *.smolmachine) log "pass the output without .smolmachine; smolvm adds it"; exit 1 ;; esac
name="${SMOL_RECIPE_PREFIX}base-build"
mkdir -p "$(dirname "$out")"

[ "$(machine_state "$name")" = absent ] || "$SMOLVM" machine delete --name "$name" -f >&2
trap '"$SMOLVM" machine delete --name "$name" -f >/dev/null 2>&1 || true' EXIT
"$SMOLVM" machine create --name "$name" -s "$(dirname "$0")/orca-base.smolfile" >&2
"$SMOLVM" machine start --name "$name" >&2

# A pack that lost its install still boots, so check the source before packing it.
"$SMOLVM" machine exec --name "$name" -- sh -c \
  'test -x /usr/sbin/sshd && git --version && ! ls /etc/ssh/ssh_host_* 2>/dev/null' >&2 \
  || { log "the base is missing sshd or git, or still has host keys"; exit 1; }

"$SMOLVM" machine stop --name "$name" >&2
"$SMOLVM" pack create --from-vm "$name" --output "$out" >&2
log "wrote $out.smolmachine"
