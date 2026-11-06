#!/usr/bin/env bash
# One capture for a rolling window: the command the timer runs. Reads its
# settings from <dir>/rewind.conf each time, so retargeting needs no new timer.
#
# usage: capture.sh --dir <dir>
#
# The capture goes into <dir>/store with --history from the config, under a new
# directory in <dir>/checkpoints. It counts only once checkpoint-log lists it as
# (this checkpoint); then the machine's older directories go and the store is
# pruned. One key=value line per run is appended to <dir>/capture.log.
# Exit status: 0 captured, 3 skipped (another capture or a rewind holds the lock),
# 1 failed, in which case nothing older was deleted.

set -uo pipefail
umask 077

DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dir) DIR="$2"; shift ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done
[ -n "$DIR" ] && [ -f "$DIR/rewind.conf" ] || { printf 'usage: capture.sh --dir <dir>, with rewind.conf in it\n' >&2; exit 2; }

conf() { sed -n "s/^$1=//p" "$DIR/rewind.conf" | tail -1; }
NAME="$(conf machine)"
HISTORY="$(conf history)"
SMOLVM="${SMOLVM:-$(command -v smolvm 2>/dev/null)}"
[ -n "$SMOLVM" ] || { printf 'smolvm not found; set SMOLVM to its path\n' >&2; exit 2; }

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
record() { printf 'ts=%s machine=%s %s\n' "$(now)" "$NAME" "$1" | tee -a "$DIR/capture.log"; }

# mkdir is atomic and macOS has no flock(1). A lock whose owner is gone is taken over.
LOCK="$DIR/.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    owner="$(cat "$LOCK/pid" 2>/dev/null)"
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
        record "result=skipped holder=$owner"
        exit 3
    fi
    rm -rf "${LOCK:?}"
    mkdir "$LOCK" || { record "result=FAILED note=could_not_take_the_lock"; exit 1; }
fi
printf '%s\n' "$$" > "$LOCK/pid"
trap 'rm -rf "${LOCK:?}"' EXIT

mkdir -p "$DIR/store" "$DIR/checkpoints"
output="$DIR/checkpoints/$NAME-$(date -u +%Y%m%dT%H%M%SZ).smolcheckpoint"
out="$("$SMOLVM" machine checkpoint --name "$NAME" --store "$DIR/store" --output "$output" --history "$HISTORY" 2>&1 </dev/null)"
rc=$?
log="$("$SMOLVM" machine checkpoint-log "$output" 2>&1 </dev/null)"

if [ "$rc" -ne 0 ] || ! printf '%s' "$log" | grep -q '(this checkpoint)'; then
    # The engine's words, on one line, so the log names the cause.
    why="$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-400)"
    record "result=FAILED rc=$rc error=\"$why\""
    case "$out" in
        *"must be running"*)
            record "note=the guest agent did not answer in time; after a long pause this clears by itself. If it stays, see 'an exec that met a pause' in references/traps.md" ;;
    esac
    exit 1
fi

# "Checkpointed 'x' to ... (121 MiB written, 2.486s total, 0.142s source pause)"
line="$(printf '%s\n' "$out" | grep '^Checkpointed')"
written="$(printf '%s' "$line" | sed -n 's/.*(\([0-9.]*\) MiB written.*/\1/p')"
total="$(printf '%s' "$line" | sed -n 's/.* \([0-9.]*\)s total.*/\1/p')"
pause="$(printf '%s' "$line" | sed -n 's/.* \([0-9.]*\)s source pause.*/\1/p')"
generations="$(printf '%s\n' "$log" | grep -c '^~')"
generation="$(printf '%s\n' "$log" | awk '$1=="~0"{print $2}')"

# Only this machine's older directories: the stamp keeps agent-b out of agent's
# count. A rewound machine's captures leave the machine it came from alone, whose
# newest directory is the one way back to it.
deleted=0
set -- "$DIR/checkpoints/$NAME"-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z.smolcheckpoint
while [ "$#" -gt 1 ]; do
    rm -rf -- "${1:?}" && deleted=$((deleted + 1))
    shift
done
prune_start="$(date +%s)"
prune="$("$SMOLVM" machine checkpoint-prune --store "$DIR/store" 2>&1 </dev/null)"
prune_rc=$?
prune_s=$(( $(date +%s) - prune_start ))
[ "$prune_rc" -eq 0 ] || record "note=prune_failed error=\"$(printf '%s' "$prune" | tr '\n' ' ' | cut -c1-300)\""

record "result=captured generation=$generation generations=$generations capture_s=${total:-?} pause_s=${pause:-?} written_mib=${written:-?} deleted=$deleted prune_s=$prune_s dir_mib=$(du -sm "$DIR/store" "$DIR/checkpoints" 2>/dev/null | awk '{s+=$1} END {print s}')"
