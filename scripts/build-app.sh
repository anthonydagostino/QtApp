#!/usr/bin/env bash
# Configure, build and install squish-anchor against the Qt SDK at QT_ROOT.
# Runs inside the builder container.
#
#   build-app.sh <QT_ROOT> [source-dir] [build-dir] [install-prefix]
set -euo pipefail

QT_ROOT="${1:?usage: $0 <QT_ROOT> [source-dir] [build-dir] [install-prefix]}"
SRC="${2:-/work}"
BUILD="${3:-/work/build}"
DIST="${4:-/work/dist}"
JOBS="${JOBS:-$(nproc)}"

echo "build-app: QT_ROOT=$QT_ROOT"
echo "build-app: toolchain: $(g++ --version | head -n1); $(cmake --version | head -n1)"

rm -rf "$BUILD" "$DIST"
GENERATOR="Unix Makefiles"; command -v ninja >/dev/null && GENERATOR=Ninja
echo "build-app: generator: $GENERATOR"
cmake -S "$SRC" -B "$BUILD" -G "$GENERATOR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$QT_ROOT" \
    -DCMAKE_INSTALL_PREFIX="$DIST"
cmake --build "$BUILD" --parallel "$JOBS" --verbose
cmake --install "$BUILD"

echo "build-app: installed:"
ls -l "$DIST/bin/squish-anchor"
file "$DIST/bin/squish-anchor"
