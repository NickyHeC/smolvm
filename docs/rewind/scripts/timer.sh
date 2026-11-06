#!/usr/bin/env bash
# Install, retarget or remove the timer that runs capture.sh. launchd on macOS, a
# systemd user timer on Linux. cron's floor is one minute, so it serves no window
# with a shorter interval.
#
# usage: timer.sh install --dir <dir> --name <machine> [--every <seconds>] [--window <seconds>]
#        timer.sh retarget --dir <dir> --name <machine>
#        timer.sh drop --dir <dir> --name <previous machine>
#        timer.sh remove --dir <dir>
#   --every    seconds between captures (default 30)
#   --window   how far back a rewind must reach (default 600); --history is window / every
#
# drop removes a machine's last capture once the timer has moved off it, which gives
# up the generations it alone retained. The window directory has to be somewhere
# launchd may read: see preflight.sh.

set -uo pipefail
umask 077

here="$(cd "$(dirname "$0")" && pwd)"
ACTION="${1:-}"
[ $# -gt 0 ] && shift
DIR=""
NAME=""
EVERY=30
WINDOW=600
while [ $# -gt 0 ]; do
    case "$1" in
        --dir)    DIR="$2"; shift ;;
        --name)   NAME="$2"; shift ;;
        --every)  EVERY="$2"; shift ;;
        --window) WINDOW="$2"; shift ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done
if [ -z "$DIR" ]; then
    printf 'usage: timer.sh install|retarget|drop|remove --dir <dir> [--name <machine>] [--every <s>] [--window <s>]\n' >&2
    exit 2
fi
mkdir -p "$DIR"
DIR="$(cd "$DIR" && pwd)"

LABEL="smolvm-rewind-$(basename "$DIR")"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

SMOLVM="${SMOLVM:-$(command -v smolvm 2>/dev/null)}"
[ -n "$SMOLVM" ] || { printf 'smolvm not found; set SMOLVM to its path\n' >&2; exit 2; }

write_conf() {
    tmp="$DIR/rewind.conf.$$"
    printf 'machine=%s\nevery=%s\nhistory=%s\n' "$1" "$2" "$3" > "$tmp"
    mv "$tmp" "$DIR/rewind.conf"
}

# StartInterval counts from the end of the last run, so a 5 s capture made a 35 s
# slot. KeepAlive with ThrottleInterval relaunches counting from the last start.
install_launchd() {
    mkdir -p "$(dirname "$PLIST")"
    cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string>
    <string>$DIR/capture.sh</string>
    <string>--dir</string><string>$DIR</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>HOME</key><string>$HOME</string>
    <key>SMOLVM</key><string>$SMOLVM</string>
    <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>$EVERY</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$DIR/timer.out</string>
  <key>StandardErrorPath</key><string>$DIR/timer.out</string>
</dict></plist>
PLIST
    launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1
    launchctl bootstrap "gui/$(id -u)" "$PLIST" || { printf 'result=FAILED launchctl bootstrap refused %s\n' "$PLIST"; exit 1; }
    printf 'timer=launchd label=%s plist=%s\n' "$LABEL" "$PLIST"
}

install_systemd() {
    mkdir -p "$UNITS"
    cat > "$UNITS/$LABEL.service" <<UNIT
[Unit]
Description=smolvm rewind capture for $DIR

[Service]
Type=oneshot
Environment=HOME=$HOME
Environment=SMOLVM=$SMOLVM
ExecStart=/bin/bash $DIR/capture.sh --dir $DIR
SuccessExitStatus=3
UNIT
    # AccuracySec defaults to one minute, which would let a 30 s timer run a minute late.
    cat > "$UNITS/$LABEL.timer" <<UNIT
[Unit]
Description=smolvm rewind timer for $DIR

[Timer]
OnActiveSec=1s
OnUnitActiveSec=${EVERY}s
AccuracySec=1s

[Install]
WantedBy=timers.target
UNIT
    systemctl --user daemon-reload || { printf 'result=FAILED systemctl --user daemon-reload\n'; exit 1; }
    systemctl --user enable --now "$LABEL.timer" 2>&1 | sed 's/^/  /'
    printf 'timer=systemd label=%s units=%s\n' "$LABEL" "$UNITS"
    if [ "$(loginctl show-user "$(id -un)" --property=Linger --value 2>/dev/null)" != yes ]; then
        printf 'note=a user timer stops when you log out unless you run: loginctl enable-linger %s\n' "$(id -un)"
    fi
}

case "$ACTION" in
    install)
        [ -n "$NAME" ] || { printf 'install needs --name\n' >&2; exit 2; }
        case "$EVERY$WINDOW" in *[!0-9]*) printf 'result=FAILED --every and --window take whole seconds\n'; exit 2 ;; esac
        history=$((WINDOW / EVERY))
        if [ "$history" -lt 1 ] || [ "$history" -gt 256 ]; then
            printf 'result=FAILED --history would be %s; smolvm keeps 1 to 256 generations, so widen --every or narrow --window\n' "$history"
            exit 2
        fi
        write_conf "$NAME" "$EVERY" "$history"
        # A copy beside the store: launchd may not read a script under ~/Documents.
        cp "$here/capture.sh" "$DIR/capture.sh"
        case "$(uname -s)" in
            Darwin) install_launchd ;;
            Linux)  install_systemd ;;
            *) printf 'result=FAILED no timer form for %s\n' "$(uname -s)"; exit 1 ;;
        esac
        printf 'machine=%s every_s=%s window_s=%s history=%s\n' "$NAME" "$EVERY" "$WINDOW" "$history"
        printf 'result=installed\n'
        ;;
    retarget)
        [ -n "$NAME" ] || { printf 'retarget needs --name\n' >&2; exit 2; }
        [ -f "$DIR/rewind.conf" ] || { printf 'result=FAILED no rewind.conf in %s\n' "$DIR"; exit 1; }
        old="$(sed -n 's/^machine=//p' "$DIR/rewind.conf")"
        write_conf "$NAME" "$(sed -n 's/^every=//p' "$DIR/rewind.conf")" "$(sed -n 's/^history=//p' "$DIR/rewind.conf")"
        printf 'previous_machine=%s\nmachine=%s\nresult=retargeted\n' "$old" "$NAME"
        ;;
    drop)
        [ -n "$NAME" ] || { printf 'drop needs --name\n' >&2; exit 2; }
        current="$(sed -n 's/^machine=//p' "$DIR/rewind.conf")"
        [ "$NAME" != "$current" ] || { printf 'result=FAILED the timer still follows %s\n' "$NAME"; exit 1; }
        # Until the current machine has a capture, the old directory is the only way back.
        set -- "$DIR/checkpoints/$current"-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z.smolcheckpoint
        [ -e "$1" ] || { printf 'result=FAILED %s has no capture yet; wait for its first, then drop\n' "$current"; exit 1; }
        until mkdir "$DIR/.lock" 2>/dev/null; do sleep 1; done
        printf '%s\n' "$$" > "$DIR/.lock/pid"
        trap 'rm -rf "${DIR:?}/.lock"' EXIT
        set -- "$DIR/checkpoints/$NAME"-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z.smolcheckpoint
        for d in "$@"; do
            [ -e "$d" ] && rm -rf -- "${d:?}" && printf 'deleted=%s\n' "$d"
        done
        "$SMOLVM" machine checkpoint-prune --store "$DIR/store" 2>&1 | sed 's/^/  /'
        printf 'result=dropped\n'
        ;;
    remove)
        case "$(uname -s)" in
            Darwin)
                launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1
                rm -f "${PLIST:?}"
                ;;
            Linux)
                systemctl --user disable --now "$LABEL.timer" >/dev/null 2>&1
                systemctl --user stop "$LABEL.service" >/dev/null 2>&1
                rm -f "${UNITS:?}/${LABEL:?}.timer" "${UNITS:?}/${LABEL:?}.service"
                systemctl --user daemon-reload >/dev/null 2>&1
                systemctl --user reset-failed >/dev/null 2>&1
                ;;
        esac
        printf 'label=%s\nresult=removed\n' "$LABEL"
        ;;
    *)
        printf 'usage: timer.sh install|retarget|drop|remove --dir <dir> [--name <machine>] [--every <s>] [--window <s>]\n' >&2
        exit 2
        ;;
esac
