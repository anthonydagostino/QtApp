#!/usr/bin/env bash
# build-rhel9.sh - build squish-anchor for RHEL 9 x86_64 inside a UBI 9 / RHEL 9-compatible
# container, against an exact Qt 6.6.0 Linux GCC 64-bit SDK.
#
# Steps:
#   1. Build the builder image from ./Containerfile.
#   2. Select the Qt 6.6.0 SDK:
#        a) QT_ROOT=/path/to/Qt/6.6.0/gcc_64   (official installer / aqt SDK) -> preferred, or
#        b) ./qt-sdk/6.6.0/gcc_64 if it was built previously by this script, or
#        c) build Qt 6.6.0 from the v6.6.0 qtbase sources (./qt-src/qtbase, cloned if absent)
#           with the container's GCC toolchain into ./qt-sdk/6.6.0/gcc_64.
#   3. Verify the SDK (Qt_6_PRIVATE_API present, version exactly 6.6.0); abort otherwise.
#   4. Configure/build/install the application into ./dist (./build is the build tree).
#
# Environment overrides:
#   CONTAINER_TOOL   podman|docker        (auto-detected; podman preferred)
#   BASE_IMAGE       builder base image   (default registry.access.redhat.com/ubi9/ubi:latest)
#   IMAGE_TAG        builder image tag    (default squish-anchor-builder:rhel9)
#   QT_ROOT          host path of an official Qt 6.6.0 gcc_64 SDK (mounted read-only)
#   QT_SOURCE_URL    git URL for qtbase   (default https://github.com/qt/qtbase.git)
#   QT_TAG           git tag              (default v6.6.0)
#   CONTAINER_NETWORK  value for --network (e.g. host); unset = runtime default
#   BUILD_CA_BUNDLE  PEM file to trust inside the image (TLS-inspecting proxies)
#   JOBS             parallel jobs
#   SKIP_IMAGE_BUILD=1  reuse an existing builder image
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

IMAGE_TAG="${IMAGE_TAG:-squish-anchor-builder:rhel9}"
BASE_IMAGE="${BASE_IMAGE:-registry.access.redhat.com/ubi9/ubi:latest}"
QT_SOURCE_URL="${QT_SOURCE_URL:-https://github.com/qt/qtbase.git}"
QT_TAG="${QT_TAG:-v6.6.0}"
QT_VERSION="${SQUISH_ANCHOR_REQUIRED_QT_VERSION:-6.6.0}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

log()  { echo "[build-rhel9] $*"; }
fail() { echo "[build-rhel9] ERROR: $*" >&2; exit 1; }

# --- container tool -------------------------------------------------------------------
if [ -z "${CONTAINER_TOOL:-}" ]; then
    if command -v podman >/dev/null 2>&1; then CONTAINER_TOOL=podman
    elif command -v docker >/dev/null 2>&1; then CONTAINER_TOOL=docker
    else fail "neither podman nor docker found"; fi
fi
log "container tool: $CONTAINER_TOOL"

net_args=()
[ -n "${CONTAINER_NETWORK:-}" ] && net_args=(--network "$CONTAINER_NETWORK")

proxy_build_args=()
for v in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
    [ -n "${!v:-}" ] && proxy_build_args+=(--build-arg "$v=${!v}")
done
proxy_run_args=()
for v in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
    [ -n "${!v:-}" ] && proxy_run_args+=(-e "$v=${!v}")
done

user_args=()
if [ "$CONTAINER_TOOL" = docker ] && [ "$(id -u)" != 0 ]; then
    user_args=(--user "$(id -u):$(id -g)" -e HOME=/tmp)
fi

# --- 1. builder image ------------------------------------------------------------------
mkdir -p build-support/ca-anchors
if [ -n "${BUILD_CA_BUNDLE:-}" ]; then
    [ -f "$BUILD_CA_BUNDLE" ] || fail "BUILD_CA_BUNDLE not found: $BUILD_CA_BUNDLE"
    cp "$BUILD_CA_BUNDLE" build-support/ca-anchors/extra-ca.crt
fi
if [ "${SKIP_IMAGE_BUILD:-0}" != 1 ]; then
    log "building image $IMAGE_TAG from $BASE_IMAGE"
    "$CONTAINER_TOOL" build "${net_args[@]}" "${proxy_build_args[@]}" \
        --build-arg "BASE_IMAGE=$BASE_IMAGE" \
        -f Containerfile -t "$IMAGE_TAG" .
else
    log "SKIP_IMAGE_BUILD=1: reusing image $IMAGE_TAG"
fi

run_in_container() {
    # usage: run_in_container [extra run args...] -- <command...>
    local extra=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do extra+=("$1"); shift; done
    shift || true
    "$CONTAINER_TOOL" run --rm "${net_args[@]}" "${proxy_run_args[@]}" "${user_args[@]}" \
        -v "$REPO_DIR:/work${MOUNT_SUFFIX:-}" -w /work \
        -e "JOBS=$JOBS" -e "SQUISH_ANCHOR_REQUIRED_QT_VERSION=$QT_VERSION" \
        "${extra[@]}" "$IMAGE_TAG" "$@"
}

log "builder image details:"
run_in_container -- bash -c 'cat /etc/redhat-release; gcc --version | head -n1; cmake --version | head -n1; ldd --version | head -n1'

# --- 2. Qt 6.6.0 SDK --------------------------------------------------------------------
sdk_mount=()
if [ -n "${QT_ROOT:-}" ]; then
    [ -e "$QT_ROOT/lib/libQt6Core.so.6" ] || fail "QT_ROOT=$QT_ROOT has no lib/libQt6Core.so.6"
    QT_ROOT_IN="/opt/Qt/$QT_VERSION/gcc_64"
    sdk_mount=(-v "$(cd "$QT_ROOT" && pwd):$QT_ROOT_IN:ro")
    log "using supplied Qt SDK: $QT_ROOT (mounted at $QT_ROOT_IN)"
elif [ -e "qt-sdk/$QT_VERSION/gcc_64/lib/libQt6Core.so.6" ]; then
    QT_ROOT_IN="/work/qt-sdk/$QT_VERSION/gcc_64"
    log "using previously built Qt SDK: qt-sdk/$QT_VERSION/gcc_64"
else
    QT_ROOT_IN="/work/qt-sdk/$QT_VERSION/gcc_64"
    log "no Qt $QT_VERSION SDK supplied (QT_ROOT unset); building Qt $QT_VERSION from source"
    if [ ! -f qt-src/qtbase/configure ]; then
        log "cloning $QT_SOURCE_URL tag $QT_TAG into qt-src/qtbase"
        mkdir -p qt-src
        git clone --depth 1 --branch "$QT_TAG" "$QT_SOURCE_URL" qt-src/qtbase
    fi
    tag="$(git -C qt-src/qtbase describe --tags --exact-match 2>/dev/null || true)"
    log "qt-src/qtbase: $(git -C qt-src/qtbase rev-parse HEAD) tag=${tag:-?}"
    [ "$tag" = "$QT_TAG" ] || fail "qt-src/qtbase is not at tag $QT_TAG (got '${tag:-none}')"
    run_in_container -- scripts/build-qt-sdk.sh /work/qt-src/qtbase "$QT_ROOT_IN" /work/qt-sdk/build-qtbase
fi

# --- 3. verify SDK (Qt_6_PRIVATE_API, exact version) -----------------------------------
run_in_container "${sdk_mount[@]}" -- scripts/verify-qt-sdk.sh "$QT_ROOT_IN"

# --- 4. build the application ------------------------------------------------------------
run_in_container "${sdk_mount[@]}" -- scripts/build-app.sh "$QT_ROOT_IN" /work /work/build /work/dist

# Record the SDK location for package-runtime.sh
printf '%s\n' "$QT_ROOT_IN" > build/qt-root-in-container.txt
printf '%s\n' "${QT_ROOT:-}" > build/qt-root-on-host.txt

log "done: dist/bin/squish-anchor"
log "next: ./package-runtime.sh"
