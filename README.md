# squish-anchor

A headless, long-running Qt anchor process for Squish attachment, packaged for
**RHEL 9-compatible Linux, x86_64**.

- `QCoreApplication` only: no GUI, no QtWidgets/QtQuick/QML, no X11/Wayland, no display.
- Logs its startup and PID to standard output, then runs the Qt event loop until
  `SIGTERM` or `SIGINT` (exit status 0). `--once` logs startup and exits 0.
- Built with CMake, C++17 and the GCC toolchain in a UBI 9 / RHEL 9-compatible container.
- Built and bundled against an **exact Qt 6.6.0** Linux GCC 64-bit runtime whose
  `libQt6Core.so.6` exports the `Qt_6_PRIVATE_API` symbol version, which the installed
  Squish Qt wrapper (built with Qt 6.6.0) requires. The build refuses any other Qt.
- **Deploys to an offline VM out of the box.** The archive is self-contained: no Qt, no
  container runtime, no packages and no network are needed on the target. Containers are
  only used on the *build* side.

## Repository contents

| Path | Purpose |
| --- | --- |
| `CMakeLists.txt` | CMake project (C++17, Qt6::Core only, RUNPATH `$ORIGIN/../lib`, exact-version + `Qt_6_PRIVATE_API` checks) |
| `src/main.cpp` | The application |
| `Containerfile` | RHEL 9 / UBI 9 builder image (GCC, CMake, Ninja, binutils, patchelf, Qt build deps) |
| `build-rhel9.sh` | Builds the image, selects/verifies the Qt 6.6.0 SDK, builds and installs the app into `dist/` |
| `package-runtime.sh` | Assembles `squish-anchor-rhel9-x86_64/` and `squish-anchor-rhel9-x86_64.tar.gz`, then validates it |
| `run-squish-anchor.sh` | Runtime wrapper shipped in the package |
| `scripts/verify-qt-sdk.sh` | `Qt_6_PRIVATE_API` / exact-version check of a Qt SDK |
| `scripts/build-qt-sdk.sh` | Fallback: builds Qt 6.6.0 (qtbase, Core only) from the `v6.6.0` sources |
| `scripts/build-app.sh` | In-container configure/build/install of the app |
| `scripts/validate-package.sh` | Automated checks of an assembled package; shipped in the package as `validate.sh` |
| `packaging/README.runtime.md` | README template shipped inside the package |
| `squish-anchor-rhel9-x86_64.tar.gz` | The deployment archive (+ `.sha256`) |

## Requirements on the build host

- `podman` or `docker` (podman is preferred when both exist; override with `CONTAINER_TOOL`).
- Network access to pull the base image (`registry.access.redhat.com/ubi9/ubi` by default)
  and its package repositories, and to fetch Qt (see next section).
- `git` (only if Qt has to be built from source).

## The critical input: Qt 6.6.0 Linux GCC 64-bit SDK

The Squish Qt wrapper was built with Qt 6.6.0 and needs the `Qt_6_PRIVATE_API` symbol
version from *that* `libQt6Core.so.6`. The RHEL system Qt package is not used.
`build-rhel9.sh` obtains Qt 6.6.0 in one of three ways, in this order:

1. **`QT_ROOT` points at an official Qt 6.6.0 `gcc_64` SDK** (preferred). Install it with
   the Qt online installer, or without an account with aqtinstall:

   ```bash
   pip install aqtinstall
   aqt install-qt linux desktop 6.6.0 gcc_64 --outputdir /opt/Qt
   # SDK root: /opt/Qt/6.6.0/gcc_64
   QT_ROOT=/opt/Qt/6.6.0/gcc_64 ./build-rhel9.sh
   ```

2. **`qt-sdk/6.6.0/gcc_64` already exists** in this checkout (built by a previous run).

3. **Fallback: build Qt 6.6.0 from source.** The `v6.6.0` tag of `qtbase` is cloned into
   `qt-src/qtbase` (from `https://github.com/qt/qtbase.git`; override `QT_SOURCE_URL`, e.g.
   `https://code.qt.io/qt/qtbase.git`) and built *inside the RHEL 9 container with its GCC*
   into `qt-sdk/6.6.0/gcc_64` (`scripts/build-qt-sdk.sh`). Only Qt Core and the build tools
   are built (`-no-gui -no-widgets -no-dbus`, Network/Sql/Xml/Test/Concurrent disabled).
   The configuration matches the official binaries where it matters: shared release
   build, ICU and GLib enabled, pcre2 bundled; the resulting `libQt6Core.so.6` carries
   the same ELF symbol-version nodes (`Qt_6`, `Qt_6.0` … `Qt_6.6`, `Qt_6_PRIVATE_API`) and
   the same Qt export set as the official 6.6.0 library. zlib is additionally compiled in.
   This takes roughly 20–40 minutes on 4 cores.

Whichever path is used, the SDK is verified **before** the application is built
(`scripts/verify-qt-sdk.sh`) and again at CMake configure time:

```bash
readelf --version-info "$QT_ROOT/lib/libQt6Core.so.6" | grep Qt_6_PRIVATE_API
```

If `Qt_6_PRIVATE_API` is absent, or the SDK version is not exactly 6.6.0, the build stops
with an explicit error. It never substitutes Qt 6.6.1, 6.6.2, 6.7 or 6.8.

## Build

```bash
# with an official Qt 6.6.0 gcc_64 SDK on the host:
QT_ROOT=/opt/Qt/6.6.0/gcc_64 ./build-rhel9.sh

# or let the script build Qt 6.6.0 from the v6.6.0 sources:
./build-rhel9.sh
```

What it does:

1. `podman build -f Containerfile -t squish-anchor-builder:rhel9 .`
   (base image overridable: `BASE_IMAGE=docker.io/redhat/ubi9 ./build-rhel9.sh`, or any
   RHEL 9-compatible image such as `docker.io/oraclelinux:9`).
2. Selects / builds the Qt 6.6.0 SDK as described above.
3. `scripts/verify-qt-sdk.sh <QT_ROOT>` — aborts if `Qt_6_PRIVATE_API` is missing.
4. `cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=<QT_ROOT> -DCMAKE_INSTALL_PREFIX=dist`
   `cmake --build build && cmake --install build` → `dist/bin/squish-anchor`.

Useful environment variables: `CONTAINER_TOOL`, `BASE_IMAGE`, `IMAGE_TAG`, `QT_ROOT`,
`QT_SOURCE_URL`, `QT_TAG`, `JOBS`, `CONTAINER_NETWORK` (e.g. `host`), `BUILD_CA_BUNDLE`
(extra CA PEM for TLS-inspecting proxies; it is added to the image trust store),
`SKIP_IMAGE_BUILD=1`.

Building manually inside any RHEL 9 environment with the SDK present works too:

```bash
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_PREFIX_PATH=/opt/Qt/6.6.0/gcc_64 -DCMAKE_INSTALL_PREFIX="$PWD/dist"
cmake --build build --parallel && cmake --install build
```

## Package

```bash
./package-runtime.sh
```

Runs inside the builder image (it re-executes itself there) and produces:

```
squish-anchor-rhel9-x86_64/
├── bin/
│   └── squish-anchor
├── lib/
│   ├── libQt6Core.so.6 -> libQt6Core.so.6.6.0
│   ├── libQt6Core.so.6.6.0
│   ├── Qt runtime dependencies of libQt6Core (ICU libraries)
│   └── fallback/            libstdc++, libgcc_s, glib2, pcre copies (used only if the host lacks them)
├── run-squish-anchor.sh
├── validate.sh
└── README.md
squish-anchor-rhel9-x86_64.tar.gz
squish-anchor-rhel9-x86_64.tar.gz.sha256
```

Packaging rules implemented by `package-runtime.sh`:

- The dependency closure comes from `ldd bin/squish-anchor` (with the SDK on the search
  path). Everything is bundled **except** core RHEL 9 system libraries: `libc.so.6`,
  `libm.so.6`, `libpthread.so.0`, `libdl.so.2`, `librt.so.1`, `libstdc++.so.6`,
  `libgcc_s.so.1`, `ld-linux-x86-64.so.2`, `libz.so.1`, `libglib-2.0.so.0` and glib's own
  BaseOS dependencies (`libpcre2-8`, `libffi`, `libmount`, `libblkid`, `libselinux`, ...).
  With the official SDK this bundles `libQt6Core` and Qt's own `libicu*.so.56`; with the
  source-built SDK it bundles `libQt6Core` and RHEL's `libicu*.so.67` (AppStream, not
  guaranteed on a minimal host, therefore bundled). glib2 and its `libpcre.so.1` come from
  the host like glibc does.
- `lib/fallback/` holds copies of every host library the binary needs other than glibc
  itself (`libstdc++.so.6`, `libgcc_s.so.1`, `libglib-2.0.so.0`, `libgthread-2.0.so.0`,
  `libpcre.so.1`), listed in `lib/fallback/SONAMES`. They are **not** on the search path:
  the wrapper appends the directory only if the host lacks one of them, so core RHEL
  libraries are never relocated on a normal host, yet the package still starts on a
  stripped-down offline VM.
- `bin/squish-anchor` and the bundled `libQt6Core` are stripped (`--strip-unneeded`),
  like the official Qt binaries; SONAMEs, symbol versions and symlinks are unaffected.
- Real files are copied under their real names and the SONAME symlinks are recreated
  (`libQt6Core.so.6 -> libQt6Core.so.6.6.0`). SONAMEs are never changed.
- `bin/squish-anchor` carries `DT_RUNPATH = $ORIGIN/../lib`, set by CMake at link time
  (`-Wl,--enable-new-dtags`). The script checks it with `readelf -d` and only calls
  `patchelf --set-rpath` if the value is wrong. Bundled libraries get `RUNPATH $ORIGIN`
  (patchelf) so they find each other without the wrapper.
- `run-squish-anchor.sh` prepends `<package>/lib` to `LD_LIBRARY_PATH`, preserving any
  existing value, and `exec()`s `bin/squish-anchor` so the logged PID is the real PID.

## Validate

`package-runtime.sh` ends by running `validate.sh --strict` on the assembled package.
On the target VM run `./validate.sh` inside the unpacked directory: it needs only bash and
`ldd`, and skips the `file`/`readelf` presentations if those tools are not installed
(it still checks the ELF header, the `$ORIGIN/../lib` runtime path and the
`Qt_6_PRIVATE_API` version string directly from the files). To validate by hand:

```bash
tar -xzf squish-anchor-rhel9-x86_64.tar.gz
cd squish-anchor-rhel9-x86_64
file bin/squish-anchor
ldd bin/squish-anchor
readelf -d bin/squish-anchor
readelf --version-info lib/libQt6Core.so.6 | grep Qt_6_PRIVATE_API
./run-squish-anchor.sh --once
```

Expected: `ELF 64-bit LSB pie executable, x86-64 ... dynamically linked, interpreter
/lib64/ld-linux-x86-64.so.2`; `ldd` resolves `libQt6Core.so.6` from `./lib` and everything
else from `/lib64`, with nothing "not found"; `readelf -d` shows
`(RUNPATH) Library runpath: [$ORIGIN/../lib]` and no `libQt6Gui`/X11 `NEEDED` entries;
the `grep` prints the `Qt_6_PRIVATE_API` version definition; `--once` prints the
startup lines (PID, `qt runtime=6.6.0`) and exits 0.

Automated checks (`validate.sh`) additionally verify: no GUI/X11/Wayland libraries are
linked, no core RHEL libraries are in `lib/`, the bundled Qt Core reports 6.6.0, the
loaded Core library is the one from `lib/`, the binary also starts without the wrapper
(RUNPATH only), the logged PID equals the process PID, and `SIGTERM` and `SIGINT` both end
the process with exit status 0.

## Run (offline VM)

Copy only `squish-anchor-rhel9-x86_64.tar.gz` to the VM. Nothing else is required there.

```bash
tar -xzf squish-anchor-rhel9-x86_64.tar.gz -C /opt
/opt/squish-anchor-rhel9-x86_64/run-squish-anchor.sh          # foreground, until SIGTERM/SIGINT
/opt/squish-anchor-rhel9-x86_64/run-squish-anchor.sh --once   # smoke test
```

Example output:

```
2026-10-06T13:40:00.123 squish-anchor[4711]: started pid=4711 version=1.0.0
2026-10-06T13:40:00.123 squish-anchor[4711]: qt runtime=6.6.0 built-against=6.6.0 core-library=/opt/squish-anchor-rhel9-x86_64/lib/libQt6Core.so.6.6.0
2026-10-06T13:40:00.123 squish-anchor[4711]: running event loop until SIGTERM or SIGINT
```

Stop with `kill -TERM 4711`; the process logs `received SIGTERM, shutting down` and exits 0.
For Squish, attach to the logged PID (or start it through `startaut`): the process loads
exactly one Qt Core library, `lib/libQt6Core.so.6` (6.6.0, `Qt_6_PRIVATE_API` present).

## What was built and tested (provenance of the shipped archive)

The archive committed here was produced by exactly these scripts, with these inputs:

- **Qt 6.6.0**: the official Qt 6.6.0 `gcc_64` installer/aqt package could not be
  downloaded in the build environment used (download.qt.io and its mirrors were blocked),
  so Qt 6.6.0 was built from the `qtbase` **v6.6.0** tag (commit
  `33f5e985e480283bb0ca9dea5f82643e825ba87c`, `QT_REPO_MODULE_VERSION 6.6.0`) with the
  RHEL 9 GCC toolchain by `scripts/build-qt-sdk.sh`. No other Qt version was used or
  substituted. Its `libQt6Core.so.6` reports `Qt 6.6.0 (x86_64-little_endian-lp64 shared
  (dynamic) release build; by GCC 11.5.0 ...)`, exports `Qt_6_PRIVATE_API`, and was
  compared with the official Qt 6.6.0 `libQt6Core.so.6` (from the PySide6 6.6.0 wheel on
  PyPI): identical ELF version-definition nodes, the identical set of 883
  `Qt_6_PRIVATE_API` symbols, and every public `Qt_6*` symbol of the official library is
  present (the only official-only entries are libstdc++ `std::pmr` helpers that the RHEL 8
  toolchain build carries statically; ours additionally exports a few
  `QOperatingSystemVersion` constants that GCC 11 does not inline).
- **Build container**: Red Hat's registries were also blocked, so the builder image was
  built from `docker.io/oraclelinux:9` (Oracle Linux 9.8, a RHEL 9 binary-compatible
  rebuild: glibc 2.34, GCC 11.5.0, CMake 3.31.8, `Red Hat Enterprise Linux release 9.8
  (Plow)` in `/etc/redhat-release`) with `BASE_IMAGE=docker.io/oraclelinux:9`. The
  `Containerfile` defaults to `registry.access.redhat.com/ubi9/ubi` and works unchanged
  with it.
- **Validation**: `validate.sh --strict` passed (29/29) inside the builder. The archive was
  then unpacked and `validate.sh` run in a pristine, network-less `redhat/ubi9` (UBI 9.8)
  container with no `file`, `readelf` or ICU installed: all checks passed, including
  `--once`, direct execution via RUNPATH, and SIGTERM/SIGINT shutdown with exit status 0.
  The fallback path was exercised in `redhat/ubi9-micro`, which has neither libstdc++ nor
  glib2: the wrapper detected that, added `lib/fallback/`, and `--once` exited 0.
- **Not tested**: attachment with an actual Squish installation (not available here).
- Archive SHA-256: see `squish-anchor-rhel9-x86_64.tar.gz.sha256`.
