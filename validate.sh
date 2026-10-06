#!/usr/bin/env bash
# Self-check of the headlessQtApp package on the machine it runs on. Needs only bash and
# ldd (glibc); checks that need `file` or `readelf` are skipped when those are not installed.
#
#   ./validate.sh            # from inside the package directory
#   ./validate.sh --strict   # missing tools count as failures (build side)
set -uo pipefail
STRICT=0; [ "${1:-}" = "--strict" ] && { STRICT=1; shift; }
PKG="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
cd "$PKG" || exit 1
LIBDIR="$(cd libs/lib64 && pwd -P)"

pass=0; failc=0; skipped=0
ok()   { echo "  [PASS] $*"; pass=$((pass+1)); }
bad()  { echo "  [FAIL] $*"; failc=$((failc+1)); }
skip() { if [ $STRICT = 1 ]; then bad "$* (tool missing, --strict)"; else echo "  [SKIP] $*"; skipped=$((skipped+1)); fi; }
hdr()  { echo; echo "== $* =="; }
have() { command -v "$1" >/dev/null 2>&1; }
# The share may have dropped the executable bits: run the wrapper through bash (it exec()s
# the binary, so the PID is unchanged) and the binary through the dynamic loader.
run_pkg() { bash ./run-headlessQtApp.sh "$@"; }

hdr "layout"
for p in bin/headlessQtApp bin/qt.conf plugins/platforms/libqoffscreen.so libs/lib64/libQt6Core.so.6 libs/lib64/libQt6Gui.so.6 libs/lib64/libQt6Widgets.so.6 libs/lib64/fonts run-headlessQtApp.sh; do
    [ -e "$p" ] && ok "$p present" || bad "$p missing"
done
if find bin plugins libs xvfb -type l 2>/dev/null | grep -q .; then bad "symlinks present (would not survive an SMB share): $(find bin plugins libs xvfb -type l 2>/dev/null | tr '\n' ' ')"; else ok "no symlinks in bin/ plugins/ libs/ xvfb/"; fi

hdr "file bin/headlessQtApp"
if have file; then
    FILE_OUT="$(file bin/headlessQtApp)"; echo "$FILE_OUT"
    grep -q 'ELF 64-bit LSB' <<<"$FILE_OUT" && grep -q 'x86-64' <<<"$FILE_OUT" && ok "ELF 64-bit x86-64" || bad "not an ELF64 x86-64 executable"
    grep -q 'interpreter /lib64/ld-linux-x86-64.so.2' <<<"$FILE_OUT" && ok "interpreter /lib64/ld-linux-x86-64.so.2" || bad "unexpected interpreter"
else
    MAGIC="$(head -c 4 bin/headlessQtApp | od -An -c | tr -d ' \n')"; CLASS="$(od -An -tu1 -j4 -N1 bin/headlessQtApp | tr -d ' ')"; MACH="$(od -An -tu2 -j18 -N2 bin/headlessQtApp | tr -d ' ')"
    [ "$MAGIC" = '177ELF' ] && [ "$CLASS" = 2 ] && [ "$MACH" = 62 ] && ok "ELF 64-bit x86-64 (from the ELF header; file(1) not installed)" || bad "not ELF64 x86-64"
    skip "file(1) output"
fi

hdr "ldd (with libs/lib64 on the path)"
if have ldd; then
    export LD_LIBRARY_PATH="$LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    LDD_OUT="$(ldd bin/headlessQtApp 2>&1)"; echo "$LDD_OUT"
    grep -q 'not found' <<<"$LDD_OUT" && bad "unresolved libraries" || ok "all libraries of bin/headlessQtApp resolved"
    for n in libQt6Core.so.6 libQt6Gui.so.6 libQt6Widgets.so.6 libstdc++.so.6 libgcc_s.so.1; do
        p="$(awk -v n="$n" '$1==n && $2=="=>" {print $3; exit}' <<<"$LDD_OUT")"
        [ -n "$p" ] && [ "$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" = "$LIBDIR" ] && ok "$n from libs/lib64" || bad "$n not from libs/lib64 (got '$p')"
    done
    for n in libc.so.6 libm.so.6; do
        awk -v n="$n" '$1==n && $2=="=>" && $3 ~ /^\/(usr\/)?lib(64)?\// {f=1} END{exit !f}' <<<"$LDD_OUT" && ok "$n from the system (glibc)" || bad "$n not from the system"
    done
    grep -qE 'libX11|libxcb|libwayland|libGL|libEGL|libfontconfig' <<<"$LDD_OUT" && bad "display/system GUI libraries linked" || ok "no X11/Wayland/OpenGL/fontconfig dependency"
    allmissing=0
    for f in plugins/*/*.so libs/lib64/*.so*; do
        [ -f "$f" ] || continue
        if ldd "$f" 2>&1 | grep -q 'not found'; then bad "$f has unresolved dependencies: $(ldd "$f" | grep 'not found' | tr -s ' \n' ' ')"; allmissing=1; fi
    done
    [ $allmissing = 0 ] && ok "every plugin and library in the package resolves"
    unset LD_LIBRARY_PATH
else
    skip "ldd checks"
fi

hdr "readelf -d bin/headlessQtApp"
if have readelf; then
    DYN="$(readelf -d bin/headlessQtApp)"; echo "$DYN" | grep -E 'NEEDED|RUNPATH|RPATH'
    grep -qE '\((RUNPATH|RPATH)\).*\[\$ORIGIN/\.\./libs/lib64\]' <<<"$DYN" && ok "RUNPATH is \$ORIGIN/../libs/lib64" || bad "RUNPATH is not \$ORIGIN/../libs/lib64"
else
    grep -q -a '\$ORIGIN/\.\./libs/lib64' bin/headlessQtApp && ok "binary contains runtime path \$ORIGIN/../libs/lib64 (string check)" || bad "runtime path missing"
    skip "readelf -d output"
fi

hdr "readelf --version-info libs/lib64/libQt6Core.so.6 | grep Qt_6_PRIVATE_API"
if have readelf; then
    VI="$(readelf --version-info libs/lib64/libQt6Core.so.6 | grep Qt_6_PRIVATE_API)"; echo "$VI"
    [ -n "$VI" ] && ok "Qt_6_PRIVATE_API symbol version present" || bad "Qt_6_PRIVATE_API ABSENT"
else
    grep -q -a 'Qt_6_PRIVATE_API' libs/lib64/libQt6Core.so.6 && ok "Qt_6_PRIVATE_API present (string check)" || bad "Qt_6_PRIVATE_API not found"
    skip "readelf --version-info output"
fi
QTV="$(grep -a -o -m1 'Qt 6\.[0-9]*\.[0-9]* (x86_64' libs/lib64/libQt6Core.so.6 | sed 's/ (x86_64//')"
[ "$QTV" = "Qt 6.6.0" ] && ok "bundled Qt Core reports $QTV" || bad "bundled Qt Core reports '$QTV'"
for n in libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 ld-linux-x86-64.so.2; do
    [ -e "libs/lib64/$n" ] && bad "glibc component bundled: $n" ; done
ok "no glibc components in libs/lib64"

hdr "./run-headlessQtApp.sh --once"
OUT="$(run_pkg --once 2>&1)"; rc=$?; echo "$OUT"
[ $rc -eq 0 ] && ok "exit status 0" || bad "exit status $rc"
grep -qE 'started pid=[0-9]+' <<<"$OUT" && ok "startup line with PID" || bad "no startup line"
grep -q 'qt runtime=6.6.0' <<<"$OUT" && ok "runtime Qt 6.6.0" || bad "runtime Qt not 6.6.0"
grep -q "core-library=$LIBDIR/libQt6Core.so" <<<"$OUT" && ok "libQt6Core loaded from libs/lib64" || bad "libQt6Core loaded from elsewhere"
grep -q 'qpa platform=offscreen' <<<"$OUT" && ok "offscreen platform plugin loaded" || bad "offscreen platform not used"
grep -q "main window 'mainWindow' shown" <<<"$OUT" && ok "main window created" || bad "no main window"
grep -qi 'warning\|could not\|failed' <<<"$OUT" && bad "warnings in output" || ok "no warnings"

hdr "./run-headlessQtApp.sh --screenshot (offscreen rendering + fonts)"
shot="$(mktemp -u).png"
OUT="$(run_pkg --screenshot "$shot" 2>&1)"; rc=$?; echo "$OUT"
[ $rc -eq 0 ] && [ -s "$shot" ] && [ "$(head -c 8 "$shot" | od -An -c | tr -d ' \n')" = '211PNG\r\n032\n' ] && ok "PNG screenshot written ($(stat -c %s "$shot") bytes)" || bad "screenshot failed (exit $rc)"
rm -f "$shot"

hdr "./run-headlessQtApp.sh --desktop-screenshot (QScreen::grabWindow(0) on the offscreen screen, as Squish does)"
shot="$(mktemp -u).png"
OUT="$(run_pkg --desktop-screenshot "$shot" 2>&1)"; rc=$?; echo "$OUT"
[ $rc -eq 0 ] && [ -s "$shot" ] && ok "desktop screenshot via primary QScreen written ($(stat -c %s "$shot") bytes)" || bad "desktop screenshot failed (exit $rc)"
rm -f "$shot"

if [ -f xvfb/Xvfb ] && [ -f plugins/platforms/libqxcb.so ]; then
    hdr "./run-headlessQtApp.sh --xvfb --desktop-screenshot (bundled Xvfb + xcb platform)"
    shot="$(mktemp -u).png"
    OUT="$(run_pkg --xvfb --desktop-screenshot "$shot" 2>&1)"; rc=$?; echo "$OUT"
    grep -q 'qpa platform=xcb' <<<"$OUT" && ok "xcb platform on the bundled Xvfb" || bad "xcb platform not used"
    [ $rc -eq 0 ] && [ -s "$shot" ] && ok "desktop screenshot on Xvfb written ($(stat -c %s "$shot") bytes)" || bad "Xvfb desktop screenshot failed (exit $rc)"
    grep -qiE 'could not|failed to|error' <<<"$OUT" && bad "errors in --xvfb output" || ok "no errors in --xvfb output"
    rm -f "$shot"
    ls /tmp/.X11-unix/ 2>/dev/null | grep -q . && echo "(note: other X sockets present in /tmp/.X11-unix: $(ls /tmp/.X11-unix | tr '\n' ' '))"
    hdr "--xvfb: SIGTERM shutdown stops both the application and Xvfb"
    tmp="$(mktemp)"; bash ./run-headlessQtApp.sh --xvfb >"$tmp" 2>&1 & wpid=$!
    for _ in $(seq 1 100); do grep -q 'running event loop' "$tmp" 2>/dev/null && break; sleep 0.1; done
    xpid="$(sed -n 's/.*Xvfb pid=\([0-9]*\).*/\1/p' "$tmp" | head -n1)"
    sleep 0.3; kill -TERM "$wpid" 2>/dev/null
    rc=1; for _ in $(seq 1 100); do if ! kill -0 "$wpid" 2>/dev/null; then wait "$wpid"; rc=$?; break; fi; sleep 0.1; done
    sleep 0.5
    [ $rc -eq 0 ] && grep -q 'received SIGTERM' "$tmp" && ok "application exited 0 on SIGTERM" || { cat "$tmp"; bad "application exit $rc"; }
    if [ -n "$xpid" ] && kill -0 "$xpid" 2>/dev/null; then bad "Xvfb (pid $xpid) still running"; kill "$xpid"; else ok "Xvfb stopped"; fi
    rm -f "$tmp"
else
    echo; echo "== --xvfb mode not available (no xvfb/Xvfb or plugins/platforms/libqxcb.so) =="
fi

hdr "./run-headlessQtApp.sh --core-only --once"
OUT="$(run_pkg --core-only --once 2>&1)"; rc=$?; echo "$OUT"
[ $rc -eq 0 ] && grep -q 'mode=core-only' <<<"$OUT" && ok "core-only mode exit 0" || bad "core-only failed (exit $rc)"

hdr "bin/headlessQtApp --once without the wrapper (RUNPATH + qt.conf only)"
[ -x bin/headlessQtApp ] || echo "(bin/headlessQtApp has no executable bit here; started through /lib64/ld-linux-x86-64.so.2)"
OUT="$(env -u LD_LIBRARY_PATH -u QT_PLUGIN_PATH -u QT_QPA_PLATFORM -u QT_QPA_FONTDIR bash -c 'if [ -x bin/headlessQtApp ]; then ./bin/headlessQtApp --once; else LD_LIBRARY_PATH=$PWD/libs/lib64 QT_PLUGIN_PATH=$PWD/plugins QT_QPA_FONTDIR=$PWD/libs/lib64/fonts /lib64/ld-linux-x86-64.so.2 ./bin/headlessQtApp --once; fi' 2>&1)"; rc=$?; echo "$OUT"
[ $rc -eq 0 ] && grep -q 'qpa platform=offscreen' <<<"$OUT" && ok "runs directly (exit 0, offscreen)" || bad "direct run failed (exit $rc)"

hdr "start via the dynamic loader (no exec bit needed)"
OUT="$(LD_LIBRARY_PATH="$LIBDIR" QT_PLUGIN_PATH="$PWD/plugins" QT_QPA_FONTDIR="$LIBDIR/fonts" /lib64/ld-linux-x86-64.so.2 ./bin/headlessQtApp --once 2>&1)"; rc=$?
[ $rc -eq 0 ] && grep -q 'qpa platform=offscreen' <<<"$OUT" && ok "ld.so start works (exit 0)" || { echo "$OUT"; bad "ld.so start failed (exit $rc)"; }

hdr "SIGTERM / SIGINT shutdown"
for sig in TERM INT; do
    tmp="$(mktemp)"; bash ./run-headlessQtApp.sh >"$tmp" 2>&1 & wpid=$!
    for _ in $(seq 1 100); do grep -q 'running event loop' "$tmp" 2>/dev/null && break; sleep 0.1; done
    pid="$(sed -n 's/.*started pid=\([0-9]*\).*/\1/p' "$tmp" | head -n1)"
    [ "$pid" = "$wpid" ] && ok "logged PID $pid equals the process PID" || bad "logged PID '$pid' != $wpid"
    sleep 0.3; kill -s "$sig" "$wpid" 2>/dev/null
    rc=1; for _ in $(seq 1 100); do if ! kill -0 "$wpid" 2>/dev/null; then wait "$wpid"; rc=$?; break; fi; sleep 0.1; done
    [ $rc -eq 0 ] && grep -q "received SIG$sig" "$tmp" && ok "SIG$sig: clean shutdown, exit 0" || { cat "$tmp"; bad "SIG$sig: exit $rc"; }
    rm -f "$tmp"
done

hdr "environment"
echo "$(cat /etc/redhat-release 2>/dev/null || head -n1 /etc/os-release); glibc $(ldd --version 2>/dev/null | head -n1 | sed 's/.* //'); DISPLAY=${DISPLAY:-<unset>}"
echo; echo "validate: $pass passed, $failc failed, $skipped skipped"
[ $failc -eq 0 ]
