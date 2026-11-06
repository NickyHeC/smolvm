#!/usr/bin/env bash
# Create and start a machine an agent can run in and a capture will accept: no
# host mounts, no SSH agent, and any API key as a credential binding, so the guest
# holds a placeholder. Started --branchable, as the engine's documentation asks.
#
# usage: start-machine.sh --dir <dir> --name <machine> [--image <image>] [--cpus <n>] [--mem <MiB>]
#                         [--credential <NAME=VAR@HOST>]... [--install '<shell command>']
#
# It also starts a small marker in the guest: a random token and a one-second
# counter in /dev/shm, which is RAM, so a rewind can show that memory came back.
# The value of each credential comes from this script's environment.

set -uo pipefail
umask 077

DIR=""
NAME=""
IMAGE="node:22-bookworm-slim"
CPUS=4
MEM=4096
INSTALL=""
CREDS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --dir)        DIR="$2"; shift ;;
        --name)       NAME="$2"; shift ;;
        --image)      IMAGE="$2"; shift ;;
        --cpus)       CPUS="$2"; shift ;;
        --mem)        MEM="$2"; shift ;;
        --install)    INSTALL="$2"; shift ;;
        --credential) CREDS+=(--credential "$2")
                      var="${2#*=}"; var="${var%%@*}"
                      [ -n "${!var:-}" ] || { printf 'result=FAILED %s is not set; every request to the bound host would answer 502\n' "$var"; exit 2; }
                      shift ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done
if [ -z "$DIR" ] || [ -z "$NAME" ]; then
    printf 'usage: start-machine.sh --dir <dir> --name <machine> [--image <image>] [--cpus <n>] [--mem <MiB>] [--credential <NAME=VAR@HOST>]... [--install <cmd>]\n' >&2
    exit 2
fi
SMOLVM="${SMOLVM:-$(command -v smolvm 2>/dev/null)}"
[ -n "$SMOLVM" ] || { printf 'smolvm not found; set SMOLVM to its path\n' >&2; exit 2; }
mkdir -p "$DIR"

if ! "$SMOLVM" machine create --name "$NAME" --net --image "$IMAGE" --cpus "$CPUS" --mem "$MEM" ${CREDS[@]+"${CREDS[@]}"} 2>&1 | sed 's/^/  /'; then
    printf 'result=FAILED machine create\n'
    exit 1
fi
printf '%s\n' "$NAME" >> "$DIR/machines"
if ! "$SMOLVM" machine start --name "$NAME" --branchable 2>&1 | sed 's/^/  /'; then
    printf 'result=FAILED machine start\n'
    exit 1
fi
if [ -n "$INSTALL" ]; then
    "$SMOLVM" machine exec --name "$NAME" --timeout 900sec -- sh -c "$INSTALL" 2>&1 | sed 's/^/  /'
    [ "${PIPESTATUS[0]}" -eq 0 ] || { printf 'result=FAILED the install command\n'; exit 1; }
fi

marker='od -An -N8 -tx1 /dev/urandom | tr -d " \n" > /dev/shm/rewind_token; (i=0; while :; do i=$((i+1)); echo $i > /dev/shm/rewind_counter; sleep 1; done) </dev/null >/dev/null 2>&1 &'
"$SMOLVM" machine exec --name "$NAME" -- sh -c "$marker" 2>&1 | sed 's/^/  /'
sleep 2
token="$("$SMOLVM" machine exec --name "$NAME" -- cat /dev/shm/rewind_token 2>&1)"
counter="$("$SMOLVM" machine exec --name "$NAME" -- cat /dev/shm/rewind_counter 2>&1)"
printf 'ram_token=%s\nram_counter=%s\n' "$token" "$counter"
case "$counter" in
    ''|*[!0-9]*) printf 'result=FAILED the marker is not counting: %s\n' "$counter"; exit 1 ;;
esac
printf 'result=up\n'
