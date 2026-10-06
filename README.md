# headlessQtApp

A self-contained Qt 6.6.0 application tree for **RHEL 9 x86_64** that Squish for Qt 8.1.0
can attach to (`startaut`), inspect and screenshot on a machine **without a display and
without installing anything**. Put this folder on the file share; run it from the other VM.

- `QApplication` on Qt's **offscreen** platform plugin: real widgets exist (a main window
  with labels, a line edit and buttons), Squish can find them and take screenshots, but no
  X11, Wayland, OpenGL or display is involved. `--core-only` runs it as a plain
  `QCoreApplication` instead.
- Built against **exactly Qt 6.6.0** whose `libQt6Core.so.6` exports `Qt_6_PRIVATE_API`
  (required by the Squish Qt wrapper built with Qt 6.6.0). The build refuses any other Qt.
- Logs its startup and PID to stdout, runs until `SIGTERM`/`SIGINT` (exit 0), supports
  `--once` and `--screenshot <file>`.
- **Everything except glibc is in the tree.** No symlinks, so it survives SMB shares.

## Layout (this folder is what goes on the share)

```
headlessQtApp/
├── bin/
│   ├── headlessQtApp            ELF x86_64, RUNPATH $ORIGIN/../libs/lib64
│   └── qt.conf                  tells Qt where plugins/ and libs/lib64/fonts are
├── plugins/
│   ├── platforms/libqoffscreen.so   (+ libqminimal.so)
│   └── imageformats/*.so
├── libs/lib64/                  EVERY shared library except glibc, named by SONAME:
│   ├── libQt6Core.so.6  libQt6Gui.so.6  libQt6Widgets.so.6  libQt6Network.so.6
│   ├── libQt6Xml.so.6  libQt6Concurrent.so.6  libQt6PrintSupport.so.6
│   ├── libicui18n.so.67  libicuuc.so.67  libicudata.so.67
│   ├── libglib-2.0.so.0  libgthread-2.0.so.0  libpcre.so.1
│   ├── libstdc++.so.6  libgcc_s.so.1
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
./run-headlessQtApp.sh                 # runs until SIGTERM/SIGINT
./run-headlessQtApp.sh --once          # logs startup, exits 0
./run-headlessQtApp.sh --screenshot /tmp/shot.png   # renders the window to a PNG, exits 0
./run-headlessQtApp.sh --core-only     # QCoreApplication only (nothing to screenshot)
./validate.sh                          # automated checks
./check-deps.sh /mnt/share/squish      # also checks a Squish installation's binaries
```

Example output:

```
2026-10-06T14:00:00.123 headlessQtApp[4711]: started pid=4711 version=1.0.0 mode=widgets/offscreen
2026-10-06T14:00:00.124 headlessQtApp[4711]: qt runtime=6.6.0 built-against=6.6.0 core-library=/mnt/share/headlessQtApp/libs/lib64/libQt6Core.so.6
2026-10-06T14:00:00.130 headlessQtApp[4711]: qpa platform=offscreen plugin-paths=/mnt/share/headlessQtApp/plugins:...
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
`counterLabel`, `clickButton`, `quitButton`. Screenshots work through Qt's own grabbing
on the offscreen platform (`--screenshot` proves that path without Squish).

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
