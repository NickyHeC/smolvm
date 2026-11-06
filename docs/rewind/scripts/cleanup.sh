#!/usr/bin/env bash
# Remove a window: the timer, the machines these scripts created, the window
# directory, and smolvm's copies of restored checkpoints. A machine you created
# yourself and only named to the timer is never deleted.
#
# usage: cleanup.sh --dir <dir> [--keep-machines] [--restore-base]
#   --keep-machines   leave the recorded machines running
#   --restore-base    also remove vms/_restore-base and vms/_restore-checkpoints,
#                     which hold restored RAM and outlive the checkpoints

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
DIR=""
KEEP=0
BASE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dir) DIR="$2"; shift ;;
        --keep-machines) KEEP=1 ;;
        --restore-base) BASE=1 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done
[ -n "$DIR" ] || { printf 'usage: cleanup.sh --dir <dir> [--keep-machines] [--restore-base]\n' >&2; exit 2; }
SMOLVM="${SMOLVM:-$(command -v smolvm 2>/dev/null)}"
[ -n "$SMOLVM" ] || { printf 'smolvm not found; set SMOLVM to its path\n' >&2; exit 2; }

# The timer first, so no capture starts while the rest goes.
"$here/timer.sh" remove --dir "$DIR" | sed 's/^/  /'
waited=0
while [ -d "$DIR/.lock" ] && [ "$waited" -lt 120 ]; do sleep 1; waited=$((waited + 1)); done

remaining=0
if [ -f "$DIR/machines" ] && [ "$KEEP" -eq 0 ]; then
    while read -r name; do
        [ -n "$name" ] || continue
        listing="$("$SMOLVM" machine list </dev/null 2>/dev/null | awk 'NR>2{print $1}')"
        printf '%s\n' "$listing" | grep -qx -- "$name" || continue
        "$SMOLVM" machine stop --name "$name" </dev/null >/dev/null 2>&1
        "$SMOLVM" machine delete --name "$name" --force --cascade </dev/null 2>&1 | sed 's/^/  /'
        listing="$("$SMOLVM" machine list </dev/null 2>/dev/null | awk 'NR>2{print $1}')"
        if printf '%s\n' "$listing" | grep -qx -- "$name"; then
            printf 'still_listed=%s\n' "$name"
            remaining=$((remaining + 1))
        fi
    done < "$DIR/machines"
fi

# A window directory is known by its config, not by its name.
if [ -f "$DIR/rewind.conf" ]; then
    rm -rf -- "${DIR:?}" && printf 'removed=%s\n' "$DIR"
else
    printf 'skipped=%s has no rewind.conf\n' "$DIR"
fi

if [ "$BASE" -eq 1 ]; then
    case "$(uname -s)" in
        Darwin) vms="$HOME/Library/Caches/smolvm/vms" ;;
        *)      vms="${XDG_CACHE_HOME:-$HOME/.cache}/smolvm/vms" ;;
    esac
    for cache in _restore-base _restore-checkpoints; do
        if [ -d "$vms/$cache" ]; then
            rm -rf "${vms:?}/${cache:?}" "${vms:?}/${cache:?}.lock" && printf 'removed=%s\n' "$vms/$cache"
        else
            printf '%s=absent\n' "$cache"
        fi
    done
fi

[ "$remaining" -eq 0 ] && printf 'result=clean\n' || { printf 'result=FAILED %s machines remain\n' "$remaining"; exit 1; }
