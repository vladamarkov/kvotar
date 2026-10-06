#!/bin/bash
# Builds Kvotar and launches that build. Usage: scripts/run.sh (or `make run`)
#
# - A Debug build for this Mac's architecture, unsigned like `make build`. Build output goes to
#   $KVOTAR_BUILD_DIR (default ${TMPDIR:-/tmp}/kvotar-build), never into the source tree; the
#   generated Kvotar.xcodeproj (gitignored) is the one exception.
# - Only after the build succeeds is a running Kvotar asked to quit. A failed build leaves the
#   running copy alone.
# - The new build is opened by its exact path, and the run fails unless the running process is
#   that file, so a stale copy is never the one on screen.
# - /Applications/Kvotar.app is never copied over, moved or deleted.
# - The build has the installed app's bundle identifier, so it uses the same sign-ins, database
#   and settings (CONTRIBUTING.md, "Running a development build").
# - KVOTAR_MENU_BAR_FIXTURE and KVOTAR_NOTIFICATION_FIXTURE, when set, are passed to the app.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp="${TMPDIR:-/tmp}"
BUILD="${KVOTAR_BUILD_DIR:-${tmp%/}/kvotar-build}"
BUNDLE_ID="com.vladimirmarkovic.kvotar"

xcodegen generate
xcodebuild build -project Kvotar.xcodeproj -scheme Kvotar -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$BUILD/xcode" \
    ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO -quiet

APP="$BUILD/xcode/Build/Products/Debug/Kvotar.app"
BINARY="$APP/Contents/MacOS/Kvotar"
[ -x "$BINARY" ] || { echo "The build succeeded but $BINARY is missing." >&2; exit 1; }

# The process ID of the running Kvotar, or nothing.
running_pid() {
    lsappinfo info -only pid -app "$BUNDLE_ID" | sed -n 's/^"pid"=//p'
}

# Up to 10 seconds for the running copy to go ($1 = gone) or for one to appear ($1 = up).
wait_until() {
    local n
    for n in $(seq 50); do
        if [ -n "$(running_pid)" ]; then
            [ "$1" = up ] && return 0
        else
            [ "$1" = gone ] && return 0
        fi
        sleep 0.2
    done
    return 1
}

if [ -n "$(running_pid)" ]; then
    echo "Quitting the running Kvotar..."
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" > /dev/null || true
    wait_until gone || {
        echo "Kvotar is still running. Quit it yourself, then run this again." >&2
        exit 1
    }
fi

launch=(open)
for v in KVOTAR_MENU_BAR_FIXTURE KVOTAR_NOTIFICATION_FIXTURE; do
    if [ -n "${!v:-}" ]; then launch+=(--env "$v=${!v}"); fi
done
"${launch[@]}" "$APP"

wait_until up || { echo "Kvotar did not start: $APP" >&2; exit 1; }
PID="$(running_pid)"
RUNNING="$(ps -o comm= -p "$PID" || true)"
# Compared as physical paths: the default build folder is behind a symlink (/var is /private/var).
if [ -z "$RUNNING" ] || [ "$(realpath "$RUNNING")" != "$(realpath "$BINARY")" ]; then
    echo "The running Kvotar is not this build." >&2
    echo "  running: $RUNNING" >&2
    echo "  built:   $BINARY" >&2
    exit 1
fi

echo "Running (unsigned Debug build, pid $PID): $APP"
echo "To go back to the installed release: quit this build (Quit Kvotar in its menu), then open Kvotar from Applications."
