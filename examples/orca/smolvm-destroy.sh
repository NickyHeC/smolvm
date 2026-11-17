#!/usr/bin/env bash
# Orca `destroy`: delete the machine and its known_hosts entry. Safe to repeat.
source "$(dirname "$0")/smolvm-lib.sh"
cat >/dev/null
name="$(machine_name)"
[ "$(machine_state "$name")" = absent ] && { log "$name already gone"; exit 0; }
port="$(machine_label "$name" orca-ssh-port)"
"$SMOLVM" machine delete --name "$name" -f >&2
if [ -n "$port" ]; then ssh-keygen -R "[127.0.0.1]:$port" -f "$SMOL_RECIPE_KNOWN_HOSTS" >/dev/null 2>&1 || true; fi
