# headlessQtApp

A self-contained Qt 6.6.0 application tree for **RHEL 9 x86_64** that Squish for Qt 8.1.0
can attach to (`startaut`), inspect and screenshot on a machine **without a display and
without installing anything**. Put this folder on the file share; run it from the other VM.

- `QApplication` with a real widget tree (a main window with labels, a line edit and
  buttons) that Squish can find, drive and screenshot. Two ways to run without a display:
  - **offscreen** (default): Qt's offscreen platform plugin, no X server at all;
  - **`--xvfb`**: the bundled virtual X server (Xvfb) is started on a free display and the
    application runs on the **xcb** platform against it. This gives Squish a real X
    display, which is what its desktop screenshots on Linux normally expect.
  `--core-only` runs it as a plain `QCoreApplication` instead (nothing to screenshot).
- Built against **exactly Qt 6.6.0** whose `libQt6Core.so.6` exports `Qt_6_PRIVATE_API`
  (required by the Squish Qt wrapper built with Qt 6.6.0). The build refuses any other Qt.
- Logs its startup, PID and screens to stdout, runs until `SIGTERM`/`SIGINT` (exit 0),
  supports `--once`, `--screenshot <file>` and `--desktop-screenshot <file>`.
- **Everything except glibc is in the tree.** No symlinks, so it survives SMB shares.

## Layout (this folder is what goes on the share)

```
headlessQtApp/
├── bin/
│   ├── headlessQtApp            ELF x86_64, RUNPATH $ORIGIN/../libs/lib64
│   └── qt.conf                  tells Qt where plugins/ and libs/lib64/fonts are
├── plugins/
│   ├── platforms/libqoffscreen.so  libqxcb.so  libqminimal.so
│   └── imageformats/*.so
├── xvfb/
│   ├── Xvfb, xkbcomp                virtual X server for --xvfb mode
│   └── xkb/                         XKB keyboard data
├── libs/lib64/                  EVERY shared library except glibc, named by SONAME:
│   ├── libQt6Core.so.6  libQt6Gui.so.6  libQt6Widgets.so.6  libQt6Network.so.6
│   ├── libQt6Xml.so.6  libQt6Concurrent.so.6  libQt6PrintSupport.so.6
│   ├── libicui18n.so.67  libicuuc.so.67  libicudata.so.67
│   ├── libglib-2.0.so.0  libgthread-2.0.so.0  libpcre.so.1
│   ├── libstdc++.so.6  libgcc_s.so.1
│   ├── libxcb*.so  libX11.so.6  libxkbcommon*.so  libXfont2, libpixman ... (xcb plugin + Xvfb)
│   ├── fonts/DejaVuSans*.ttf    fonts for offscreen rendering (no fontconfig needed)
│   └── MANIFEST.txt             where every file came from
├── run-headlessQtApp.sh         the entry point (use this as the AUT for startaut)
├── validate.sh                  self-check on the target machine (needs only bash + ldd)
├── check-deps.sh                lists missing libraries for this tree and for a Squish install
├── src/main.cpp, CMakeLists.txt the application source
└── tools/                       build tooling (containers); NOT needed on either VM
```

The only things used from the machine that runs it are the kernel and glibc
(`/lib64/ld-linux-x86-64.so.2`, `libc`, `libm`, `libdl`, `libpthread`, `librt`), which
every RHEL 9 system has.

## Running it on VM2 from the share

Nothing is installed on VM2. The share must be mounted so that files on it may be
executed (not `noexec`); the executable bit itself is not required, the wrapper starts the
binary through the system loader if it is missing.

```bash
cd /mnt/share/headlessQtApp
./run-headlessQtApp.sh                 # offscreen platform, runs until SIGTERM/SIGINT
./run-headlessQtApp.sh --xvfb          # bundled Xvfb + xcb platform, runs until SIGTERM/SIGINT
./run-headlessQtApp.sh --once          # logs startup, exits 0
./run-headlessQtApp.sh --screenshot /tmp/shot.png          # QWidget::grab() of the window -> PNG
./run-headlessQtApp.sh --desktop-screenshot /tmp/desk.png  # QScreen::grabWindow(0), what Squish does
./run-headlessQtApp.sh --xvfb --desktop-screenshot /tmp/desk.png
./run-headlessQtApp.sh --core-only     # QCoreApplication only (nothing to screenshot)
./validate.sh                          # automated checks
./check-deps.sh /mnt/share/squish      # also checks a Squish installation's binaries
```

Example output:

```
2026-10-06T14:00:00.123 headlessQtApp[4711]: started pid=4711 version=1.0.0 mode=widgets/offscreen
2026-10-06T14:00:00.124 headlessQtApp[4711]: qt runtime=6.6.0 built-against=6.6.0 core-library=/mnt/share/headlessQtApp/libs/lib64/libQt6Core.so.6
2026-10-06T14:00:00.130 headlessQtApp[4711]: qpa platform=offscreen plugin-paths=/mnt/share/headlessQtApp/plugins:...
2026-10-06T14:00:00.131 headlessQtApp[4711]: screens=1 primary= 800x800
2026-10-06T14:00:00.140 headlessQtApp[4711]: main window 'mainWindow' shown (640x400)
2026-10-06T14:00:00.140 headlessQtApp[4711]: running event loop until SIGTERM or SIGINT
```

The wrapper `exec()`s the binary, so the PID it logs is the PID of the AUT.

### With Squish for Qt 8.1.0

The wrapper sets `LD_LIBRARY_PATH`, `QT_PLUGIN_PATH`, `QT_QPA_PLATFORM=offscreen` and
`QT_QPA_FONTDIR` and then exec()s the binary, so register the **wrapper script** as the AUT:

```bash
# on VM2 (Squish itself lives on the share too)
/mnt/share/squish/bin/squishserver --config addAUT headlessQtApp /mnt/share/headlessQtApp   # AUT name -> run-headlessQtApp.sh
/mnt/share/squish/bin/startaut --port=4322 /mnt/share/headlessQtApp/run-headlessQtApp.sh
```

`startaut` injects the Squish Qt wrapper into the process; the wrapper finds the matching
Qt 6.6.0 libraries in `libs/lib64` through `LD_LIBRARY_PATH`. Objects are named
`mainWindow`, `centralWidget`, `titleLabel`, `statusLabel`, `inputLineEdit`,
`counterLabel`, `clickButton`, `quitButton`.

**Screenshots.** Squish's desktop screenshot (`Wrapper::desktopImage`) grabs the primary
`QScreen`. If Squish reports `Cannot take screenshot without a primary QScreen`, first look at
the AUT's own stdout: it must say `mode=widgets/offscreen` (not `core-only`) and
`screens=1 primary=...`. `./run-headlessQtApp.sh --desktop-screenshot /tmp/d.png` performs
exactly that grab without Squish. If Squish still refuses the offscreen screen, start the
AUT with `--xvfb`: the bundled Xvfb gives it a real X display (`qpa platform=xcb`), the
normal situation for Squish screenshots on Linux:

```bash
/mnt/share/squish/bin/startaut --port=4322 /mnt/share/headlessQtApp/run-headlessQtApp.sh --xvfb
```

`--xvfb` needs a writable `/tmp` on VM2 (the X socket and lock file live there); display
numbers `:99` and up are tried. The wrapper stays alive as the parent of Xvfb and the AUT
in this mode (the AUT's PID is the one it logs) and stops Xvfb when the AUT exits.

Before the first Squish run, run `./check-deps.sh /mnt/share/squish` on VM2: it prints any
library that Squish's own binaries would need from VM2 and cannot find. (Squish for Qt is
not available in the environment this tree was built in, so that part could not be tried
here; see "What was tested".)

## Rebuilding (only needed if you change `src/main.cpp`)

This needs a machine with podman or docker and network access; it is never done on VM1/VM2.

```bash
tools/build-rhel9.sh      # builder image (UBI 9 / RHEL 9 compatible), Qt 6.6.0, the app
tools/package.sh          # lays out bin/ plugins/ libs/lib64/ here and runs validate.sh --strict
```

`tools/build-rhel9.sh` takes the Qt 6.6.0 SDK from `QT_ROOT=/path/to/Qt/6.6.0/gcc_64` if
you have the official installer/aqt package, or otherwise builds Qt 6.6.0 from the `v6.6.0`
qtbase sources (Core, Gui, Widgets, Network, Xml, Concurrent, PrintSupport, offscreen
plugin; bundled freetype/harfbuzz/png/jpeg/zlib/pcre2, ICU and GLib enabled, no
X11/OpenGL/DBus/fontconfig). Either way the SDK is checked first:

```bash
readelf --version-info "$QT_ROOT/lib/libQt6Core.so.6" | grep Qt_6_PRIVATE_API
```

and the build stops if `Qt_6_PRIVATE_API` is absent or the version is not exactly 6.6.0.
Variables: `CONTAINER_TOOL`, `BASE_IMAGE` (default `registry.access.redhat.com/ubi9/ubi`),
`QT_ROOT`, `QT_SOURCE_URL`, `JOBS`, `CONTAINER_NETWORK`, `BUILD_CA_BUNDLE`, `SKIP_IMAGE_BUILD`.

## Validation by hand

```bash
file bin/headlessQtApp
LD_LIBRARY_PATH=$PWD/libs/lib64 ldd bin/headlessQtApp
readelf -d bin/headlessQtApp
readelf --version-info libs/lib64/libQt6Core.so.6 | grep Qt_6_PRIVATE_API
./run-headlessQtApp.sh --once
```

`file` and `readelf` are not part of a minimal RHEL 9; `validate.sh` does the equivalent
checks without them.

## What was tested

The binaries committed here were produced by `tools/build-rhel9.sh` + `tools/package.sh`
with these inputs, and checked as follows:

- **Qt 6.6.0** was built from the `qtbase` **v6.6.0** tag (commit
  `33f5e985e480283bb0ca9dea5f82643e825ba87c`) with the RHEL 9 GCC 11.5 toolchain, because
  the official Qt 6.6.0 installer/aqt package could not be downloaded in the build
  environment (download.qt.io and its mirrors were blocked). No other Qt version was
  substituted. The resulting `libQt6Core.so.6` reports `Qt 6.6.0 (x86_64-little_endian-lp64
  shared (dynamic) release build; by GCC 11.5.0)` and exports `Qt_6_PRIVATE_API`; compared
  with the official Qt 6.6.0 `libQt6Core.so.6` (PySide6 6.6.0 wheel) it has identical ELF
  version nodes and the identical set of 883 `Qt_6_PRIVATE_API` symbols.
- **Build container**: Red Hat's registries were blocked too, so the builder image was made
  from `docker.io/oraclelinux:9` (Oracle Linux 9.8, RHEL 9 binary compatible: glibc 2.34,
  GCC 11.5.0; `/etc/redhat-release` reads "Red Hat Enterprise Linux release 9.8 (Plow)").
  `tools/Containerfile` defaults to `registry.access.redhat.com/ubi9/ubi` and works with it.
- `validate.sh --strict` inside the builder: 40/40 passed.
- The tree was mounted **read-only, with every executable bit removed, into a pristine
  network-less `redhat/ubi9` (UBI 9.8) container** with no `file`, `readelf`, ICU, glib
  or fonts installed, simulating VM2 reading the share: `bash validate.sh` passed 39/39
  (3 presentational checks skipped for the missing tools). That covers `--once`,
  `--screenshot` (a 640x400 PNG with rendered text), `--core-only`, starting the binary
  through the dynamic loader without exec bits, and SIGTERM/SIGINT shutdown with exit 0.
- `redhat/ubi9-micro` (no libstdc++, no glib2 at all): `--once` and `--screenshot` exit 0.
- **Not tested**: attaching Squish for Qt 8.1.0 (not available here). `check-deps.sh
  /path/to/squish` on VM2 will list anything Squish's own binaries still need from VM2.

One harmless line may appear on stderr with the offscreen platform:
`This plugin does not support propagateSizeHints()`.
