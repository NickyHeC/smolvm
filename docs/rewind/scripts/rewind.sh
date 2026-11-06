#!/usr/bin/env bash
# Bring back a machine as it was some time ago, as a new machine. Reads the newest
# capture's history, picks the newest generation at or before that moment and
# selects it by id, because ~N shifts with every capture.
#
# usage: rewind.sh --dir <dir> --ago <time> --name <new> [--keep-identity] [--supply <BINDING>=<VAR>]...
#   --ago <time>            90, 90s, 5m, 9m30s or 1h
#   --name <new>            the machine to create; the source keeps running
#   --keep-identity         keep the hostname and machine ID, not its own name
#   --supply <BINDING>=<VAR>  a credential binding the machine holds, and the
#                           variable in this script's environment that holds its value
#
# A restored machine never reads a credential value from its environment, so a
# machine with bindings needs --supply: machine start cannot hand one over.
# start-supplied.sh is how the value gets there.

set -uo pipefail
umask 077

here="$(cd "$(dirname "$0")" && pwd)"
DIR=""
AGO=""
NAME=""
KEEP=()
SUPPLY=()
while [ $# -gt 0 ]; do
    case "$1" in
        --dir)  DIR="$2"; shift ;;
        --ago)  AGO="$2"; shift ;;
        --name) NAME="$2"; shift ;;
        --keep-identity) KEEP=(--keep-identity) ;;
        --supply) SUPPLY+=("$2"); shift ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done
if [ -z "$DIR" ] || [ -z "$AGO" ] || [ -z "$NAME" ]; then
    printf 'usage: rewind.sh --dir <dir> --ago <time> --name <new> [--keep-identity] [--supply <BINDING>=<VAR>]...\n' >&2
    exit 2
fi
[ -f "$DIR/rewind.conf" ] || { printf 'result=FAILED no rewind.conf in %s\n' "$DIR"; exit 1; }
SMOLVM="${SMOLVM:-$(command -v smolvm 2>/dev/null)}"
[ -n "$SMOLVM" ] || { printf 'smolvm not found; set SMOLVM to its path\n' >&2; exit 2; }

# 90, 90s, 5m, 9m30s, 1h to seconds.
seconds() {
    local rest="$1" total=0 n u
    case "$rest" in *[0-9]) rest="${rest}s" ;; esac
    while [ -n "$rest" ]; do
        n="${rest%%[!0-9]*}"
        u="${rest#"$n"}"; u="${u%"${u#?}"}"
        [ -n "$n" ] || return 1
        case "$u" in s) total=$((total + n)) ;; m) total=$((total + n * 60)) ;; h) total=$((total + n * 3600)) ;; *) return 1 ;; esac
        rest="${rest#"$n$u"}"
    done
    printf '%s' "$total"
}
# checkpoint-log's UTC stamp to epoch seconds, on either date(1).
epoch() {
    case "$(uname -s)" in
        Darwin) date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s ;;
        *)      date -u -d "$1" +%s ;;
    esac
}

ago_s="$(seconds "$AGO")" || { printf 'result=FAILED --ago takes 90, 90s, 5m, 9m30s or 1h, not %s\n' "$AGO"; exit 2; }
machine="$(sed -n 's/^machine=//p' "$DIR/rewind.conf")"
every="$(sed -n 's/^every=//p' "$DIR/rewind.conf")"
started="$(date +%s)"
target=$((started - ago_s))

# Hold the capture lock so the timer cannot delete the directory being read. A
# capture in progress finishes first; a slot that falls in here logs as skipped.
LOCK="$DIR/.lock"
waited=0
until mkdir "$LOCK" 2>/dev/null; do
    owner="$(cat "$LOCK/pid" 2>/dev/null)"
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then rm -rf "${LOCK:?}"; continue; fi
    [ "$waited" -lt 120 ] || { printf 'result=FAILED %s stayed locked for 120 s\n' "$LOCK"; exit 1; }
    sleep 1; waited=$((waited + 1))
done
printf '%s\n' "$$" > "$LOCK/pid"
release() { rm -rf "${LOCK:?}"; }
trap release EXIT

set -- "$DIR/checkpoints/$machine"-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z.smolcheckpoint
[ -e "$1" ] || { printf 'result=FAILED no capture of %s in %s/checkpoints\n' "$machine" "$DIR"; exit 1; }
while [ "$#" -gt 1 ]; do shift; done
newest="$1"
log="$("$SMOLVM" machine checkpoint-log "$newest" 2>&1)" || { printf 'result=FAILED checkpoint-log: %s\n' "$log"; exit 1; }

# Newest first, so the first line at or before the target is the one.
pick=""; pick_time=""; oldest_time=""
while read -r gen id stamp _; do
    case "$gen" in "~"*) ;; *) continue ;; esac
    t="$(epoch "$stamp")"
    oldest_time="$t"
    if [ -z "$pick" ] && [ "$t" -le "$target" ]; then pick="$id"; pick_time="$t"; fi
done <<<"$log"
if [ -z "$pick" ]; then
    printf 'oldest_capture_age_s=%s\n' "$((started - ${oldest_time:-started}))"
    printf 'result=FAILED nothing that old: the window holds no capture from %ss ago\n' "$ago_s"
    exit 1
fi

printf 'source=%s\n' "$machine"
printf 'asked_ago_s=%s\n' "$ago_s"
printf 'generation=%s\n' "$pick"
printf 'generation_time=%s\n' "$pick_time"
printf 'generation_age_s=%s\n' "$((started - pick_time))"
distance=$((target - pick_time))
printf 'distance_from_asked_s=%s\n' "$distance"
if [ "$distance" -gt $((every * 2)) ]; then
    printf 'note=the nearest capture is %ss before the moment asked for: slots were skipped there, or the source was itself rewound there\n' "$distance"
fi

if ! "$SMOLVM" machine create --name "$NAME" --from "$newest" --at "$pick" ${KEEP[@]+"${KEEP[@]}"} 2>&1 | sed 's/^/  /'; then
    printf 'result=FAILED machine create --from did not succeed, so nothing was restored\n'
    exit 1
fi
release; trap - EXIT
printf '%s\n' "$NAME" >> "$DIR/machines"

if [ "${#SUPPLY[@]}" -eq 0 ]; then
    "$SMOLVM" machine start --name "$NAME" --branchable 2>&1 | sed 's/^/  /'
else
    args=()
    for s in "${SUPPLY[@]}"; do args+=(--supply "$s"); done
    "$here/start-supplied.sh" --name "$NAME" "${args[@]}" || exit 1
fi

# A value from the guest, not the start command's word.
marker="$("$SMOLVM" machine exec --name "$NAME" -- sh -c 'cat /dev/shm/rewind_token 2>/dev/null && echo && cat /dev/shm/rewind_counter; true' 2>&1)"
rc=$?
printf 'seconds_to_first_answer=%s\n' "$(( $(date +%s) - started ))"
if [ "$rc" -ne 0 ]; then
    printf 'result=FAILED the restored machine did not answer: %s\n' "$marker"
    exit 1
fi
if [ -n "$marker" ]; then
    printf 'ram_token=%s\n' "$(printf '%s\n' "$marker" | sed -n 1p)"
    printf 'ram_counter=%s\n' "$(printf '%s\n' "$marker" | sed -n 2p)"
fi
printf 'result=rewound\n'
