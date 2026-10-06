#!/usr/bin/env bash
# Validation of a squish-anchor runtime package. Shipped inside the package as
# validate.sh (run it from the package directory, no arguments) and used by
# package-runtime.sh on the build side (with --strict).
#
#   validate.sh [--strict] [package-dir]
#
# Runs and checks the required commands:
#   file bin/squish-anchor
#   ldd bin/squish-anchor
#   readelf -d bin/squish-anchor
#   readelf --version-info lib/libQt6Core.so.6 | grep Qt_6_PRIVATE_API
#   ./run-squish-anchor.sh --once
# plus: SIGTERM/SIGINT shutdown, no GUI/QPA linkage, no core RHEL libraries in lib/.
#
# Needs only bash and ldd (glibc). Checks that need `file` or `readelf` (binutils) are
# skipped with a warning when the tool is not installed; --strict turns that into a
# failure (used on the build side, where the tools exist).
set -uo pipefail

STRICT=0
if [ "${1:-}" = "--strict" ]; then STRICT=1; shift; fi
PKG="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
cd "$PKG" || exit 1

pass=0; failc=0; skipped=0
ok()   { echo "  [PASS] $*"; pass=$((pass+1)); }
bad()  { echo "  [FAIL] $*"; failc=$((failc+1)); }
skip() { if [ $STRICT = 1 ]; then bad "$* (tool missing, --strict)"; else echo "  [SKIP] $*"; skipped=$((skipped+1)); fi; }
hdr()  { echo; echo "== $* =="; }
have() { command -v "$1" >/dev/null 2>&1; }

LIBDIR="$(cd lib && pwd -P)"

hdr "file bin/squish-anchor"
if have file; then
    FILE_OUT="$(file bin/squish-anchor)"; echo "$FILE_OUT"
    grep -q 'ELF 64-bit LSB' <<<"$FILE_OUT" && grep -q 'x86-64' <<<"$FILE_OUT" && ok "ELF 64-bit x86-64" || bad "not an ELF64 x86-64 executable"
    grep -q 'dynamically linked' <<<"$FILE_OUT" && ok "dynamically linked" || bad "not dynamically linked"
    grep -q 'interpreter /lib64/ld-linux-x86-64.so.2' <<<"$FILE_OUT" && ok "interpreter /lib64/ld-linux-x86-64.so.2 (system loader, not bundled)" || bad "unexpected interpreter"
else
    # minimal fallback without file(1): ELF magic, class 2 (64-bit), machine 0x3E (x86-64)
    MAGIC="$(head -c 4 bin/squish-anchor | od -An -c | tr -d ' \n')"
    CLASS="$(od -An -tu1 -j4 -N1 bin/squish-anchor | tr -d ' ')"
    MACH="$(od -An -tu2 -j18 -N2 bin/squish-anchor | tr -d ' ')"
    [ "$MAGIC" = '177ELF' ] && [ "$CLASS" = 2 ] && [ "$MACH" = 62 ] && ok "ELF 64-bit x86-64 (checked from the ELF header; file(1) not installed)" || bad "not an ELF64 x86-64 file (magic=$MAGIC class=$CLASS machine=$MACH)"
    skip "file(1) output"
fi

hdr "ldd bin/squish-anchor"
if have ldd; then
    LDD_OUT="$(ldd bin/squish-anchor 2>&1)"; echo "$LDD_OUT"
    grep -q 'not found' <<<"$LDD_OUT" && bad "unresolved libraries" || ok "all libraries resolved"
    QTCORE_PATH="$(awk '$1=="libQt6Core.so.6" && $2=="=>" {print $3; exit}' <<<"$LDD_OUT")"
    [ -n "$QTCORE_PATH" ] && [ "$(cd "$(dirname "$QTCORE_PATH")" 2>/dev/null && pwd -P)" = "$LIBDIR" ] && ok "libQt6Core.so.6 resolved from the package lib/ via RUNPATH ($QTCORE_PATH)" || bad "libQt6Core.so.6 not resolved from package lib/ (got '$QTCORE_PATH')"
    grep -qE 'libQt6(Gui|Widgets|Qml|Quick|DBus|Network)\.so|libX11|libxcb|libwayland|libGL' <<<"$LDD_OUT" && bad "GUI/display libraries linked" || ok "no Gui/Widgets/Qml/Quick/X11/Wayland/OpenGL dependency"
    for sys in libc.so.6 libm.so.6 libstdc++.so.6 libgcc_s.so.1; do
        awk -v n="$sys" '$1==n && $2=="=>" && $3 ~ /^\/(usr\/)?lib(64)?\// {found=1} END {exit !found}' <<<"$LDD_OUT" && ok "$sys from the system" || bad "$sys not resolved from the system"
    done
    LDD_LIBS="$(LD_LIBRARY_PATH="$LIBDIR" ldd lib/libQt6Core.so.6 2>&1)"
    grep -q 'not found' <<<"$LDD_LIBS" && bad "libQt6Core.so.6 has unresolved dependencies" || ok "libQt6Core.so.6 dependencies resolve"
else
    skip "ldd checks"
fi

hdr "readelf -d bin/squish-anchor"
if have readelf; then
    DYN_OUT="$(readelf -d bin/squish-anchor)"; echo "$DYN_OUT"
    grep -qE '\((RUNPATH|RPATH)\).*\[\$ORIGIN/\.\./lib\]' <<<"$DYN_OUT" && ok "RUNPATH/RPATH is \$ORIGIN/../lib" || bad "RUNPATH/RPATH is not \$ORIGIN/../lib"
    grep -q 'NEEDED.*\[libQt6Core.so.6\]' <<<"$DYN_OUT" && ok "NEEDED libQt6Core.so.6" || bad "libQt6Core.so.6 not NEEDED"
else
    grep -q -a '\$ORIGIN/\.\./lib' bin/squish-anchor && ok "binary contains the runtime path \$ORIGIN/../lib (readelf not installed; string check)" || bad "\$ORIGIN/../lib not found in binary"
    skip "readelf -d output"
fi

hdr "readelf --version-info lib/libQt6Core.so.6 | grep Qt_6_PRIVATE_API"
if have readelf; then
    VI="$(readelf --version-info lib/libQt6Core.so.6 | grep Qt_6_PRIVATE_API)"; echo "$VI"
    [ -n "$VI" ] && ok "Qt_6_PRIVATE_API symbol version present" || bad "Qt_6_PRIVATE_API symbol version ABSENT"
    CORE_DYN="$(readelf -d lib/libQt6Core.so.6)"
    grep -q 'SONAME.*\[libQt6Core.so.6\]' <<<"$CORE_DYN" && ok "SONAME libQt6Core.so.6 preserved" || bad "SONAME not libQt6Core.so.6"
else
    grep -q -a 'Qt_6_PRIVATE_API' lib/libQt6Core.so.6 && ok "Qt_6_PRIVATE_API version string present in libQt6Core.so.6 (readelf not installed; string check)" || bad "Qt_6_PRIVATE_API not found in libQt6Core.so.6"
    skip "readelf --version-info output"
fi
[ -L lib/libQt6Core.so.6 ] && ok "lib/libQt6Core.so.6 is a SONAME symlink -> $(readlink lib/libQt6Core.so.6)" || { [ -f lib/libQt6Core.so.6 ] && ok "lib/libQt6Core.so.6 present" || bad "lib/libQt6Core.so.6 missing"; }
QTV="$(grep -a -o -m1 'Qt 6\.[0-9]*\.[0-9]* (x86_64' lib/libQt6Core.so.6 | head -n1 | sed 's/ (x86_64//')"
[ "$QTV" = "Qt 6.6.0" ] && ok "bundled Qt Core reports $QTV" || bad "bundled Qt Core reports '$QTV', expected 'Qt 6.6.0'"

hdr "lib/ contents"
ls -l lib
for f in lib/*; do
    [ -d "$f" ] && continue
    n="$(basename "$f")"
    case "$n" in
        libc.so*|libm.so*|libpthread.so*|libdl.so*|librt.so*|libstdc++.so*|libgcc_s.so*|ld-linux*|libz.so*|libglib-2.0.so*)
            bad "core RHEL library bundled in lib/: $n";;
    esac
done
ok "no core RHEL libraries (glibc, loader, libstdc++, libgcc_s, zlib, glib) in lib/ itself"
if [ -d lib/fallback ]; then
    ls -l lib/fallback
    ok "lib/fallback/ present (used by the wrapper only if the host lacks libstdc++/libgcc_s)"
fi

hdr "./run-squish-anchor.sh --once"
ONCE_OUT="$(./run-squish-anchor.sh --once 2>&1)"; rc=$?
echo "$ONCE_OUT"
[ $rc -eq 0 ] && ok "exit status 0" || bad "exit status $rc"
grep -qE 'started pid=[0-9]+' <<<"$ONCE_OUT" && ok "startup line with PID logged" || bad "no startup/PID line"
grep -q 'qt runtime=6.6.0' <<<"$ONCE_OUT" && ok "runtime Qt 6.6.0" || bad "runtime Qt is not 6.6.0"
grep -q "core-library=$LIBDIR/libQt6Core.so" <<<"$ONCE_OUT" && ok "loaded libQt6Core from package lib/" || bad "libQt6Core loaded from elsewhere"
grep -q 'warning: runtime Qt' <<<"$ONCE_OUT" && bad "runtime/build-time Qt mismatch warning" || ok "no Qt version mismatch warning"

hdr "bin/squish-anchor --once without the wrapper (RUNPATH only, no LD_LIBRARY_PATH)"
DIRECT_OUT="$(env -u LD_LIBRARY_PATH ./bin/squish-anchor --once 2>&1)"; rc=$?
echo "$DIRECT_OUT"
[ $rc -eq 0 ] && grep -q "core-library=$LIBDIR/libQt6Core.so" <<<"$DIRECT_OUT" && ok "runs directly via RUNPATH (exit 0, Qt from lib/)" || bad "direct run failed (exit $rc)"

hdr "SIGTERM / SIGINT shutdown"
for sig in TERM INT; do
    tmp="$(mktemp)"
    ./run-squish-anchor.sh >"$tmp" 2>&1 &
    wpid=$!
    for _ in $(seq 1 50); do grep -q 'running event loop' "$tmp" 2>/dev/null && break; sleep 0.1; done
    pid="$(sed -n 's/.*started pid=\([0-9]*\).*/\1/p' "$tmp" | head -n1)"
    if [ "$pid" = "$wpid" ]; then ok "logged PID $pid equals the process PID (wrapper exec()s the binary)"; else bad "logged PID '$pid' != process PID $wpid"; fi
    sleep 0.3
    kill -s "$sig" "$wpid" 2>/dev/null
    rc=1; for _ in $(seq 1 50); do if ! kill -0 "$wpid" 2>/dev/null; then wait "$wpid"; rc=$?; break; fi; sleep 0.1; done
    cat "$tmp"
    [ $rc -eq 0 ] && grep -q "received SIG$sig" "$tmp" && ok "SIG$sig: clean shutdown, exit status 0" || bad "SIG$sig: exit status $rc"
    rm -f "$tmp"
done

hdr "environment"
echo "$(cat /etc/redhat-release 2>/dev/null || head -n1 /etc/os-release); glibc $(ldd --version 2>/dev/null | head -n1 | sed 's/.* //'); DISPLAY=${DISPLAY:-<unset>} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>}"

echo
echo "validate: $pass passed, $failc failed, $skipped skipped"
[ $failc -eq 0 ]
