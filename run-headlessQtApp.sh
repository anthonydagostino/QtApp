#!/usr/bin/env bash
# Runtime wrapper for headlessQtApp. Nothing needs to be installed on the machine that runs
# it: every library besides glibc is in libs/lib64, the Qt platform plugin is in plugins/.
#
# Use this script as the AUT for Squish:
#   <squish>/bin/startaut --port=4322 /path/to/headlessQtApp/run-headlessQtApp.sh
#
# What it does:
#   - prepends libs/lib64 to LD_LIBRARY_PATH (existing value preserved)
#   - points Qt at plugins/ (QT_PLUGIN_PATH) and libs/lib64/fonts (QT_QPA_FONTDIR)
#   - selects the offscreen platform unless QT_QPA_PLATFORM is already set
#   - exec()s bin/headlessQtApp, so the PID it logs is the PID of the real process;
#     if the share stripped the executable bit, the binary is started through the
#     system dynamic loader instead (no exec bit needed).
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

for p in "$PKG_BIN" "$PKG_LIB/libQt6Core.so.6" "$PKG_PLUGINS/platforms/libqoffscreen.so"; do
    if [ ! -e "$p" ]; then
        echo "run-headlessQtApp.sh: missing: $p" >&2
        exit 127
    fi
done

export LD_LIBRARY_PATH="$PKG_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export QT_PLUGIN_PATH="$PKG_PLUGINS${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}"
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"
export QT_QPA_FONTDIR="${QT_QPA_FONTDIR:-$PKG_LIB/fonts}"
# Qt wants a UTF-8 locale; glibc's built-in C.UTF-8 needs no locale package.
if [ -z "${LC_ALL:-}" ] && [ -z "${LANG:-}" ]; then
    export LANG=C.UTF-8
fi

if [ -x "$PKG_BIN" ]; then
    exec "$PKG_BIN" "$@"
fi
echo "run-headlessQtApp.sh: $PKG_BIN is not executable (file share without exec bits?); starting it via the dynamic loader" >&2
exec /lib64/ld-linux-x86-64.so.2 "$PKG_BIN" "$@"
