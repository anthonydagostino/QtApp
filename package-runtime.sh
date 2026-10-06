#!/usr/bin/env bash
# package-runtime.sh - assemble the relocatable runtime package and the deployment archive
#
#   squish-anchor-rhel9-x86_64/
#   ├── bin/squish-anchor
#   ├── lib/libQt6Core.so.6 (+ real file) and the Qt runtime dependencies it needs
#   ├── run-squish-anchor.sh
#   └── README.md
#   -> squish-anchor-rhel9-x86_64.tar.gz
#
# Must run with the same RHEL 9 userland the binary was built in. When invoked on the
# host it re-executes itself inside the builder image (same mounts as build-rhel9.sh).
# Inside the container (SQUISH_ANCHOR_IN_CONTAINER=1) it does the actual work.
#
# Environment:
#   QT_ROOT          host path of the Qt SDK used by build-rhel9.sh (only when it was supplied there)
#   PKG_NAME         package directory / archive base name (default squish-anchor-rhel9-x86_64)
#   SKIP_VALIDATION=1  do not run scripts/validate-package.sh afterwards
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

PKG_NAME="${PKG_NAME:-squish-anchor-rhel9-x86_64}"
OUT_DIR="out"
PKG_DIR="$OUT_DIR/$PKG_NAME"
ARCHIVE="$PKG_NAME.tar.gz"

log()  { echo "[package-runtime] $*"; }
fail() { echo "[package-runtime] ERROR: $*" >&2; exit 1; }

# --- host side: re-exec inside the builder container ---------------------------------------
if [ "${SQUISH_ANCHOR_IN_CONTAINER:-0}" != 1 ]; then
    [ -f build/qt-root-in-container.txt ] || fail "run ./build-rhel9.sh first (build/qt-root-in-container.txt missing)"
    IMAGE_TAG="${IMAGE_TAG:-squish-anchor-builder:rhel9}"
    if [ -z "${CONTAINER_TOOL:-}" ]; then
        if command -v podman >/dev/null 2>&1; then CONTAINER_TOOL=podman
        elif command -v docker >/dev/null 2>&1; then CONTAINER_TOOL=docker
        else fail "neither podman nor docker found"; fi
    fi
    QT_ROOT_IN="$(cat build/qt-root-in-container.txt)"
    QT_ROOT_HOST="${QT_ROOT:-$(cat build/qt-root-on-host.txt 2>/dev/null || true)}"
    mounts=(-v "$REPO_DIR:/work")
    if [ -n "$QT_ROOT_HOST" ]; then
        [ -e "$QT_ROOT_HOST/lib/libQt6Core.so.6" ] || fail "QT_ROOT=$QT_ROOT_HOST has no lib/libQt6Core.so.6"
        mounts+=(-v "$(cd "$QT_ROOT_HOST" && pwd):$QT_ROOT_IN:ro")
    fi
    user_args=()
    if [ "$CONTAINER_TOOL" = docker ] && [ "$(id -u)" != 0 ]; then
        user_args=(--user "$(id -u):$(id -g)" -e HOME=/tmp)
    fi
    net_args=()
    [ -n "${CONTAINER_NETWORK:-}" ] && net_args=(--network "$CONTAINER_NETWORK")
    log "re-executing inside $IMAGE_TAG ($CONTAINER_TOOL)"
    exec "$CONTAINER_TOOL" run --rm "${net_args[@]}" "${user_args[@]}" "${mounts[@]}" -w /work \
        -e "PKG_NAME=$PKG_NAME" -e "SKIP_VALIDATION=${SKIP_VALIDATION:-0}" \
        -e "QT_ROOT=$QT_ROOT_IN" \
        "$IMAGE_TAG" ./package-runtime.sh
fi

# --- container side ---------------------------------------------------------------------------
QT_ROOT="${QT_ROOT:-$(cat build/qt-root-in-container.txt 2>/dev/null || true)}"
[ -n "$QT_ROOT" ] || fail "QT_ROOT is not set"
BIN_SRC="dist/bin/squish-anchor"
[ -x "$BIN_SRC" ] || fail "$BIN_SRC not found; run ./build-rhel9.sh first"
for t in readelf ldd file tar; do command -v "$t" >/dev/null || fail "$t not found"; done

scripts/verify-qt-sdk.sh "$QT_ROOT"

# Core RHEL 9 system libraries that must NOT be bundled or relocated. Everything the
# binary (transitively) needs that is not in this list is bundled into lib/.
SYSTEM_LIB_RE='^(linux-vdso\.so\.1|ld-linux-x86-64\.so\.2|libc\.so\.6|libm\.so\.6|libpthread\.so\.0|libdl\.so\.2|librt\.so\.1|libresolv\.so\.2|libutil\.so\.1|libnsl\.so\.[0-9]+|libanl\.so\.1|libcrypt\.so\.[0-9]+|libstdc\+\+\.so\.6|libgcc_s\.so\.1|libz\.so\.1|libglib-2\.0\.so\.0|libgthread-2\.0\.so\.0|libgobject-2\.0\.so\.0|libgmodule-2\.0\.so\.0|libgio-2\.0\.so\.0|libpcre2-8\.so\.0|libpcre\.so\.1|libffi\.so\.[0-9]+|libmount\.so\.1|libblkid\.so\.1|libuuid\.so\.1|libselinux\.so\.1|libsystemd\.so\.0|libgcrypt\.so\.[0-9]+|libgpg-error\.so\.0|liblz4\.so\.1|liblzma\.so\.5|libzstd\.so\.1|libcap\.so\.2)$'

log "assembling $PKG_DIR"
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/bin" "$PKG_DIR/lib"
cp -p "$BIN_SRC" "$PKG_DIR/bin/squish-anchor"
chmod 0755 "$PKG_DIR/bin/squish-anchor"

# Resolve the full dependency tree of the binary with the SDK's lib dir visible.
log "resolving shared-library dependencies (ldd with LD_LIBRARY_PATH=$QT_ROOT/lib)"
LDD_OUT="$(LD_LIBRARY_PATH="$QT_ROOT/lib" ldd "$PKG_DIR/bin/squish-anchor")"
echo "$LDD_OUT" | sed 's/^/    /'
grep -q 'not found' <<<"$LDD_OUT" && fail "unresolved dependencies"

bundled=()
skipped=()
while read -r name arrow path _; do
    [ -n "$name" ] || continue
    case "$name" in linux-vdso.so.1|ld-linux-x86-64.so.2) continue;; esac
    if [[ "$name" == /* ]]; then continue; fi          # the dynamic loader line
    [ "$arrow" = "=>" ] || continue
    if [[ "$name" =~ $SYSTEM_LIB_RE ]]; then
        skipped+=("$name => $path")
        continue
    fi
    real="$(readlink -f "$path")"
    [ -f "$real" ] || fail "cannot resolve $name ($path)"
    realname="$(basename "$real")"
    soname="$(readelf -d "$real" | sed -n 's/.*(SONAME) *Library soname: \[\(.*\)\]/\1/p' | head -n1)"
    if [ ! -e "$PKG_DIR/lib/$realname" ]; then
        cp -p "$real" "$PKG_DIR/lib/$realname"
        chmod 0755 "$PKG_DIR/lib/$realname"
    fi
    # SONAME symlink (e.g. libQt6Core.so.6 -> libQt6Core.so.6.6.0)
    if [ -n "$soname" ] && [ "$soname" != "$realname" ]; then
        ln -sfn "$realname" "$PKG_DIR/lib/$soname"
    fi
    # the name the binary asked for, if it differs from both (defensive)
    if [ "$name" != "$realname" ] && [ "$name" != "$soname" ]; then
        ln -sfn "$realname" "$PKG_DIR/lib/$name"
    fi
    bundled+=("$name => $realname (SONAME $soname) from $path")
done <<<"$LDD_OUT"

log "bundled into lib/:"
printf '    %s\n' "${bundled[@]}"
log "left to the RHEL 9 system (not bundled):"
printf '    %s\n' "${skipped[@]}"

[ -e "$PKG_DIR/lib/libQt6Core.so.6" ] || fail "lib/libQt6Core.so.6 is missing from the package"

# --- runtime search paths (DT_RUNPATH) ------------------------------------------------------------
runpath_of() { readelf -d "$1" | sed -n 's/.*(R\(UN\)\?PATH) *Library r\(un\)\?path: \[\(.*\)\]/\3/p' | head -n1; }

want='$ORIGIN/../lib'
have="$(runpath_of "$PKG_DIR/bin/squish-anchor")"
if [ "$have" = "$want" ]; then
    log "bin/squish-anchor RUNPATH already '$want' (set by CMake); patchelf not needed"
else
    command -v patchelf >/dev/null || fail "bin/squish-anchor RUNPATH is '$have', need '$want', and patchelf is not installed"
    log "bin/squish-anchor RUNPATH is '$have'; setting '$want' with patchelf"
    patchelf --set-rpath "$want" "$PKG_DIR/bin/squish-anchor"
    [ "$(runpath_of "$PKG_DIR/bin/squish-anchor")" = "$want" ] || fail "patchelf did not set the RUNPATH"
fi

# Bundled libraries must find each other in lib/ (DT_RUNPATH is not transitive), so each
# gets RUNPATH '$ORIGIN'. SONAMEs and file names are not touched.
if command -v patchelf >/dev/null; then
    for lib in "$PKG_DIR"/lib/*; do
        [ -L "$lib" ] && continue
        cur="$(runpath_of "$lib")"
        if [ "$cur" != '$ORIGIN' ]; then
            log "lib/$(basename "$lib"): RUNPATH '${cur:-<none>}' -> '\$ORIGIN' (patchelf)"
            patchelf --set-rpath '$ORIGIN' "$lib"
        fi
    done
else
    log "WARNING: patchelf not available; bundled libraries keep their RUNPATH (run-squish-anchor.sh sets LD_LIBRARY_PATH, so the wrapper still works)"
fi

# --- lib/fallback: libstdc++ / libgcc_s safety net for hosts that lack them -------------------------
# Not on the loader's search path by default: run-squish-anchor.sh appends lib/fallback only when the
# host provides neither /lib64/libstdc++.so.6 nor /lib64/libgcc_s.so.1. The package therefore runs
# out of the box on a stripped-down offline VM, while a normal RHEL 9 host keeps using its own copies.
mkdir -p "$PKG_DIR/lib/fallback"
fallback=()
for name in libstdc++.so.6 libgcc_s.so.1; do
    path="$(grep -E "^\s*$name => " <<<"$LDD_OUT" | awk '{print $3}' | head -n1)"
    [ -n "$path" ] || fail "could not locate $name for lib/fallback"
    real="$(readlink -f "$path")"
    cp -p "$real" "$PKG_DIR/lib/fallback/$(basename "$real")"
    chmod 0755 "$PKG_DIR/lib/fallback/$(basename "$real")"
    [ "$(basename "$real")" != "$name" ] && ln -sfn "$(basename "$real")" "$PKG_DIR/lib/fallback/$name"
    fallback+=("$name => $(basename "$real") from $path ($(rpm -qf "$real" 2>/dev/null || echo 'build system'))")
done
log "lib/fallback/ (only used if the host lacks them):"
printf '    %s\n' "${fallback[@]}"

# --- wrapper, validator, README, manifest ---------------------------------------------------------
install -m 0755 run-squish-anchor.sh "$PKG_DIR/run-squish-anchor.sh"
install -m 0755 scripts/validate-package.sh "$PKG_DIR/validate.sh"

QT_VERSION="$(sed -n 's/^set(PACKAGE_VERSION "\([0-9.]*\)")/\1/p' "$QT_ROOT/lib/cmake/Qt6/Qt6ConfigVersion.cmake" | head -n1)"
QT_BANNER="$(strings -a "$QT_ROOT/lib/libQt6Core.so.6" | grep -m1 -E '^Qt [0-9]+\.[0-9]+\.[0-9]+ \(' || true)"
{
    cat packaging/README.runtime.md
    echo
    echo "## Build and bundle manifest"
    echo
    echo "- Built: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    echo "- Build environment: $(cat /etc/redhat-release 2>/dev/null || echo unknown), glibc $(ldd --version | head -n1 | sed 's/.* //')"
    echo "- Compiler: $(g++ --version | head -n1)"
    echo "- Qt: $QT_VERSION ($QT_BANNER)"
    echo "- Qt SDK root at build time: $QT_ROOT"
    echo
    echo "Bundled in \`lib/\`:"
    echo
    for l in "${bundled[@]}"; do echo "- $l"; done
    echo
    echo "Resolved from the RHEL 9 system (not bundled):"
    echo
    for l in "${skipped[@]}"; do echo "- $l"; done
    echo
    echo "Fallback copies in \`lib/fallback/\` (used by the wrapper only if the host lacks them):"
    echo
    for l in "${fallback[@]}"; do echo "- $l"; done
    echo
    echo "\`bin/squish-anchor\` RUNPATH: \`$(runpath_of "$PKG_DIR/bin/squish-anchor")\`"
} > "$PKG_DIR/README.md"

# --- archive ---------------------------------------------------------------------------------------------
log "creating $ARCHIVE"
rm -f "$ARCHIVE"
tar -C "$OUT_DIR" --owner=0 --group=0 --numeric-owner -czf "$ARCHIVE" "$PKG_NAME"
sha256sum "$ARCHIVE" | tee "$ARCHIVE.sha256"
log "package tree:"
( cd "$OUT_DIR" && find "$PKG_NAME" | sort | sed 's/^/    /' )

if [ "${SKIP_VALIDATION:-0}" != 1 ]; then
    "$PKG_DIR/validate.sh" --strict "$PKG_DIR"
fi
log "done: $ARCHIVE"
