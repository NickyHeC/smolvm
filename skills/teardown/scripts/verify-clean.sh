#!/usr/bin/env bash
# Prove the host is clean after a teardown. Every check asserts a value rather
# than an exit code, because the commands teardown runs report success while
# leaving state behind.
#
# usage: verify-clean.sh [--protected <dir>] [--since <date>]
#   --protected <dir>  assert nothing under <dir> was written on or after --since.
#                      Point it at a real installation you ran beside: that is how
#                      you show a test under an isolated HOME did not reach it.
#                      Omitted, the check is reported as not run rather than passed.
#   --since <date>     the cutoff for --protected (default: today)

set -uo pipefail

SMOLVM="${SMOLVM:-$(command -v smolvm 2>/dev/null)}"
since="$(date +%F)"
protected=""
while [ $# -gt 0 ]; do
    case "$1" in
        --protected) protected="$2"; shift ;;
        --since)     since="$2"; shift ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf '%s=ok\n' "$1"
    else
        printf '%s=FAIL expected=%s actual=%s\n' "$1" "$3" "$2"
        fail=1
    fi
}

if [ -n "$SMOLVM" ]; then
    if "$SMOLVM" machine list 2>&1 | grep -q 'No machines found'; then
        check machines clean clean
    else
        check machines dirty clean
    fi
else
    printf 'machines=skipped (smolvm not on PATH; it may already be uninstalled)\n'
fi

case "$(uname -s)" in
    Darwin) cache_dir="$HOME/Library/Caches/smolvm" ;;
    *)      cache_dir="${SMOLVM_DATA_DIR:-$HOME/.cache/smolvm}" ;;
esac
VMS_DIR="${SMOLVM_VMS_DIR:-$cache_dir/vms}"

# List the VM processes belonging to this HOME's smolvm state, as "pid config".
#
# Match on argv, not on a pattern over the whole command line: `pgrep -f _boot-vm`
# matches any shell whose text contains that string, including this script, and
# that produced a phantom orphan in the runs behind this packet. Requiring
# argv[1] to be exactly `_boot-vm` cannot match a shell.
#
# `readlink /proc/<pid>/exe` is the other obvious route and it does not work
# here: the VM process is not dumpable, so its /proc/<pid>/exe is root-owned and
# readlink returns "Permission denied" to the user who started it. A reaper
# built on it reports "no orphans" while an orphan runs.
list_vm_processes() {
    case "$(uname -s)" in
        Linux)
            for p in /proc/[0-9]*; do
                [ -r "$p/cmdline" ] || continue
                sub="$(tr '\0' '\n' < "$p/cmdline" 2>/dev/null | sed -n '2p')"
                [ "$sub" = "_boot-vm" ] || continue
                cfg="$(tr '\0' '\n' < "$p/cmdline" 2>/dev/null | sed -n '3p')"
                case "$cfg" in "$VMS_DIR"/*) printf '%s %s\n' "${p#/proc/}" "$cfg" ;; esac
            done
            ;;
        Darwin)
            ps -axo pid=,command= 2>/dev/null | while read -r pid rest; do
                case "$rest" in
                    *" _boot-vm "*) cfg="${rest#* _boot-vm }" ;;
                    *) continue ;;
                esac
                case "$cfg" in "$VMS_DIR"/*) printf '%s %s\n' "$pid" "$cfg" ;; esac
            done
            ;;
    esac
}

# _shared is the --oci-cache image store, not residue. Excluding it is what
# makes this a leak check rather than a false alarm.
if [ -d "$cache_dir/vms" ]; then
    left="$(find "$cache_dir/vms" -mindepth 1 -maxdepth 1 -type d ! -name _shared 2>/dev/null | wc -l | tr -d ' ')"
else
    left=0
fi
check vm_dirs "$left" 0

procs="$(list_vm_processes | grep -c . )"
check vm_processes "$procs" 0

# Proof that a run under an isolated HOME left a real installation alone. Silence
# here would read as a pass, so an unchecked run says so.
if [ -n "$protected" ]; then
    touched="$(find "$protected" -newermt "$since" 2>/dev/null | wc -l | tr -d ' ')"
    check "protected_untouched_since_$since" "$touched" 0
else
    printf 'protected=not_checked (pass --protected <dir> to assert a real install was untouched)\n'
fi

if [ "$fail" -eq 0 ]; then printf 'result=clean\n'; else printf 'result=dirty\n'; fi
exit "$fail"
