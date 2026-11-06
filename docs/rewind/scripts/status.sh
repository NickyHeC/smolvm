#!/usr/bin/env bash
# What the window holds right now. Read-only.
#
# usage: status.sh --dir <dir>

set -uo pipefail

DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dir) DIR="$2"; shift ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done
[ -n "$DIR" ] && [ -f "$DIR/rewind.conf" ] || { printf 'usage: status.sh --dir <dir>, with rewind.conf in it\n' >&2; exit 2; }
SMOLVM="${SMOLVM:-$(command -v smolvm 2>/dev/null)}"
[ -n "$SMOLVM" ] || { printf 'smolvm not found; set SMOLVM to its path\n' >&2; exit 2; }

epoch() {
    case "$(uname -s)" in
        Darwin) date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s ;;
        *)      date -u -d "$1" +%s ;;
    esac
}
machine="$(sed -n 's/^machine=//p' "$DIR/rewind.conf")"
every="$(sed -n 's/^every=//p' "$DIR/rewind.conf")"
history="$(sed -n 's/^history=//p' "$DIR/rewind.conf")"
label="smolvm-rewind-$(basename "$(cd "$DIR" && pwd)")"
printf 'machine=%s\nevery_s=%s\nhistory=%s\n' "$machine" "$every" "$history"

case "$(uname -s)" in
    Darwin) if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then printf 'timer=loaded\n'; else printf 'timer=absent\n'; fi ;;
    Linux)  printf 'timer=%s\n' "$(systemctl --user is-active "$label.timer" 2>/dev/null)" ;;
esac

set -- "$DIR/checkpoints/$machine"-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z.smolcheckpoint
if [ -e "$1" ]; then
    while [ "$#" -gt 1 ]; do shift; done
    log="$("$SMOLVM" machine checkpoint-log "$1" 2>&1)"
    now="$(date +%s)"
    printf 'generations=%s\n' "$(printf '%s\n' "$log" | grep -c '^~')"
    newest_stamp="$(printf '%s\n' "$log" | awk '$1=="~0"{print $3}')"
    oldest_stamp="$(printf '%s\n' "$log" | awk '$1 ~ /^~/{s=$3} END {print s}')"
    [ -n "$newest_stamp" ] && printf 'newest_age_s=%s\n' "$((now - $(epoch "$newest_stamp")))"
    [ -n "$oldest_stamp" ] && printf 'oldest_age_s=%s\n' "$((now - $(epoch "$oldest_stamp")))"
else
    printf 'generations=0\n'
fi
printf 'store_mib=%s\n' "$(du -sm "$DIR/store" "$DIR/checkpoints" 2>/dev/null | awk '{s+=$1} END {print s+0}')"
if [ -f "$DIR/capture.log" ]; then
    printf 'captures=%s\n' "$(grep -c 'result=captured' "$DIR/capture.log")"
    printf 'skipped=%s\n' "$(grep -c 'result=skipped' "$DIR/capture.log")"
    printf 'failed=%s\n' "$(grep -c 'result=FAILED' "$DIR/capture.log")"
    printf 'last=%s\n' "$(grep 'result=' "$DIR/capture.log" | tail -1)"
fi
