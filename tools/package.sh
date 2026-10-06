#!/usr/bin/env bash
# tools/package.sh - lay out the self-contained, relocatable headlessQtApp tree at the
# repository root (the folder you put on the file share):
#
#   bin/headlessQtApp, bin/qt.conf
#   plugins/platforms/*.so, plugins/imageformats/*.so      (Qt plugins)
#   libs/lib64/*.so.N                                       (EVERY library except glibc:
#                                                            Qt, ICU, glib2, pcre, libstdc++, libgcc_s)
#   libs/lib64/fonts/*.ttf                                  (fonts for offscreen rendering)
#   libs/lib64/MANIFEST.txt
#
# No symlinks are created: every library is a real file named exactly as the dynamic
# loader asks for it (its SONAME), so the tree survives SMB/Windows file shares.
#
# Must run with the RHEL 9 userland the binary was built in. On the host it re-executes
# itself inside the builder image; inside the container (HEADLESSQTAPP_IN_CONTAINER=1)
# it does the work. Run tools/build-rhel9.sh first.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"
log()  { echo "[package] $*"; }
fail() { echo "[package] ERROR: $*" >&2; exit 1; }

# --- host side: re-exec inside the builder container -------------------------------------------
if [ "${HEADLESSQTAPP_IN_CONTAINER:-0}" != 1 ]; then
    [ -f build/qt-root-in-container.txt ] || fail "run tools/build-rhel9.sh first"
    IMAGE_TAG="${IMAGE_TAG:-headlessqtapp-builder:rhel9}"
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
    if [ "$CONTAINER_TOOL" = docker ] && [ "$(id -u)" != 0 ]; then user_args=(--user "$(id -u):$(id -g)" -e HOME=/tmp); fi
    log "re-executing inside $IMAGE_TAG ($CONTAINER_TOOL)"
    exec "$CONTAINER_TOOL" run --rm "${user_args[@]}" "${mounts[@]}" -w /work \
        -e "SKIP_VALIDATION=${SKIP_VALIDATION:-0}" -e "QT_ROOT=$QT_ROOT_IN" \
        "$IMAGE_TAG" tools/package.sh
fi

# --- container side ---------------------------------------------------------------------------------
QT_ROOT="${QT_ROOT:-$(cat build/qt-root-in-container.txt 2>/dev/null || true)}"
[ -n "$QT_ROOT" ] || fail "QT_ROOT is not set"
[ -x dist/bin/headlessQtApp ] || fail "dist/bin/headlessQtApp not found; run tools/build-rhel9.sh first"
for t in readelf ldd patchelf strip; do command -v "$t" >/dev/null || fail "$t not found in the builder image"; done
tools/scripts/verify-qt-sdk.sh "$QT_ROOT"

# glibc is the only thing taken from the target machine.
GLIBC_RE='^(linux-vdso\.so\.1|ld-linux-x86-64\.so\.2|libc\.so\.6|libm\.so\.6|libpthread\.so\.0|libdl\.so\.2|librt\.so\.1|libresolv\.so\.2|libutil\.so\.1|libnsl\.so\.[0-9]+|libanl\.so\.1|libcrypt\.so\.[0-9]+)$'

LIB="libs/lib64"
log "assembling bin/ plugins/ $LIB/"
rm -rf bin plugins libs
mkdir -p bin plugins/platforms plugins/imageformats "$LIB/fonts"

install -m 0755 dist/bin/headlessQtApp bin/headlessQtApp
install -m 0644 dist/bin/qt.conf bin/qt.conf

# Qt plugins: platform plugins (offscreen, minimal) and image formats.
for f in "$QT_ROOT"/plugins/platforms/libqoffscreen.so "$QT_ROOT"/plugins/platforms/libqminimal.so; do
    [ -f "$f" ] && install -m 0755 "$f" plugins/platforms/
done
for f in "$QT_ROOT"/plugins/imageformats/*.so; do
    [ -f "$f" ] && install -m 0755 "$f" plugins/imageformats/
done
[ -f plugins/platforms/libqoffscreen.so ] || fail "offscreen platform plugin missing in $QT_ROOT/plugins/platforms"

# Every Qt library of the SDK, under its SONAME, as a real file (Squish's wrapper may
# load modules the application itself does not link).
declare -A origin
for f in "$QT_ROOT"/lib/libQt6*.so.6; do
    [ -e "$f" ] || continue
    real="$(readlink -f "$f")"
    soname="$(readelf -d "$real" | sed -n 's/.*(SONAME) *Library soname: \[\(.*\)\]/\1/p')"
    [ -n "$soname" ] || soname="$(basename "$f")"
    install -m 0755 "$real" "$LIB/$soname"
    origin["$soname"]="$real (Qt 6.6.0 SDK)"
done

# Transitive closure over the binary, every plugin and every Qt library, resolved with the
# SDK's lib dir visible. Anything that is not glibc is copied under the name the loader asks for.
resolve_into_lib() {
    local file="$1" out
    out="$(LD_LIBRARY_PATH="$QT_ROOT/lib:$REPO_DIR/$LIB" ldd "$file" 2>&1)" || fail "ldd failed on $file: $out"
    grep -q 'not found' <<<"$out" && fail "unresolved dependency for $file: $(grep 'not found' <<<"$out" | tr -s ' \n' ' ')"
    while read -r name arrow path _; do
        [ "$arrow" = "=>" ] || continue
        [[ "$name" =~ $GLIBC_RE ]] && continue
        [ -e "$LIB/$name" ] && continue
        local real; real="$(readlink -f "$path")"
        [ -f "$real" ] || fail "cannot resolve $name ($path)"
        install -m 0755 "$real" "$LIB/$name"
        origin["$name"]="$real ($(rpm -qf "$real" 2>/dev/null || echo 'build system'))"
    done <<<"$out"
}
resolve_into_lib bin/headlessQtApp
for f in plugins/*/*.so "$LIB"/*.so*; do resolve_into_lib "$f"; done
# second pass: dependencies of the libraries just added (e.g. libpcre for glib)
for f in "$LIB"/*.so*; do resolve_into_lib "$f"; done

# Fonts for the offscreen platform (no fontconfig on the target is required).
for f in /usr/share/fonts/dejavu/DejaVuSans.ttf /usr/share/fonts/dejavu/DejaVuSans-Bold.ttf /usr/share/fonts/dejavu/DejaVuSansMono.ttf; do
    [ -f "$f" ] && install -m 0644 "$f" "$LIB/fonts/"
done
ls "$LIB"/fonts/*.ttf >/dev/null 2>&1 || fail "no fonts found (install dejavu-sans-fonts in the builder image)"

# Runtime search paths: binary -> ../libs/lib64, plugins -> ../../libs/lib64, libraries -> $ORIGIN.
runpath_of() { local d; d="$(readelf -d "$1")"; sed -n 's/.*(R\(UN\)\?PATH) *Library r\(un\)\?path: \[\(.*\)\]/\3/p' <<<"$d" | sed -n '1p'; }
set_runpath() { [ "$(runpath_of "$1")" = "$2" ] || { patchelf --set-rpath "$2" "$1"; log "RUNPATH $1 -> $2"; }; }
set_runpath bin/headlessQtApp '$ORIGIN/../libs/lib64'
for f in plugins/*/*.so; do set_runpath "$f" '$ORIGIN/../../libs/lib64'; done
for f in "$LIB"/*.so*; do set_runpath "$f" '$ORIGIN'; done

# Strip what we built (SONAMEs, symbol versions untouched); system libraries are already stripped.
strip --strip-unneeded bin/headlessQtApp plugins/*/*.so
for f in "$LIB"/libQt6*.so.6; do strip --strip-unneeded "$f"; done

# Manifest
{
    echo "headlessQtApp runtime manifest"
    echo "built: $(date -u +'%Y-%m-%dT%H:%M:%SZ') on $(cat /etc/redhat-release 2>/dev/null), glibc $(ldd --version | head -n1 | sed 's/.* //'), $(g++ --version | head -n1)"
    echo "Qt: $(grep -a -o -m1 'Qt [0-9]*\.[0-9]*\.[0-9]* ([^)]*)' "$LIB/libQt6Core.so.6")"
    echo
    echo "libs/lib64 (every library except glibc; the loader finds them by exactly these names):"
    for n in $(ls "$LIB" | grep '\.so' | sort); do printf '  %-28s <- %s\n' "$n" "${origin[$n]:-?}"; done
    echo
    echo "plugins:"; ls plugins/*/*.so | sed 's/^/  /'
    echo; echo "fonts:"; ls "$LIB"/fonts | sed 's/^/  /'
    echo; echo "taken from the target machine (glibc only):"
    LD_LIBRARY_PATH="$REPO_DIR/$LIB" ldd bin/headlessQtApp | awk '$3 ~ /^\/(usr\/)?lib64\// {print "  " $1 " => " $3}'
} > "$LIB/MANIFEST.txt"
chmod 0755 run-headlessQtApp.sh validate.sh check-deps.sh

log "tree:"; find bin plugins libs -type f | sort | sed 's/^/    /'
log "size: $(du -sh libs plugins bin | awk '{printf "%s %s  ", $1, $2}')"
if find bin plugins libs -type l | grep -q .; then fail "symlinks present"; fi

if [ "${SKIP_VALIDATION:-0}" != 1 ]; then
    ./validate.sh --strict "$REPO_DIR"
fi
log "done"
