#!/usr/bin/env bash
# Runtime wrapper for squish-anchor.
#
# Prepends this package's lib/ directory (bundled Qt 6.6.0 runtime) to
# LD_LIBRARY_PATH, preserving any value that was already set, and then
# exec()s bin/squish-anchor so the logged PID is the PID of the real process
# (the one Squish attaches to). All arguments are passed through.
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
PKG_LIB="$PKG_DIR/lib"
PKG_BIN="$PKG_DIR/bin/squish-anchor"

if [ ! -x "$PKG_BIN" ]; then
    echo "run-squish-anchor.sh: missing executable: $PKG_BIN" >&2
    exit 127
fi
if [ ! -d "$PKG_LIB" ]; then
    echo "run-squish-anchor.sh: missing library directory: $PKG_LIB" >&2
    exit 127
fi

if [ -n "${LD_LIBRARY_PATH:-}" ]; then
    export LD_LIBRARY_PATH="$PKG_LIB:$LD_LIBRARY_PATH"
else
    export LD_LIBRARY_PATH="$PKG_LIB"
fi

exec "$PKG_BIN" "$@"
