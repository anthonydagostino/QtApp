#!/usr/bin/env bash
# Build Qt 6.6.0 (qtbase: Core and friends, no Gui/Widgets/DBus/OpenGL) from the
# v6.6.0 sources with the RHEL 9 GCC toolchain and install it as a conventional
# "gcc_64" SDK layout. Runs inside the builder container.
#
#   build-qt-sdk.sh <qtbase-source-dir> <install-prefix> [build-dir]
#
# This is the fallback used when no official Qt 6.6.0 Linux GCC 64-bit SDK
# (installer/aqt "gcc_64") is supplied via QT_ROOT. The configuration mirrors the
# official binaries where it matters for the runtime (shared/release build, ICU
# enabled) but minimises what is taken from the target system: zlib and pcre2 are
# bundled into libQt6Core and GLib is disabled, so the runtime needs only glibc,
# libstdc++ and libgcc_s from the RHEL 9 host (the package carries lib/fallback/
# copies of the latter two for hosts that lack them).
set -euo pipefail

SRC="${1:?usage: $0 <qtbase-source-dir> <install-prefix> [build-dir]}"
PREFIX="${2:?usage: $0 <qtbase-source-dir> <install-prefix> [build-dir]}"
BUILD="${3:-$(dirname "$PREFIX")/build-qtbase}"
REQUIRED_VERSION="${SQUISH_ANCHOR_REQUIRED_QT_VERSION:-6.6.0}"
JOBS="${JOBS:-$(nproc)}"

fail() { echo "build-qt-sdk: ERROR: $*" >&2; exit 1; }

[ -f "$SRC/configure" ] || fail "$SRC does not look like a qtbase source tree (no configure)"
SRC_VERSION="$(sed -n 's/^set(QT_REPO_MODULE_VERSION "\([0-9.]*\)")/\1/p' "$SRC/.cmake.conf")"
echo "build-qt-sdk: source version: $SRC_VERSION"
[ "$SRC_VERSION" = "$REQUIRED_VERSION" ] || fail "source tree is Qt $SRC_VERSION, need exactly $REQUIRED_VERSION"

echo "build-qt-sdk: toolchain: $(gcc --version | head -n1); $(cmake --version | head -n1); $(ninja --version)"
echo "build-qt-sdk: prefix: $PREFIX  build dir: $BUILD  jobs: $JOBS"

# always configure from scratch so stale caches cannot leak old options
rm -rf "$BUILD"
mkdir -p "$BUILD"
cd "$BUILD"

# Qt's configure accepts -- followed by raw CMake arguments.
"$SRC/configure" \
    -prefix "$PREFIX" \
    -release \
    -shared \
    -opensource -confirm-license \
    -nomake examples -nomake tests \
    -no-gui -no-widgets \
    -no-dbus \
    -no-opengl \
    -no-openssl \
    -no-feature-network -no-feature-sql -no-feature-xml -no-feature-testlib -no-feature-concurrent \
    -qt-zlib \
    -qt-pcre \
    -icu \
    -no-glib \
    -- \
    -DCMAKE_BUILD_TYPE=Release \
    -DQT_BUILD_TESTS=OFF \
    -DQT_BUILD_EXAMPLES=OFF

cmake --build . --parallel "$JOBS"
cmake --install .

echo "build-qt-sdk: installed Qt $SRC_VERSION to $PREFIX"
ls -l "$PREFIX/lib/libQt6Core.so"*
