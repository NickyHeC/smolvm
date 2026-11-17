#!/usr/bin/env bash
# Shared helpers for the smolvm Orca recipe, sourced by the four step scripts.
# Orca parses stdout as exactly one JSON object, so every other line goes to stderr.
set -euo pipefail

: "${SMOLVM:=$(command -v smolvm || echo "$HOME/.local/bin/smolvm")}"   # where the installer puts it
: "${SMOL_RECIPE_IMAGE:=ubuntu:24.04}"          # used when there is no base pack; needs apt
: "${SMOL_RECIPE_CPUS:=2}"
: "${SMOL_RECIPE_MEM_MIB:=2048}"
: "${SMOL_RECIPE_PREFIX:=orca-}"                # machine name prefix
: "${SMOL_RECIPE_DIR:=${HOME}/.orca-smolvm}"    # the recipe's key and known_hosts
: "${SMOL_RECIPE_KEY:=$SMOL_RECIPE_DIR/id_ed25519}"
: "${SMOL_RECIPE_KNOWN_HOSTS:=$SMOL_RECIPE_DIR/known_hosts}"
: "${SMOL_RECIPE_FROM:=}"                       # a base pack; empty: $SMOL_RECIPE_DIR/orca-base.smolmachine if built
: "${SMOL_RECIPE_PORT_MIN:=22000}"
: "${SMOL_RECIPE_PORT_MAX:=22999}"

log() { printf '[smolvm-recipe %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# One machine per Orca instance, named from ORCA_VM_INSTANCE_ID ("orca-<uuid>").
machine_name() {
  local id="${ORCA_VM_INSTANCE_ID:-}"
  [ -n "$id" ] || { log "ORCA_VM_INSTANCE_ID is empty"; exit 1; }
  id="$(printf '%s' "${id#orca-}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' | cut -c1-20 | sed 's/-*$//')"
  printf '%s%s' "$SMOL_RECIPE_PREFIX" "$id"
}

machine_state() {  # prints running|stopped|paused|created|absent
  local json
  json="$("$SMOLVM" machine status --name "$1" --json 2>/dev/null)" || { echo absent; return; }
  printf '%s' "$json" | sed -n 's/^  "state": "\([a-z]*\)".*/\1/p'
}

machine_label() {  # machine_label NAME KEY
  "$SMOLVM" machine status --name "$1" --json 2>/dev/null \
    | sed -n "s/^ *\"$2\": \"\\([^\"]*\\)\".*/\\1/p" | head -1
}

json_str() {  # JSON string escape for the controlled values below
  local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"
}

ssh_guest() {  # ssh_guest PORT CMD...
  local port="$1"; shift
  ssh -i "$SMOL_RECIPE_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$SMOL_RECIPE_KNOWN_HOSTS" -o ConnectTimeout=3 -p "$port" root@127.0.0.1 "$@"
}

wait_for_ssh() {  # wait_for_ssh PORT
  local _
  for _ in $(seq 1 100); do
    if ssh_guest "$1" true 2>/dev/null; then return 0; fi
    sleep 0.2
  done
  log "sshd on 127.0.0.1:$1 did not answer"; return 1
}

# The one JSON object Orca reads from create and resume.
emit_result() {  # emit_result NAME PORT PROJECT_ROOT
  local name="$1" port="$2" root="$3" v="${ORCA_RECIPE_RESULT_SCHEMA_VERSION:-1}" mode=""
  [ "$v" = 2 ] && mode='"checkoutMode":"provisioned-root",'
  printf '{"schemaVersion":%s,%s"connection":{"type":"ssh","projectRoot":%s,"target":{"label":%s,"host":"127.0.0.1","port":%s,"username":"root","identityFile":%s,"identitiesOnly":true}},"userData":{"provider":"smolvm","machine":%s,"sshPort":%s}}\n' \
    "$v" "$mode" "$(json_str "$root")" "$(json_str "smolvm $name")" "$port" \
    "$(json_str "$SMOL_RECIPE_KEY")" "$(json_str "$name")" "$port"
}
