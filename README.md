# HeadlessQtApp — build branch

This branch builds the `HeadlessQtApp` tree from source on **RHEL 9 (tested with the 9.8
toolchain)**. The ready-built tree is on branch `claude/new-session-6jr4li`; this branch
produces the same thing and contains everything needed to do so, except the compiler
toolchain from the RHEL repositories.

```bash
sudo dnf install gcc-c++ cmake make binutils     # the only packages needed
git clone -b build <repo-url> HeadlessQtApp
cd HeadlessQtApp
./build.sh
```

Result: `bin/`, `plugins/` and `libs/lib64/` in this directory, the deployable tree. Copy
those three folders to the share and start it with Squish:

```bash
/mnt/share/squish/bin/startaut --port=4322 /mnt/share/HeadlessQtApp/bin/HeadlessQtApp
```

## What is in this branch

| Path | Content |
| --- | --- |
| `main.cpp`, `CMakeLists.txt` | the application (QGuiApplication on xcb, no window; see below) |
| `build.sh` | builds the app and lays out the tree; checks the Qt SDK and the result |
| `qt/6.8.0/gcc_64/` | the Qt 6.8.0 SDK: headers, libraries, CMake files, `moc`/`rcc`/`uic`, plugins (72 MB) |
| `support/runtime-libs/lib64/` | the non-Qt libraries shipped in `libs/lib64` (ICU 67, glib2, pcre, zstd, X11/xcb/xkbcommon, libstdc++, `libgcc_s` from RHEL 9.0 GA); `ORIGINS.txt` names the RPMs |
| `support/patchelf` | patchelf 0.15 (EPEL build; not in the RHEL repositories), used to set RPATHs |
| `support/qt.conf` | copied next to the binary so Qt finds `plugins/` |

No network is needed by `build.sh`. No container is involved.

## What build.sh does

1. Checks for `cmake`, `g++`, `make`, `readelf`, `strip`, `ldd`.
2. Verifies the Qt SDK is exactly 6.8.0 and that its `libQt6Core.so.6` exports the
   `Qt_6_PRIVATE_API` and `Qt_6.8` symbol versions (what Squish for Qt 8.1.0, built with
   Qt 6.8.0, requires). `CMakeLists.txt` checks the same at configure time.
3. `cmake` configure/build/install into `build/` and `dist/`.
4. Lays out the tree: six byte-identical copies of the binary (`HeadlessQtApp`,
   `HeadlessQtApp2` … `HeadlessQtApp6`), `qt.conf`, the xcb/offscreen/minimal platform
   plugins and image-format plugins, every Qt library under its SONAME as a real file, the
   runtime libraries from `support/runtime-libs`. No symlinks.
5. Sets `DT_RPATH` with `patchelf` (`$ORIGIN/../libs/lib64` on the binaries,
   `$ORIGIN/../../libs/lib64` on the plugins, `$ORIGIN` on the libraries) and strips.
6. Checks: no file needs a glibc symbol newer than `GLIBC_2.34` (so the tree runs on every
   RHEL 9.x), every file resolves with `ldd` without `LD_LIBRARY_PATH`, RPATH set; then a
   smoke test (starts on the offscreen platform, prints its line, stops on SIGTERM).

## The application

`main.cpp`: a `QGuiApplication` on Qt's xcb platform that connects to the machine's own X
display (`DISPLAY`, default `:0`), prints one line
(`HeadlessQtApp pid=... qt=6.8.0 platform=xcb display=:0 screen=... WxH`, with the name it
was started as) and runs the event loop until it is killed. No window. Squish attaches to it
with `startaut`; its desktop screenshots then show the real display.

Environment it reacts to: `DISPLAY` (default `:0`), `XAUTHORITY` (if the X server needs a
cookie), `QT_QPA_PLATFORM=offscreen` (no display at all). Do not set `LD_LIBRARY_PATH`.

## Notes

- The Qt 6.8.0 SDK here was built from the `qtbase` v6.8.0 sources with GCC 11.5 on a
  RHEL 9-compatible system (Core, Gui, Widgets, Network, Xml, Concurrent, PrintSupport;
  xcb/offscreen/minimal platforms; ICU, GLib, zstd; bundled freetype/harfbuzz/png/jpeg/
  zlib/pcre2; no OpenGL/DBus/fontconfig). Its `libQt6Core.so.6` has the same ELF version
  nodes as the official Qt 6.8.0 library and a superset of its exported symbols.
- The runtime libraries are the RHEL 9 (el9) packages' files, except `libgcc_s.so.1`,
  which is the RHEL 9.0 GA build: newer builds need `_dl_find_object@GLIBC_2.35`, which
  older RHEL 9.x do not have.
- A binary built on RHEL 9.8 with its GCC 11.5 links against the shipped `libstdc++`
  (GLIBCXX 3.4.29) and needs nothing newer than `GLIBC_2.34`; `build.sh` verifies this.
