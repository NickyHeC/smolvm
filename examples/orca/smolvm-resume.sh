#!/usr/bin/env bash
# Orca `resume`: resume a paused machine, or start a stopped one, and print the result again.
source "$(dirname "$0")/smolvm-lib.sh"
cat >/dev/null
name="$(machine_name)"
case "$(machine_state "$name")" in
  paused) "$SMOLVM" machine resume --name "$name" >&2 ;;
  stopped) "$SMOLVM" machine start --name "$name" >&2 ;;
  running) ;;
  *) log "$name not found"; exit 1 ;;
esac
port="$(machine_label "$name" orca-ssh-port)"
[ -n "$port" ] || { log "no orca-ssh-port label on $name"; exit 1; }
root="$(machine_label "$name" orca-project-root)"
[ -n "$root" ] || { log "no orca-project-root label on $name"; exit 1; }
wait_for_ssh "$port"
emit_result "$name" "$port" "$root"
