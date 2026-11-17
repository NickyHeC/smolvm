#!/usr/bin/env bash
# Orca `suspend`: pause keeps RAM and processes (agents, shells, sshd) and frees the CPU.
source "$(dirname "$0")/smolvm-lib.sh"
cat >/dev/null   # the lifecycle payload; the instance id also arrives in ORCA_VM_INSTANCE_ID
name="$(machine_name)"
case "$(machine_state "$name")" in
  running) "$SMOLVM" machine pause --name "$name" >&2 ;;
  paused|stopped) log "$name already $(machine_state "$name")" ;;
  *) log "$name not found"; exit 1 ;;
esac
