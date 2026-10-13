#!/usr/bin/env bash
# build.sh - build HeadlessQtApp on RHEL 9 (tested on 9.8) and lay out the deployable tree
# (bin/, plugins/, libs/lib64/) exactly like the "claude/new-session-6jr4li" branch ships it.
#
# Needs only the RHEL toolchain packages:   sudo dnf install gcc-c++ cmake make binutils
# (on an unregistered system with ISO-based repos:  sudo dnf --disablerepo=Local-CRB install ...)
# Without a compiler it falls back to support/prebuilt/HeadlessQtApp, built from the same
# main.cpp, and only lays out the tree; without binutils the strip/readelf checks are skipped.
# Everything else is in this repository:
#   qt/6.8.0/gcc_64/          Qt 6.8.0 SDK (headers, libraries, CMake files, moc/rcc/uic)
#   support/runtime-libs/     the non-Qt libraries that go into libs/lib64 (ICU, glib2, X11/xcb, ...)
#   support/patchelf          patchelf binary (not in the RHEL repositories)
#   support/qt.conf           copied next to the binary
#
# Usage:  ./build.sh            (outputs bin/ plugins/ libs/lib64/ in this directory)
#         ./build.sh clean      (removes build outputs)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
QT_ROOT="$ROOT/qt/6.8.0/gcc_64"
QT_VERSION="6.8.0"
PATCHELF="$ROOT/support/patchelf"
LIB="libs/lib64"
GLIBC_MAX="2.34"            # RHEL 9.0 GA baseline: the tree must run on every RHEL 9.x

log()  { echo "[build] $*"; }
fail() { echo "[build] ERROR: $*" >&2; exit 1; }

if [ "${1:-}" = "clean" ]; then rm -rf build dist bin plugins libs; log "cleaned"; exit 0; fi

# --- prerequisites -------------------------------------------------------------------------
COMPILE=1
for t in cmake g++ make; do command -v "$t" >/dev/null 2>&1 || COMPILE=0; done
HAVE_BINUTILS=1
for t in readelf strip; do command -v "$t" >/dev/null 2>&1 || HAVE_BINUTILS=0; done
command -v ldd >/dev/null 2>&1 || fail "ldd (glibc) not found"
[ -x "$PATCHELF" ] || chmod +x "$PATCHELF" 2>/dev/null || true
"$PATCHELF" --version >/dev/null 2>&1 || fail "$PATCHELF does not run"
[ -e "$QT_ROOT/lib/libQt6Core.so.$QT_VERSION" ] || fail "Qt SDK missing: $QT_ROOT/lib/libQt6Core.so.$QT_VERSION"
if [ $COMPILE = 1 ]; then
    log "toolchain: $(g++ --version | head -n1); $(cmake --version | head -n1); $(cat /etc/redhat-release 2>/dev/null || true)"
else
    [ -x support/prebuilt/HeadlessQtApp ] || chmod +x support/prebuilt/HeadlessQtApp 2>/dev/null || true
    [ -f support/prebuilt/HeadlessQtApp ] || fail "no compiler (cmake/g++/make) and no support/prebuilt/HeadlessQtApp -> sudo dnf install gcc-c++ cmake make binutils"
    log "WARNING: cmake/g++/make not found -> using the prebuilt binary support/prebuilt/HeadlessQtApp (built from this main.cpp); install gcc-c++ cmake make to compile it yourself"
fi
[ $HAVE_BINUTILS = 1 ] || log "WARNING: binutils (readelf/strip) not found -> binaries are not stripped and the symbol-version checks are skipped"


# --- verify the Qt SDK (exact version, Qt_6_PRIVATE_API and Qt_6.8 symbol versions) --------
CORE="$QT_ROOT/lib/libQt6Core.so.$QT_VERSION"   # the SDK has no symlinks (checks out on any filesystem)
if [ $HAVE_BINUTILS = 1 ]; then
    VI="$(readelf --version-info "$CORE")"
    grep -q 'Qt_6_PRIVATE_API' <<<"$VI" || fail "Qt_6_PRIVATE_API absent from $CORE (incompatible with the Squish Qt wrapper)"
    grep -q 'Name: Qt_6.8$' <<<"$VI" || fail "Qt_6.8 symbol version absent from $CORE"
else
    grep -q -a 'Qt_6_PRIVATE_API' "$CORE" && grep -q -a 'Qt_6.8' "$CORE" || fail "Qt_6_PRIVATE_API / Qt_6.8 not found in $CORE"
fi
SDK_VERSION="$(cat "$QT_ROOT"/lib/cmake/Qt6/Qt6ConfigVersionImpl.cmake "$QT_ROOT"/lib/cmake/Qt6/Qt6ConfigVersion.cmake 2>/dev/null | sed -n 's/^set(PACKAGE_VERSION "\([0-9.]*\)")/\1/p' | sed -n '1p')"
[ -n "$SDK_VERSION" ] || SDK_VERSION="$(grep -a -o -m1 'Qt [0-9]*\.[0-9]*\.[0-9]* (x86_64' "$CORE" | sed 's/^Qt //; s/ (x86_64//')"
[ "$SDK_VERSION" = "$QT_VERSION" ] || fail "SDK is Qt $SDK_VERSION, need exactly $QT_VERSION"
log "Qt SDK: $SDK_VERSION, Qt_6_PRIVATE_API and Qt_6.8 present"

# --- build the application ------------------------------------------------------------------
rm -rf build dist
if [ $COMPILE = 1 ]; then
    GEN="Unix Makefiles"; command -v ninja >/dev/null 2>&1 && GEN=Ninja
    cmake -S . -B build -G "$GEN" -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_PREFIX_PATH="$QT_ROOT" -DCMAKE_INSTALL_PREFIX="$ROOT/dist" >/dev/null
    cmake --build build --parallel "$(nproc)"
    cmake --install build >/dev/null
    [ -x dist/bin/HeadlessQtApp ] || fail "dist/bin/HeadlessQtApp was not produced"
    log "built dist/bin/HeadlessQtApp"
else
    mkdir -p dist/bin && install -m 0755 support/prebuilt/HeadlessQtApp dist/bin/HeadlessQtApp
    log "using prebuilt dist/bin/HeadlessQtApp"
fi

# --- lay out the tree --------------------------------------------------------------------------
rm -rf bin plugins libs
mkdir -p bin plugins/platforms plugins/imageformats "$LIB"
install -m 0755 dist/bin/HeadlessQtApp bin/HeadlessQtApp
for n in 2 3 4 5 6; do install -m 0755 dist/bin/HeadlessQtApp "bin/HeadlessQtApp$n"; done
install -m 0644 support/qt.conf bin/qt.conf

for f in "$QT_ROOT"/plugins/platforms/libqxcb.so "$QT_ROOT"/plugins/platforms/libqoffscreen.so "$QT_ROOT"/plugins/platforms/libqminimal.so; do
    [ -f "$f" ] || fail "missing plugin $f"; install -m 0755 "$f" plugins/platforms/
done
for f in "$QT_ROOT"/plugins/imageformats/*.so; do [ -f "$f" ] && install -m 0755 "$f" plugins/imageformats/; done

# Qt libraries: real files named by SONAME (no symlinks, survives SMB shares)
for real in "$QT_ROOT"/lib/libQt6*.so."$QT_VERSION"; do
    soname="$("$PATCHELF" --print-soname "$real" 2>/dev/null || basename "$real" ".$QT_VERSION")"
    install -m 0755 "$real" "$LIB/$soname"
done
# non-Qt runtime libraries (ICU, glib2, pcre, zstd, X11/xcb/xkbcommon, libstdc++, libgcc_s 9.0 GA)
for f in support/runtime-libs/lib64/*; do install -m 0755 "$f" "$LIB/$(basename "$f")"; done

# RPATH (DT_RPATH, inherited by everything loaded into the process, Squish's wrapper included)
"$PATCHELF" --force-rpath --set-rpath '$ORIGIN/../libs/lib64' bin/HeadlessQtApp*
for f in plugins/*/*.so; do "$PATCHELF" --force-rpath --set-rpath '$ORIGIN/../../libs/lib64' "$f"; done
for f in "$LIB"/*.so*; do "$PATCHELF" --force-rpath --set-rpath '$ORIGIN' "$f"; done
[ $HAVE_BINUTILS = 1 ] && strip --strip-unneeded bin/HeadlessQtApp* plugins/*/*.so "$LIB"/libQt6*.so.6

# --- checks ---------------------------------------------------------------------------------------
bad=0
[ $HAVE_BINUTILS = 1 ] && for f in bin/HeadlessQtApp* plugins/*/*.so "$LIB"/*.so*; do
    need="$( (readelf -V "$f" 2>/dev/null || true) | (grep -oE 'GLIBC_2\.[0-9]+' || true) | sort -t. -k2 -n -u | tail -n1 | sed 's/GLIBC_//')"
    [ -n "$need" ] || continue
    if [ "$(printf '%s\n%s\n' "$GLIBC_MAX" "$need" | sort -t. -k2 -n | tail -n1)" != "$GLIBC_MAX" ]; then
        echo "[build] ERROR: $f requires GLIBC_$need (> $GLIBC_MAX)" >&2; bad=1
    fi
done
[ $bad = 0 ] || fail "files require glibc symbols newer than RHEL 9.0 GA"
for f in bin/HeadlessQtApp plugins/*/*.so "$LIB"/*.so*; do
    if env -u LD_LIBRARY_PATH ldd "$f" 2>&1 | grep -q 'not found'; then
        echo "[build] ERROR: $f: $(env -u LD_LIBRARY_PATH ldd "$f" | grep 'not found' | tr -s ' \n' ' ')" >&2; bad=1
    fi
done
[ $bad = 0 ] || fail "unresolved libraries"
"$PATCHELF" --print-rpath bin/HeadlessQtApp | grep -q '^\$ORIGIN/../libs/lib64$' || fail "RPATH not set on bin/HeadlessQtApp"
find bin plugins libs -type l | grep -q . && fail "symlinks in the tree"

{
    echo "HeadlessQtApp runtime manifest (built by build.sh)"
    echo "built: $(date -u +'%Y-%m-%dT%H:%M:%SZ') on $(cat /etc/redhat-release 2>/dev/null || uname -a), $( [ $COMPILE = 1 ] && g++ --version | head -n1 || echo 'prebuilt binary from support/prebuilt')"
    echo "Qt: $(grep -a -o -m1 'Qt [0-9]*\.[0-9]*\.[0-9]* ([^)]*)' "$LIB/libQt6Core.so.6") (from qt/6.8.0/gcc_64)"
    echo "glibc requirement: every file needs at most GLIBC_$GLIBC_MAX (RHEL 9.0 GA and later)"
    echo; echo "non-Qt libraries (from support/runtime-libs, origins):"; cat support/runtime-libs/ORIGINS.txt
} > "$LIB/MANIFEST.txt"

# --- smoke test: starts, prints its line, stays in the event loop until SIGTERM ------------------
tmp="$(mktemp)"
env -u LD_LIBRARY_PATH -u DISPLAY QT_QPA_PLATFORM=offscreen ./bin/HeadlessQtApp >"$tmp" 2>&1 & pid=$!
for _ in $(seq 1 100); do grep -q '^HeadlessQtApp pid=' "$tmp" 2>/dev/null && break; kill -0 $pid 2>/dev/null || break; sleep 0.1; done
if kill -0 $pid 2>/dev/null; then kill -TERM $pid; wait $pid 2>/dev/null || true; log "smoke test: $(head -n1 "$tmp")"; else cat "$tmp"; fail "smoke test: the binary did not start"; fi
rm -f "$tmp"

log "done. Deployable tree: bin/ plugins/ libs/lib64/  ($(du -sh libs | cut -f1) libs)"
log "copy bin/ plugins/ libs/ to the share and run:  <squish>/bin/startaut --port=4322 <share>/HeadlessQtApp/bin/HeadlessQtApp"
