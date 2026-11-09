#!/usr/bin/env bash
# Report whether this host can hold a rolling window. Read-only: starts no VM and
# installs no timer. The last line is always result=ready or result=blocked.
#
# usage: preflight.sh --dir <dir> [--every <seconds>] [--window <seconds>]

set -uo pipefail

VERIFIED_VERSION="1.34.0"

emit() { printf '%s=%s\n' "$1" "$2"; }
note() { printf 'note=%s\n' "$1"; }

DIR="."
EVERY=30
WINDOW=600
while [ $# -gt 0 ]; do
    case "$1" in
        --dir)    DIR="$2"; shift ;;
        --every)  EVERY="$2"; shift ;;
        --window) WINDOW="$2"; shift ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

blocked=0
SMOLVM="${SMOLVM:-$(command -v smolvm 2>/dev/null)}"
if [ -z "$SMOLVM" ]; then
    emit smolvm_installed no
    blocked=1
else
    emit smolvm_installed yes
    version="$("$SMOLVM" --version 2>/dev/null | awk '{print $NF}')"
    emit smolvm_version "${version:-unknown}"
    emit verified_version "$VERIFIED_VERSION"
    if [ "${version:-}" = "$VERIFIED_VERSION" ]; then
        emit version_status match
    else
        newest="$(printf '%s\n%s\n' "${version:-0}" "$VERIFIED_VERSION" | sort -V | tail -1)"
        if [ "$newest" = "${version:-}" ]; then emit version_status newer; else emit version_status older; fi
        note "this packet was verified on $VERIFIED_VERSION and the binary is ${version:-unknown}; check the output against the binary before trusting a step here"
    fi
    ckhelp="$("$SMOLVM" machine checkpoint --help 2>&1)"
    for flag in --store --history; do
        k="has_${flag#--}"
        if printf '%s' "$ckhelp" | grep -q -- "$flag"; then emit "$k" yes; else emit "$k" no; blocked=1; fi
    done
    if "$SMOLVM" machine checkpoint-log --help >/dev/null 2>&1; then emit has_checkpoint_log yes; else emit has_checkpoint_log no; blocked=1; fi
    createhelp="$("$SMOLVM" machine create --help 2>&1)"
    if printf '%s' "$createhelp" | grep -q -- '--at <GENERATION>'; then emit restore_by_id yes; else emit restore_by_id no; blocked=1; fi
fi

history=$((WINDOW / EVERY))
emit every_s "$EVERY"
emit window_s "$WINDOW"
emit history "$history"
# smolvm's MAX_RETAINED_GENERATIONS.
if [ "$history" -lt 1 ] || [ "$history" -gt 256 ]; then
    emit history_ok no
    blocked=1
    note "smolvm keeps 1 to 256 generations; widen --every or narrow --window"
else
    emit history_ok yes
fi

case "$(uname -s)" in
    Darwin)
        emit platform "darwin-$(uname -m)"
        if [ "$(sysctl -n kern.hv_support 2>/dev/null)" = 1 ]; then emit accel_access ok; else emit accel_access denied; blocked=1; fi
        emit timer launchd
        if launchctl print "gui/$(id -u)" >/dev/null 2>&1; then emit timer_domain ok; else emit timer_domain missing; blocked=1; note "no gui/$(id -u) launchd domain; log in at the console, since an SSH session has none"; fi
        sock="$HOME/Library/Caches/smolvm/vms/0123456789abcdef/agent.sock"
        emit socket_path_bytes "${#sock}"
        if [ "${#sock}" -gt 100 ]; then emit socket_path_status too_long; blocked=1; note "HOME is too deep: every VM start would fail, since macOS sockaddr_un holds 104 bytes"; else emit socket_path_status ok; fi
        # A launchd job gets Operation not permitted under these, and never logs a capture.
        readable=yes
        for p in "$(cd "$(dirname "$DIR")" 2>/dev/null && pwd)/" "$(dirname "${SMOLVM:-/}")/"; do
            case "$p" in
                /Users/*/Documents/*|/Users/*/Desktop/*|/Users/*/Downloads/*)
                    readable=no
                    blocked=1
                    note "$p is under Documents, Desktop or Downloads, which macOS keeps from a launchd job. Put the window directory and smolvm elsewhere." ;;
            esac
        done
        emit dir_readable_by_timer "$readable"
        ;;
    Linux)
        emit platform "linux-$(uname -m)"
        if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then emit accel_access ok; else emit accel_access denied; blocked=1; note "your user cannot open /dev/kvm"; fi
        emit timer systemd
        if systemctl --user show-environment >/dev/null 2>&1; then emit timer_domain ok; else emit timer_domain missing; blocked=1; note "no systemd user instance; the timer needs one"; fi
        ;;
    *)
        emit platform "unsupported-$(uname -s)"
        blocked=1
        ;;
esac

mkdir -p "$DIR" 2>/dev/null
free_mib="$(df -Pm "$DIR" 2>/dev/null | awk 'NR==2{print $4}')"
emit store_free_mib "${free_mib:-unknown}"
# Each restored machine holds its own copy-on-write disks and RAM on top.
if [ -n "${free_mib:-}" ] && [ "$free_mib" -lt 10240 ]; then
    emit store_space_ok no
    blocked=1
    note "under 10 GiB free where the window goes: a 4 GiB machine's window measured 3.7 GiB, and each rewind about 2.6 GiB more"
else
    emit store_space_ok yes
fi

# start-supplied.sh, which a machine with credential bindings needs after a rewind.
if command -v curl >/dev/null 2>&1; then emit has_curl yes; else emit has_curl no; note "rewind.sh --supply needs curl; a machine with no credential bindings does not"; fi
if [ "$blocked" -eq 0 ]; then emit result ready; else emit result blocked; fi
