#!/usr/bin/env bash
# Run an untrusted command against a repo it must not modify, with no network,
# and collect its artifacts.
#
# usage: run.sh [--repo <dir>] [--out <dir>] [--image <img>] [--allow-host <h>]... -- <command...>
#   --repo <dir>        mounted read-only at /workspace (default ./repo)
#   --out  <dir>        mounted writable at /out        (default ./out)
#   --image <img>       must already be baked; see bake.sh (default python:3.12-alpine)
#   --allow-host <h>    grant egress to one host. Repeatable. Weakens the sandbox
#                       and the script says so; --allow-host implies --net.
#   --route <r>         offline (default) or network-on.
#                       offline    bake once, then run with no network at all.
#                       network-on no --oci-cache, the run pulls its own image and
#                       therefore has egress for the whole run. Use it only where
#                       offline does not work: macOS, where --oci-cache with any
#                       mount never boots (smol-machines/smolvm#1192), and any host
#                       that cannot give the bake helper its 8192 MiB.
#
# The VM's pid is recorded before the workload finishes, because Ctrl-C does not
# stop a smolvm machine: the VM outlives the CLI, `machine list` cannot see it,
# and it exits only when the untrusted workload does, which for code that hangs
# or loops is never (smol-machines/smolvm#1193). Cancel with
# `scripts/cleanup.sh --cancel`, never with Ctrl-C.

set -uo pipefail

REPO="./repo"
OUT="./out"
IMAGE="python:3.12-alpine"
ROUTE="offline"
allow=()

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)       REPO="$2"; shift ;;
        --out)        OUT="$2"; shift ;;
        --image)      IMAGE="$2"; shift ;;
        --allow-host) allow+=(--allow-host "$2"); shift ;;
        --route)      ROUTE="$2"; shift ;;
        --) shift; break ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

case "$ROUTE" in
    offline|network-on) ;;
    *) printf 'unknown route: %s (offline or network-on)\n' "$ROUTE" >&2; exit 2 ;;
esac

if [ $# -eq 0 ]; then
    printf 'no command given; everything after -- is run inside the sandbox\n' >&2
    exit 2
fi

SMOLVM="${SMOLVM:-$(command -v smolvm 2>/dev/null)}"
if [ -z "$SMOLVM" ]; then
    printf 'smolvm not found; set SMOLVM to its path\n' >&2
    exit 2
fi

if [ ! -d "$REPO" ]; then
    printf 'repo directory not found: %s\n' "$REPO" >&2
    exit 2
fi
mkdir -p "$OUT"
REPO="$(cd "$REPO" && pwd)"
OUT="$(cd "$OUT" && pwd)"

STATE_DIR="${SMOLVM_SKILL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/smolvm-skills}"
mkdir -p "$STATE_DIR"
PIDFILE="$STATE_DIR/sandbox.vmpids"

case "$(uname -s)" in
    Darwin) VMS_DIR="$HOME/Library/Caches/smolvm/vms" ;;
    *)      VMS_DIR="${SMOLVM_DATA_DIR:-$HOME/.cache/smolvm}/vms" ;;
esac
VMS_DIR="${SMOLVM_VMS_DIR:-$VMS_DIR}"

# Match argv, never a pattern over the whole command line: `pgrep -f _boot-vm`
# matches any shell whose text contains that string, including this script.
# `readlink /proc/<pid>/exe` is the other obvious route and finds nothing: the
# VM process is not dumpable, so its /proc entry is root-owned and readlink
# returns Permission denied to the user who started it.
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
                case "$rest" in *" _boot-vm "*) cfg="${rest#* _boot-vm }" ;; *) continue ;; esac
                case "$cfg" in "$VMS_DIR"/*) printf '%s %s\n' "$pid" "$cfg" ;; esac
            done
            ;;
    esac
}

before="$(list_vm_processes | awk '{print $1}' | sort)"

printf 'route=%s\n' "$ROUTE"
cache=(--oci-cache)
if [ "$ROUTE" = "network-on" ]; then
    # No host cache, so the run pulls its own image and needs the network for
    # the whole run. Say what that costs rather than letting it look equivalent.
    cache=()
    if [ "${#allow[@]}" -eq 0 ]; then
        allow=(--net)
        printf 'egress=all\n'
        printf 'note=network-on with no --allow-host gives the untrusted workload unrestricted egress for the whole run. Name the hosts it needs with --allow-host to narrow it.\n'
    else
        printf 'egress=granted %s\n' "${allow[*]}"
        printf 'note=the run also needs to reach the registry to pull its image, so the policy must include the registry hosts or the run will not start.\n'
    fi
    printf 'note=this is the weaker sandbox. The offline route reaches no network at all; this one is open for as long as the workload runs.\n'
elif [ "${#allow[@]}" -gt 0 ]; then
    printf 'egress=granted %s\n' "${allow[*]}"
    printf 'note=--allow-host implies --net. The workload can now reach the named hosts, and a denial looks like a DNS failure rather than a policy denial.\n'
else
    printf 'egress=none\n'
fi

logfile="$STATE_DIR/sandbox.lastrun.log"
"$SMOLVM" machine run --mem 2048 ${cache[@]+"${cache[@]}"} --image "$IMAGE" \
    --volume "$REPO:/workspace:ro" \
    --volume "$OUT:/out" \
    ${allow[@]+"${allow[@]}"} \
    -- "$@" > "$logfile" 2>&1 &
cli_pid=$!

# Record the VM before waiting on it. If the caller kills this script, the pid
# in that file is the only route back to the machine.
# 90 s: long enough to see the VM appear on a host that is pulling an image,
# and bounded so a workload that finishes instantly does not stall the script.
recorded=""
waited=0
while [ "$waited" -lt 90 ]; do
    while read -r pid cfg; do
        [ -n "$pid" ] || continue
        case "$(printf '%s\n' "$before" | grep -c "^$pid$")" in
            0) printf '%s %s\n' "$pid" "$cfg" >> "$PIDFILE"; recorded="$pid" ;;
        esac
    done <<EOF
$(list_vm_processes)
EOF
    [ -n "$recorded" ] && break
    kill -0 "$cli_pid" 2>/dev/null || break
    sleep 1
    waited=$((waited + 1))
done

if [ -n "$recorded" ]; then
    printf 'vm_pid=%s\n' "$recorded"
    printf 'vm_pid_recorded_in=%s\n' "$PIDFILE"
else
    printf 'vm_pid=not_observed\n'
    printf 'note=the VM was not seen before the run ended, which is normal for a command that finishes in under a second. Nothing to cancel.\n'
fi

wait "$cli_pid"
rc=$?
sed 's/^/  /' "$logfile"

# On the offline route the cache-hit line is the assertion that the bake worked
# and that this run reached no registry. Without it the run pulled, which means
# it had network, which means it was not the sandbox you asked for.
if [ "$ROUTE" = "offline" ]; then
    if grep -q 'host cache hit' "$logfile"; then
        printf 'used_host_cache=yes\n'
    else
        printf 'used_host_cache=no\n'
        printf 'note=no host cache hit on the offline route. Run bake.sh first: an ordinary earlier pull does not make a later run offline-capable, because the runtime still resolves the tag through the registry.\n'
    fi
else
    printf 'used_host_cache=n_a_on_this_route\n'
fi

printf 'cli_exit=%s\n' "$rc"
printf 'next: scripts/verify.sh, then scripts/cleanup.sh\n'
exit "$rc"
