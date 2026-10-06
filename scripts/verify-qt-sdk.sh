#!/usr/bin/env bash
# Verify that a Qt SDK is the exact Qt 6.6.0 Linux GCC 64-bit runtime required by the
# installed Squish Qt wrapper:
#   * lib/libQt6Core.so.6 exists and is an ELF64 x86-64 shared object
#   * it exports the Qt_6_PRIVATE_API symbol version
#       readelf --version-info "$QT_ROOT/lib/libQt6Core.so.6" | grep Qt_6_PRIVATE_API
#   * the SDK version is exactly 6.6.0 (Qt6ConfigVersion.cmake / embedded version string)
# Exit status 0 only if every check passes.
set -euo pipefail

QT_ROOT="${1:-${QT_ROOT:-}}"
REQUIRED_VERSION="${SQUISH_ANCHOR_REQUIRED_QT_VERSION:-6.6.0}"

fail() { echo "verify-qt-sdk: ERROR: $*" >&2; exit 1; }

[ -n "$QT_ROOT" ] || fail "usage: $0 <QT_ROOT>   (e.g. /opt/Qt/6.6.0/gcc_64)"
[ -d "$QT_ROOT" ] || fail "QT_ROOT does not exist: $QT_ROOT"

CORE="$QT_ROOT/lib/libQt6Core.so.6"
[ -e "$CORE" ] || fail "missing $CORE"
command -v readelf >/dev/null || fail "readelf not found (install binutils)"

echo "verify-qt-sdk: QT_ROOT=$QT_ROOT"
echo "verify-qt-sdk: libQt6Core.so.6 -> $(readlink -f "$CORE")"

# ELF class / machine
HDR="$(readelf -h "$CORE")"
grep -q 'Class: *ELF64' <<<"$HDR" || fail "$CORE is not ELF64"
grep -q "Machine: *Advanced Micro Devices X86-64" <<<"$HDR" || fail "$CORE is not x86-64"
grep -q 'Type: *DYN' <<<"$HDR" || fail "$CORE is not a shared object"
echo "verify-qt-sdk: ELF64 x86-64 shared object: OK"

# Qt_6_PRIVATE_API symbol version (the critical Squish compatibility requirement)
# (capture first: with pipefail, grep -q closing the pipe early would make readelf fail)
VERSION_INFO="$(readelf --version-info "$CORE")"
if grep -q 'Qt_6_PRIVATE_API' <<<"$VERSION_INFO"; then
    echo "verify-qt-sdk: Qt_6_PRIVATE_API symbol version: present"
else
    fail "Qt_6_PRIVATE_API symbol version is ABSENT from $CORE. The supplied Qt SDK is incompatible with the installed Squish Qt wrapper. Stopping; refusing to build against another Qt."
fi

# Exact version
VERSION=""
CFG="$QT_ROOT/lib/cmake/Qt6/Qt6ConfigVersion.cmake"
if [ -f "$CFG" ]; then
    VERSION="$(sed -n 's/^set(PACKAGE_VERSION "\([0-9.]*\)")/\1/p' "$CFG" | sed -n '1p')"
fi
if [ -z "$VERSION" ]; then
    VERSION="$(grep -a -o -m1 'Qt [0-9][0-9.]* (x86_64' "$CORE" | sed 's/^Qt //; s/ (x86_64//')"
fi
[ -n "$VERSION" ] || fail "could not determine the Qt version of $QT_ROOT"
echo "verify-qt-sdk: Qt version: $VERSION"
[ "$VERSION" = "$REQUIRED_VERSION" ] || fail "Qt $VERSION found, but exactly Qt $REQUIRED_VERSION is required. Refusing to substitute another Qt version."

# Embedded build banner (informational)
BANNER="$(grep -a -o -m1 'Qt [0-9]*\.[0-9]*\.[0-9]* ([^)]*)' "$CORE" || true)"
[ -n "$BANNER" ] && echo "verify-qt-sdk: build banner: $BANNER"

echo "verify-qt-sdk: OK - Qt $VERSION SDK at $QT_ROOT is compatible"
