#!/usr/bin/env bash
# Automated validation of an assembled runtime package directory.
#
#   validate-package.sh <package-dir>      e.g. out/squish-anchor-rhel9-x86_64
#
# Runs and checks the required commands:
#   file bin/squish-anchor
#   ldd bin/squish-anchor
#   readelf -d bin/squish-anchor
#   readelf --version-info lib/libQt6Core.so.6 | grep Qt_6_PRIVATE_API
#   ./run-squish-anchor.sh --once
# plus: SIGTERM/SIGINT shutdown, no GUI/QPA linkage, no core RHEL libraries in lib/.
set -uo pipefail

PKG="${1:?usage: $0 <package-dir>}"
cd "$PKG" || exit 1

pass=0; failc=0
ok()   { echo "  [PASS] $*"; pass=$((pass+1)); }
bad()  { echo "  [FAIL] $*"; failc=$((failc+1)); }
hdr()  { echo; echo "== $* =="; }

hdr "file bin/squish-anchor"
FILE_OUT="$(file bin/squish-anchor)"; echo "$FILE_OUT"
grep -q 'ELF 64-bit LSB' <<<"$FILE_OUT" && grep -q 'x86-64' <<<"$FILE_OUT" && ok "ELF 64-bit x86-64" || bad "not an ELF64 x86-64 executable"
grep -q 'dynamically linked' <<<"$FILE_OUT" && ok "dynamically linked" || bad "not dynamically linked"
grep -qE 'pie executable|executable' <<<"$FILE_OUT" && ok "executable" || bad "not an executable"
grep -q 'interpreter /lib64/ld-linux-x86-64.so.2' <<<"$FILE_OUT" && ok "interpreter /lib64/ld-linux-x86-64.so.2 (system loader, not bundled)" || bad "unexpected interpreter"

hdr "ldd bin/squish-anchor"
LDD_OUT="$(ldd bin/squish-anchor)"; echo "$LDD_OUT"
grep -q 'not found' <<<"$LDD_OUT" && bad "unresolved libraries" || ok "all libraries resolved"
grep -E 'libQt6Core\.so\.6 => .*/lib/libQt6Core\.so\.6' <<<"$LDD_OUT" | grep -q "$(cd lib && pwd -P)" && ok "libQt6Core.so.6 resolved from the package lib/ via RUNPATH" || bad "libQt6Core.so.6 not resolved from package lib/"
grep -qE 'libQt6(Gui|Widgets|Qml|Quick|DBus|Network)\.so|libX11|libxcb|libwayland|libGL' <<<"$LDD_OUT" && bad "GUI/display libraries linked" || ok "no Gui/Widgets/Qml/Quick/X11/Wayland/OpenGL dependency"
for sys in libc.so.6 libm.so.6 libstdc++.so.6 libgcc_s.so.1; do
    grep -E "^\s*$sys => /(usr/)?lib64/" <<<"$LDD_OUT" >/dev/null && ok "$sys from the system" || bad "$sys not resolved from the system"
done

hdr "readelf -d bin/squish-anchor"
DYN_OUT="$(readelf -d bin/squish-anchor)"; echo "$DYN_OUT"
grep -qE '\((RUNPATH|RPATH)\).*\[\$ORIGIN/\.\./lib\]' <<<"$DYN_OUT" && ok "RUNPATH/RPATH is \$ORIGIN/../lib" || bad "RUNPATH/RPATH is not \$ORIGIN/../lib"
grep -q 'NEEDED.*\[libQt6Core.so.6\]' <<<"$DYN_OUT" && ok "NEEDED libQt6Core.so.6" || bad "libQt6Core.so.6 not NEEDED"

hdr "readelf --version-info lib/libQt6Core.so.6 | grep Qt_6_PRIVATE_API"
VI="$(readelf --version-info lib/libQt6Core.so.6 | grep Qt_6_PRIVATE_API)"; echo "$VI"
[ -n "$VI" ] && ok "Qt_6_PRIVATE_API symbol version present" || bad "Qt_6_PRIVATE_API symbol version ABSENT"
[ -L lib/libQt6Core.so.6 ] && ok "lib/libQt6Core.so.6 is a SONAME symlink -> $(readlink lib/libQt6Core.so.6)" || { [ -f lib/libQt6Core.so.6 ] && ok "lib/libQt6Core.so.6 present"; }
readelf -d lib/libQt6Core.so.6 | grep -q 'SONAME.*\[libQt6Core.so.6\]' && ok "SONAME libQt6Core.so.6 preserved" || bad "SONAME not libQt6Core.so.6"
QTV="$(strings -a lib/libQt6Core.so.6 | grep -m1 -oE '^Qt [0-9]+\.[0-9]+\.[0-9]+')"
[ "$QTV" = "Qt 6.6.0" ] && ok "bundled Qt Core reports $QTV" || bad "bundled Qt Core reports '$QTV', expected 'Qt 6.6.0'"

hdr "lib/ contents"
ls -l lib
for f in lib/*; do
    n="$(basename "$f")"
    case "$n" in
        libc.so*|libm.so*|libpthread.so*|libdl.so*|librt.so*|libstdc++.so*|libgcc_s.so*|ld-linux*|libz.so*|libglib-2.0.so*)
            bad "core RHEL library bundled: $n";;
    esac
done
ok "no core RHEL libraries (glibc, loader, libstdc++, libgcc_s, zlib, glib) in lib/"
LDD_LIBS="$(LD_LIBRARY_PATH="$(pwd)/lib" ldd lib/libQt6Core.so.6)"
grep -q 'not found' <<<"$LDD_LIBS" && bad "libQt6Core.so.6 has unresolved dependencies" || ok "libQt6Core.so.6 dependencies resolve"

hdr "./run-squish-anchor.sh --once"
ONCE_OUT="$(./run-squish-anchor.sh --once 2>&1)"; rc=$?
echo "$ONCE_OUT"
[ $rc -eq 0 ] && ok "exit status 0" || bad "exit status $rc"
grep -qE 'started pid=[0-9]+' <<<"$ONCE_OUT" && ok "startup line with PID logged" || bad "no startup/PID line"
grep -q 'qt runtime=6.6.0' <<<"$ONCE_OUT" && ok "runtime Qt 6.6.0" || bad "runtime Qt is not 6.6.0"
grep -q "core-library=$(cd lib && pwd -P)/libQt6Core.so" <<<"$ONCE_OUT" && ok "loaded libQt6Core from package lib/" || bad "libQt6Core loaded from elsewhere"
grep -q 'warning: runtime Qt' <<<"$ONCE_OUT" && bad "runtime/build-time Qt mismatch warning" || ok "no Qt version mismatch warning"

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
echo "$(cat /etc/redhat-release 2>/dev/null || cat /etc/os-release | head -n1); glibc $(ldd --version | head -n1 | sed 's/.* //'); DISPLAY=${DISPLAY:-<unset>} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>}"

echo
echo "validate-package: $pass passed, $failc failed"
[ $failc -eq 0 ]
