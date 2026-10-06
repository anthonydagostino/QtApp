#!/usr/bin/env bash
# Runtime wrapper for headlessQtApp. Nothing needs to be installed on the machine that runs
# it: every library besides glibc is in libs/lib64, the Qt platform plugins are in plugins/,
# a virtual X server (Xvfb) is in xvfb/.
#
# Use this script as the AUT for Squish:
#   <squish>/bin/startaut --port=4322 /path/to/headlessQtApp/run-headlessQtApp.sh          # offscreen
#   <squish>/bin/startaut --port=4322 /path/to/headlessQtApp/run-headlessQtApp.sh --xvfb   # Xvfb + xcb
#
# Modes:
#   default   Qt "offscreen" platform: no X server at all. Squish can inspect and interact
#             with the widgets; desktop screenshots depend on Squish accepting the
#             offscreen QScreen.
#   --xvfb    starts the bundled Xvfb on a free display and runs the application on the
#             "xcb" platform against it: a real X display, which is what Squish's desktop
#             screenshots on Linux normally use. Xvfb is stopped when the application exits.
#
# What it does in both modes:
#   - prepends libs/lib64 to LD_LIBRARY_PATH (existing value preserved)
#   - points Qt at plugins/ (QT_PLUGIN_PATH) and libs/lib64/fonts (QT_QPA_FONTDIR)
#   - starts bin/headlessQtApp; if the share stripped the executable bit, through the
#     system dynamic loader instead (no exec bit needed)
set -euo pipefail

resolve_self() {
    local src="${BASH_SOURCE[0]}"
    while [ -L "$src" ]; do
        local dir
        dir="$(cd -P "$(dirname "$src")" && pwd)"
        src="$(readlink "$src")"
        [[ "$src" != /* ]] && src="$dir/$src"
    done
    cd -P "$(dirname "$src")" && pwd
}

PKG_DIR="$(resolve_self)"
PKG_LIB="$PKG_DIR/libs/lib64"
PKG_BIN="$PKG_DIR/bin/headlessQtApp"
PKG_PLUGINS="$PKG_DIR/plugins"
PKG_XVFB="$PKG_DIR/xvfb"
LOADER=/lib64/ld-linux-x86-64.so.2

USE_XVFB=0
if [ "${1:-}" = "--xvfb" ]; then USE_XVFB=1; shift; fi

for p in "$PKG_BIN" "$PKG_LIB/libQt6Core.so.6" "$PKG_PLUGINS/platforms/libqoffscreen.so"; do
    [ -e "$p" ] || { echo "run-headlessQtApp.sh: missing: $p" >&2; exit 127; }
done

export LD_LIBRARY_PATH="$PKG_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export QT_PLUGIN_PATH="$PKG_PLUGINS${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}"
export QT_QPA_FONTDIR="${QT_QPA_FONTDIR:-$PKG_LIB/fonts}"
# Qt wants a UTF-8 locale; glibc's built-in C.UTF-8 needs no locale package.
if [ -z "${LC_ALL:-}" ] && [ -z "${LANG:-}" ]; then
    export LANG=C.UTF-8
fi

# Run a program from the package even if the file share dropped its executable bit.
run_prog() {
    local prog="$1"; shift
    if [ -x "$prog" ]; then "$prog" "$@"; else "$LOADER" "$prog" "$@"; fi
}
exec_prog() {
    local prog="$1"; shift
    if [ -x "$prog" ]; then exec "$prog" "$@"; else exec "$LOADER" "$prog" "$@"; fi
}

if [ $USE_XVFB = 0 ]; then
    export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"
    exec_prog "$PKG_BIN" "$@"
fi

# --- --xvfb: bundled virtual X server + xcb platform ------------------------------------------
for p in "$PKG_XVFB/Xvfb" "$PKG_PLUGINS/platforms/libqxcb.so"; do
    [ -e "$p" ] || { echo "run-headlessQtApp.sh: --xvfb needs $p" >&2; exit 127; }
done
export XKB_CONFIG_ROOT="$PKG_XVFB/xkb"            # libxkbcommon (Qt xcb plugin)
export QT_XKB_CONFIG_ROOT="$PKG_XVFB/xkb"
export XKB_BINDIR="$PKG_XVFB"                      # xkbcomp for the X server

# Pick a free display number.
disp=""
for n in $(seq 99 199); do
    if [ ! -e "/tmp/.X11-unix/X$n" ] && [ ! -e "/tmp/.X$n-lock" ]; then disp=$n; break; fi
done
[ -n "$disp" ] || { echo "run-headlessQtApp.sh: no free X display number between :99 and :199" >&2; exit 1; }

XVFB_LOG="${TMPDIR:-/tmp}/headlessQtApp-xvfb-$$-$disp.log"
run_prog "$PKG_XVFB/Xvfb" ":$disp" -screen 0 "${XVFB_SCREEN:-1280x1024x24}" -nolisten tcp -noreset \
    -xkbdir "$PKG_XVFB/xkb" -fp built-ins >"$XVFB_LOG" 2>&1 &
XVFB_PID=$!
cleanup() {
    kill "$XVFB_PID" 2>/dev/null || true
    rm -f "/tmp/.X$disp-lock" 2>/dev/null || true
}
trap cleanup EXIT
for _ in $(seq 1 100); do
    [ -e "/tmp/.X11-unix/X$disp" ] && break
    kill -0 "$XVFB_PID" 2>/dev/null || { echo "run-headlessQtApp.sh: Xvfb failed to start; log:" >&2; cat "$XVFB_LOG" >&2; exit 1; }
    sleep 0.1
done
[ -e "/tmp/.X11-unix/X$disp" ] || { echo "run-headlessQtApp.sh: Xvfb did not come up on :$disp; log:" >&2; cat "$XVFB_LOG" >&2; exit 1; }
echo "run-headlessQtApp.sh: Xvfb pid=$XVFB_PID on DISPLAY=:$disp (log: $XVFB_LOG)" >&2

export DISPLAY=":$disp"
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM_XVFB:-xcb}"

# Run the application in the foreground (not exec'd, Xvfb must be cleaned up afterwards).
# Signals sent to this script are forwarded to the application.
run_prog "$PKG_BIN" "$@" &
APP_PID=$!
forward() { kill -s "$1" "$APP_PID" 2>/dev/null || true; }
trap 'forward TERM' TERM
trap 'forward INT' INT
rc=0
wait "$APP_PID" || rc=$?
# a second wait collects the status if the first one was interrupted by a trapped signal
wait "$APP_PID" 2>/dev/null || rc=$?
exit $rc
