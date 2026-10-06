#!/usr/bin/env bash
# Runtime wrapper for squish-anchor (self-contained package, no installation required).
#
# - Prepends this package's lib/ (bundled Qt 6.6.0 runtime) to LD_LIBRARY_PATH,
#   preserving any value that was already set.
# - If the host lacks libstdc++.so.6 or libgcc_s.so.1, also appends lib/fallback/
#   (copies taken from the RHEL 9 build environment). On a normal RHEL 9 host the
#   system copies are used and lib/fallback/ is ignored.
# - exec()s bin/squish-anchor so the logged PID is the PID of the real process
#   (the one Squish attaches to). All arguments are passed through.
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

# Core runtime libraries normally come from the RHEL 9 host. Use the bundled fallback
# copies only when the host does not provide them.
host_has_lib() {
    local name="$1" d
    for d in /lib64 /usr/lib64 /lib /usr/lib; do
        [ -e "$d/$name" ] && return 0
    done
    if [ -x /sbin/ldconfig ]; then
        /sbin/ldconfig -p 2>/dev/null | grep -q "^[[:space:]]*$name " && return 0
    fi
    return 1
}
if [ -d "$PKG_LIB/fallback" ]; then
    for name in libstdc++.so.6 libgcc_s.so.1; do
        if ! host_has_lib "$name"; then
            echo "run-squish-anchor.sh: host lacks $name, using $PKG_LIB/fallback" >&2
            export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$PKG_LIB/fallback"
            break
        fi
    done
fi

exec "$PKG_BIN" "$@"
