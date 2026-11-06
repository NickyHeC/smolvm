#!/usr/bin/env bash
# Start a stopped machine restored from a checkpoint, handing it the values of its
# credential bindings. machine start cannot: a restored machine takes values only
# from the API, never from the environment, because a checkpoint chose both the
# variable and the destination. So a private `smolvm serve` lives for this one
# start; the machine keeps its values and keeps running after the server goes.
#
# usage: start-supplied.sh --name <machine> --supply <BINDING>=<VAR> [--supply ...]
#   <BINDING> is the name in --credential NAME=VAR@HOST
#   <VAR> is the variable in this script's environment that holds the value

set -uo pipefail
umask 077

NAME=""
SUPPLY=()
while [ $# -gt 0 ]; do
    case "$1" in
        --name)   NAME="$2"; shift ;;
        --supply) SUPPLY+=("$2"); shift ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done
if [ -z "$NAME" ] || [ "${#SUPPLY[@]}" -eq 0 ]; then
    printf 'usage: start-supplied.sh --name <machine> --supply <BINDING>=<VAR> [--supply ...]\n' >&2
    exit 2
fi
SMOLVM="${SMOLVM:-$(command -v smolvm 2>/dev/null)}"
[ -n "$SMOLVM" ] || { printf 'smolvm not found; set SMOLVM to its path\n' >&2; exit 2; }

SERVE_PID=""
serve_dir="$(mktemp -d /tmp/rw.XXXXXX)"
sock="$serve_dir/s"
stop_serve() {
    [ -n "$SERVE_PID" ] && { kill "$SERVE_PID" 2>/dev/null; wait "$SERVE_PID" 2>/dev/null; }
    rm -rf "${serve_dir:?}"
}
trap stop_serve EXIT

# Build the body first, so a missing value stops this before anything starts. The
# value leaves here in a request body on standard input, never on a command line,
# and the server does not get it in its environment.
body='{"values":{'
sep=""
unset_vars=()
for s in "${SUPPLY[@]}"; do
    binding="${s%%=*}"; var="${s#*=}"
    value="${!var:-}"
    [ -n "$value" ] || { printf 'result=FAILED %s is not set, so binding %s has no value\n' "$var" "$binding"; exit 1; }
    case "$value" in *\"*|*\\*) printf 'result=FAILED the value of %s holds a quote or a backslash, which this script does not escape\n' "$var"; exit 1 ;; esac
    body="$body$sep\"$binding\":\"$value\""
    sep=","
    unset_vars+=(-u "$var")
done
body="$body}}"

# --guest-rollout-port: every server binds it, so this one must not collide with another.
env "${unset_vars[@]}" "$SMOLVM" serve start -l "unix://$sock" --guest-rollout-port $((20000 + $$ % 20000)) >"$serve_dir/serve.log" 2>&1 &
SERVE_PID=$!
ready=no
for _ in $(seq 1 100); do
    if curl -s -o /dev/null --unix-socket "$sock" http://l/health; then ready=yes; break; fi
    sleep 0.1
done
[ "$ready" = yes ] || { printf 'result=FAILED the private server did not answer: %s\n' "$(cut -c1-300 "$serve_dir/serve.log")"; exit 1; }

code="$(printf '%s' "$body" | curl -s -o /dev/null -w '%{http_code}' --unix-socket "$sock" -X PUT -H 'Content-Type: application/json' --data-binary @- "http://l/api/v1/machines/$NAME/credential-values")"
body=""; value=""
[ "$code" = 204 ] || { printf 'result=FAILED credential-values answered %s\n' "$code"; exit 1; }
code="$(curl -s -o "$serve_dir/start.json" -w '%{http_code}' --unix-socket "$sock" -X POST -H 'Content-Type: application/json' -d '{"branchable":true}' "http://l/api/v1/machines/$NAME/start")"
[ "$code" = 200 ] || { printf 'result=FAILED start answered %s: %s\n' "$code" "$(cut -c1-300 "$serve_dir/start.json")"; exit 1; }
printf 'credentials_supplied=%s\n' "${#SUPPLY[@]}"
