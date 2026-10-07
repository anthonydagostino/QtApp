# HeadlessQtApp

A self-contained Qt 6.8.0 widgets application for **RHEL 9 x86_64** that Squish for Qt
8.1.0 attaches to with `startaut`, on a machine **without a display and without installing
anything**. Put this folder on the file share and start the binary from the other VM.

```bash
/mnt/share/squish/bin/startaut --port=4322 /mnt/share/HeadlessQtApp/bin/HeadlessQtApp
/mnt/share/squish/bin/startaut --port=4322 /mnt/share/HeadlessQtApp/bin/HeadlessQtApp --xvfb
```

No scripts, no environment variables, no Qt, no packages and no network are needed on the
machine that runs it. The binary finds everything relative to itself. The only things used
from that machine are the kernel and glibc, and nothing in the tree needs more than
`GLIBC_2.34`, so it runs on **every RHEL 9 release from 9.0 GA on**.

**Do not set `LD_LIBRARY_PATH`** to `libs/lib64` for `startaut`: it is not needed (the
binary has an RPATH), and it would make Squish's own binaries load libraries from this
tree instead of the system ones.

## Layout

```
HeadlessQtApp/
├── bin/
│   ├── HeadlessQtApp            ELF x86_64, DT_RPATH $ORIGIN/../libs/lib64
│   └── qt.conf                  tells Qt where plugins/ and libs/lib64/fonts are
├── plugins/
│   ├── platforms/libqoffscreen.so  libqxcb.so  libqminimal.so
│   └── imageformats/libqjpeg.so  libqgif.so  libqico.so
├── libs/lib64/                  EVERY shared library except glibc, under its SONAME:
│   ├── libQt6Core.so.6  libQt6Gui.so.6  libQt6Widgets.so.6  libQt6Network.so.6
│   ├── libQt6Xml.so.6  libQt6Concurrent.so.6  libQt6PrintSupport.so.6
│   ├── libicui18n.so.67  libicuuc.so.67  libicudata.so.67
│   ├── libglib-2.0.so.0  libgthread-2.0.so.0  libpcre.so.1
│   ├── libstdc++.so.6  libgcc_s.so.1
│   ├── libxcb*.so  libX11.so.6  libxkbcommon*.so  libXfont2  libpixman ...  (xcb + Xvfb)
│   ├── fonts/DejaVuSans*.ttf    fonts for rendering without fontconfig
│   └── MANIFEST.txt             where every file came from
├── xvfb/
│   ├── Xvfb, xkbcomp            virtual X server for --xvfb mode
│   └── xkb/                     XKB keyboard data
├── main.cpp, CMakeLists.txt     the application source
└── README.md
```

No symlinks anywhere, so the tree survives an SMB/Windows share. The share must be
mounted on the running machine so that files on it are executable (not `noexec`, and with
the executable bit visible, e.g. CIFS `file_mode=0755`): `startaut` executes
`bin/HeadlessQtApp` directly.

## What the application does

- `QApplication` with a real widget tree that Squish can find, drive and screenshot:
  `mainWindow`, `centralWidget`, `titleLabel`, `statusLabel`, `inputLineEdit`,
  `counterLabel`, `clickButton`, `quitButton`.
- Two ways to run without a display:
  - **offscreen** (default): Qt's offscreen platform plugin, no X server at all;
  - **`--xvfb`**: the application itself starts the bundled Xvfb on a free display
    (`:99` upwards), runs on the **xcb** platform against it, and stops Xvfb when it exits.
    This gives Squish a real X display, which is what its desktop screenshots on Linux
    normally expect. Needs a writable `/tmp` (X socket, lock file, Xvfb log).
- Logs its startup, PID, platform and screens to stdout; runs the event loop until
  `SIGTERM`/`SIGINT` and exits 0.
- Options: `--once` (log startup, exit 0), `--screenshot <png>` (render the window),
  `--desktop-screenshot <png>` (grab the primary `QScreen`, exactly what Squish's
  `desktopImage` does), `--core-only` (plain `QCoreApplication`, nothing to screenshot),
  `--help`, `--version`.
- Built against **exactly Qt 6.8.0**, whose `libQt6Core.so.6` exports `Qt_6_PRIVATE_API`
  (required by the Squish Qt wrapper built with Qt 6.8.0). The build refuses any other Qt.
- The binary links all shipped Qt modules with `--no-as-needed` and carries a `DT_RPATH`
  (not `RUNPATH`): the RPATH is inherited by every library loaded into the process, so the
  Squish wrapper that `startaut` preloads resolves its Qt dependencies from `libs/lib64`
  as well, with no `LD_LIBRARY_PATH`.

Example output:

```
2026-10-06T14:00:00.123 HeadlessQtApp[4711]: started pid=4711 version=1.0.0 mode=widgets/xvfb exe=/mnt/share/HeadlessQtApp/bin/HeadlessQtApp
2026-10-06T14:00:00.124 HeadlessQtApp[4711]: qt runtime=6.8.0 built-against=6.8.0 core-library=/mnt/share/HeadlessQtApp/libs/lib64/libQt6Core.so.6
2026-10-06T14:00:00.124 HeadlessQtApp[4711]: xvfb pid=4712 DISPLAY=:99 log=/tmp/HeadlessQtApp-xvfb-4711-99.log
2026-10-06T14:00:00.180 HeadlessQtApp[4711]: qpa platform=xcb plugin-paths=/mnt/share/HeadlessQtApp/plugins:...
2026-10-06T14:00:00.181 HeadlessQtApp[4711]: screens=1 primary=screen 1280x1024
2026-10-06T14:00:00.190 HeadlessQtApp[4711]: main window 'mainWindow' shown (640x400)
2026-10-06T14:00:00.190 HeadlessQtApp[4711]: running event loop until SIGTERM or SIGINT
```

## Squish screenshots

Squish's desktop screenshot (`Wrapper::desktopImage`) grabs the primary `QScreen`. If
Squish reports `Cannot take screenshot without a primary QScreen`:

1. Look at the AUT's own stdout: it must say `mode=widgets/...` (not `core-only`) and
   `screens=1 primary=...`.
2. `bin/HeadlessQtApp --desktop-screenshot /tmp/d.png` performs the same grab without
   Squish; it works on the offscreen platform in our tests.
3. If Squish still refuses the offscreen screen, start the AUT with `--xvfb`: a real X
   display on the xcb platform, the normal situation for Squish screenshots on Linux.

One harmless line may appear on stderr with the offscreen platform:
`This plugin does not support propagateSizeHints()`.

## Checking by hand on the running machine

```bash
cd /mnt/share/HeadlessQtApp
bin/HeadlessQtApp --once
bin/HeadlessQtApp --xvfb --desktop-screenshot /tmp/d.png
ldd bin/HeadlessQtApp                       # everything from libs/lib64 except glibc
readelf -d bin/HeadlessQtApp                # (RPATH) $ORIGIN/../libs/lib64  (binutils, if installed)
readelf --version-info libs/lib64/libQt6Core.so.6 | grep Qt_6_PRIVATE_API
```

## Rebuilding

Only `main.cpp` and `CMakeLists.txt` are needed to rebuild; the tooling that produced the
binaries (a RHEL 9 container with the Qt 6.8.0 SDK) is not part of this repository. In any
RHEL 9 environment with a Qt 6.8.0 `gcc_64` SDK and `cmake`/`g++`:

```bash
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_PREFIX_PATH=/opt/Qt/6.8.0/gcc_64 -DCMAKE_INSTALL_PREFIX="$PWD/dist"
cmake --build build --parallel && cmake --install build      # -> dist/bin/HeadlessQtApp
```

Configure stops if the SDK is not exactly 6.8.0 or its `libQt6Core.so.6` lacks
`Qt_6_PRIVATE_API` (`readelf --version-info "$QT_ROOT/lib/libQt6Core.so.6" | grep Qt_6_PRIVATE_API`).
Then copy the binary to `bin/`, keep `bin/qt.conf`, and put the Qt libraries and plugins
next to it as in the layout above (real files named by SONAME, RPATH `$ORIGIN` on the
libraries, `$ORIGIN/../../libs/lib64` on the plugins, `$ORIGIN/../libs/lib64` on the
binary and on `xvfb/Xvfb`).

## What was built and tested

- **Qt 6.8.0** was built from the `qtbase` **v6.8.0** tag (commit
  `b839e9b36db3a4e50dfb34521d8ef8de1fd01969`) with the RHEL 9 GCC 11.5 toolchain (the
  official 6.8.0 installer was unreachable from the build environment; no other Qt version
  was substituted). Modules: Core, Gui, Widgets, Network, Xml, Concurrent, PrintSupport;
  platforms offscreen, xcb, minimal; ICU, GLib and zstd enabled, freetype/harfbuzz/png/jpeg/
  zlib/pcre2 compiled in, no fontconfig/OpenGL/DBus. Its `libQt6Core.so.6` exports
  `Qt_6_PRIVATE_API` and `Qt_6.8` with the same ELF version nodes as the official Qt 6.8.0
  library (compared against the PySide6 6.8.0 wheel) and a strict superset of its exported
  Qt symbols (every official export is present; private API 1070 vs 1067).
- Built in an Oracle Linux 9.8 container (RHEL 9 binary compatible; glibc 2.34, GCC
  11.5.0). Xvfb, xkbcomp, the XKB data, ICU, glib2 and the X libraries are the RHEL 9
  (el9) packages, see `libs/lib64/MANIFEST.txt`. Xvfb's compiled-in `/usr/bin` xkbcomp
  directory is patched to `.` so it runs the bundled `xvfb/xkbcomp`.
- **glibc compatibility.** Later RHEL 9.x releases backport new glibc symbol versions
  (`_dl_find_object@GLIBC_2.35`, used by libgcc builds from 9.2 on), which produce
  `version 'GLIBC_2.35' not found` on an older 9.x. Every file in this tree is checked to
  require at most `GLIBC_2.34`; `libgcc_s.so.1` is therefore the RHEL 9.0 GA build
  (`libgcc-11.2.1-9.4.0.2.el9`, Oracle Linux 9.0 GA = RHEL 9.0 baseline).
- Build-side validation (67 checks) passed: RPATH, every library/plugin/Xvfb resolving
  without `LD_LIBRARY_PATH`, `--once`, `--screenshot`, `--desktop-screenshot` on offscreen
  and on `--xvfb` (xcb, 1280x1024 primary screen), `--core-only`, SIGTERM/SIGINT in both
  modes with Xvfb stopped and no X socket or lock left behind.
- The tree was mounted **read-only into pristine, network-less containers** with no X, ICU,
  fonts, `file` or `readelf` installed, and the binary was started directly with no
  environment: **`redhat/ubi9:9.0.0-1576` (RHEL 9.0 GA, glibc 2.34-28, no `GLIBC_2.35`)**,
  `redhat/ubi9` (9.8) and `redhat/ubi9-micro` (no libstdc++, no glib2). On each: `--once`
  (offscreen, `screens=1`), `--desktop-screenshot` (offscreen), `--xvfb
  --desktop-screenshot` (xcb on the bundled Xvfb, empty Xvfb log, PNG of the 1280x1024
  screen showing the window) and SIGTERM in `--xvfb` mode (exit 0, no Xvfb process left)
  passed; on 9.0 GA also with `LD_LIBRARY_PATH` pointed at `libs/lib64`.
- **Not tested**: attaching Squish for Qt 8.1.0 (not available here). In your earlier run
  Squish attached successfully; the remaining question is only which platform its
  `desktopImage` accepts, hence `--xvfb`.
