#!/usr/bin/env bash
# Report every shared library that would be missing when headlessQtApp, its bundled Qt
# and (optionally) a Squish for Qt installation run on THIS machine with the package's
# libs/lib64 on the library path. Needs only bash and ldd (part of glibc).
#
#   ./check-deps.sh                    # package only
#   ./check-deps.sh /path/to/squish    # package + Squish's bin/ and lib/
set -uo pipefail
PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$PKG_DIR/libs/lib64"
export LD_LIBRARY_PATH="$LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

missing=0
check() {
    local f="$1" out
    out="$(ldd "$f" 2>&1)" || { echo "[skip] $f ($(head -n1 <<<"$out"))"; return; }
    if grep -q 'not found' <<<"$out"; then
        echo "[MISSING] $f"
        grep 'not found' <<<"$out" | sed 's/^/           /'
        missing=$((missing+1))
    else
        echo "[ok] $f"
    fi
}
is_elf() { [ "$(head -c 4 "$1" 2>/dev/null | od -An -c | tr -d ' \n')" = '177ELF' ]; }

echo "== package: $PKG_DIR"
check "$PKG_DIR/bin/headlessQtApp"
for f in "$PKG_DIR"/plugins/*/*.so "$LIB"/*.so*; do [ -f "$f" ] && check "$f"; done

if [ -n "${1:-}" ]; then
    SQ="$1"
    echo "== squish: $SQ"
    [ -d "$SQ" ] || { echo "not a directory: $SQ"; exit 2; }
    for f in "$SQ"/bin/* "$SQ"/lib/*.so* "$SQ"/lib/*/*.so*; do
        [ -f "$f" ] && is_elf "$f" && check "$f"
    done
fi
echo
echo "glibc on this machine: $(ldd --version 2>/dev/null | head -n1)"
if [ $missing -eq 0 ]; then echo "check-deps: nothing missing"; else echo "check-deps: $missing file(s) with missing libraries"; fi
[ $missing -eq 0 ]
