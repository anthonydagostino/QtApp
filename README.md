# HeadlessQtApp

Everything in one place: the **ready-to-use tree** (`bin/`, `plugins/`, `libs/`) and the
**sources and build script** to rebuild it on RHEL 9.

`HeadlessQtApp` is a minimal Qt 6.8.0 anchor process for **Squish for Qt 8.1.0** on
**RHEL 9 x86_64**. It has no GUI and creates no window; it connects to the machine's own X
display so that, once Squish is attached (`startaut`), Squish's desktop screenshots show
that display and image-based interaction works on it.

## Use it (nothing to build)

```bash
git clone -b build <repo-url> HeadlessQtApp
```

Copy `bin/`, `plugins/` and `libs/` to the share, then on the VM:

```bash
/mnt/share/squish/bin/startaut --port=4322 /mnt/share/HeadlessQtApp/bin/HeadlessQtApp
```

`bin/` contains six executables, each compiled separately from `main.cpp` with its own
name baked in: `HeadlessQtApp`, `HeadlessQtAppA1`, `HeadlessQtAppA2`, `HeadlessQtAppAb`,
`HeadlessQtAppRo`, `HeadlessQtAppPr`. Each is its own attachable AUT for Squish (own
`startaut` port, own `addAttachableAUT` entry). All names are 15 characters or fewer:
Linux truncates the process name (`ps`, `/proc/<pid>/comm`) to 15 characters and Squish
looks the AUT process up by that name, so a longer name runs but cannot be attached to
(the build refuses longer names).

Nothing is installed on the VM, no environment variables are needed, and the only things
used from it are the kernel, glibc and the X server; every file in the tree needs at most
`GLIBC_2.34`, so it runs on every RHEL 9 release. Do not set `LD_LIBRARY_PATH`. The share
must be mounted so files on it are executable.

Each executable prints one line and then runs until killed:
`HeadlessQtAppA1 pid=... qt=6.8.0 platform=xcb display=:0 screen=... WxH`.
Environment it reacts to: `DISPLAY` (default `:0`), `XAUTHORITY` (if the X server needs a
cookie), `QT_QPA_PLATFORM=offscreen` (run with no display at all).

## Rebuild it

Needs `gcc-c++ cmake make binutils` from the RHEL repositories (on an unregistered system
with ISO repos: `sudo dnf --disablerepo=Local-CRB install ...`). Work on a local disk, not
on a VirtualBox/SMB shared folder.

```bash
cd HeadlessQtApp
./build.sh            # rebuilds bin/ plugins/ libs/lib64/ in place
./build.sh clean      # removes the outputs
```

To change the executable names, edit the list near the top of `build.sh`:

```bash
APP_NAMES=(HeadlessQtApp HeadlessQtAppA1 HeadlessQtAppA2 HeadlessQtAppAb HeadlessQtAppRo HeadlessQtAppPr)
```

Without a compiler, `build.sh` uses the prebuilt binaries in `support/prebuilt/` (one per
default name) and only lays out the tree; without binutils it skips stripping and the
symbol-version checks.

## Layout

```
HeadlessQtApp/
├── bin/                     the six executables + qt.conf            (output, committed)
├── plugins/                 Qt platform (xcb, offscreen, minimal) and imageformat plugins (output)
├── libs/lib64/              every shared library except glibc, named by SONAME (output)
├── main.cpp, CMakeLists.txt the application
├── build.sh                 builds the executables and lays out the tree
├── qt/6.8.0/gcc_64/         Qt 6.8.0 SDK (headers, libraries, CMake files, moc/rcc/uic, plugins)
└── support/
    ├── runtime-libs/lib64/  the non-Qt libraries shipped in libs/lib64 (ICU, glib2, pcre, zstd,
    │                        X11/xcb/xkbcommon, libstdc++, libgcc_s from RHEL 9.0 GA); ORIGINS.txt
    ├── prebuilt/            fallback binaries for machines without a compiler
    ├── patchelf             patchelf 0.15 (not in the RHEL repositories)
    └── qt.conf              copied next to the binaries
```

No symlinks anywhere (survives SMB/VirtualBox shares).

## What build.sh does

1. Checks for `cmake`, `g++`, `make` (else uses `support/prebuilt/`) and `readelf`/`strip`.
2. Verifies the Qt SDK is exactly 6.8.0 and its `libQt6Core.so.6` exports `Qt_6_PRIVATE_API`
   and `Qt_6.8` (what Squish for Qt 8.1.0, built with Qt 6.8.0, requires).
3. `cmake` configure/build/install: one target per name in `APP_NAMES`, each with
   `HEADLESSQTAPP_NAME` compiled in; names over 15 characters are rejected.
4. Lays out the tree: the executables, `qt.conf`, the plugins, every Qt library under its
   SONAME as a real file, the runtime libraries from `support/runtime-libs`.
5. Sets `DT_RPATH` with `patchelf` (`$ORIGIN/../libs/lib64` on the binaries,
   `$ORIGIN/../../libs/lib64` on the plugins, `$ORIGIN` on the libraries) and strips.
6. Checks: no file needs a glibc symbol newer than `GLIBC_2.34`, everything resolves with
   `ldd` without `LD_LIBRARY_PATH`, RPATH set; then a smoke test of the first executable.

## Notes

- The Qt 6.8.0 SDK was built from the `qtbase` v6.8.0 sources with GCC 11.5 on a RHEL 9
  compatible system (Core, Gui, Widgets, Network, Xml, Concurrent, PrintSupport; xcb/
  offscreen/minimal platforms; ICU, GLib, zstd; bundled freetype/harfbuzz/png/jpeg/zlib/
  pcre2; no OpenGL/DBus/fontconfig). Its `libQt6Core.so.6` has the same ELF version nodes
  as the official Qt 6.8.0 library and a superset of its exported symbols.
- The binaries link every shipped Qt module with `--no-as-needed` and carry a `DT_RPATH`
  that is inherited by everything loaded into the process, so the Squish wrapper that
  `startaut` preloads resolves its Qt 6.8.0 libraries from `libs/lib64`.
- `libgcc_s.so.1` is the RHEL 9.0 GA build: newer builds need `_dl_find_object@GLIBC_2.35`,
  which older RHEL 9.x do not have.
