# HeadlessQtApp

A minimal Qt 6.8.0 anchor process for **Squish for Qt 8.1.0** on **RHEL 9 x86_64**. It has
no GUI and creates no window. Its only job is to be the AUT that Squish attaches to on a
machine where nothing can be installed, so that Squish can take desktop screenshots of
that machine's own display and do image-based interaction on it.

```bash
/mnt/share/squish/bin/startaut --port=4322 /mnt/share/HeadlessQtApp/bin/HeadlessQtApp
```

The whole application (`main.cpp`):

- connects to the machine's X display through Qt's xcb platform plugin (`DISPLAY`,
  default `:0`),
- prints one line (`HeadlessQtApp pid=... qt=6.8.0 platform=xcb display=:0 screen=... WxH`,
  with the name it was started as),
- runs the Qt event loop until it is killed. No window, no widgets.

`bin/` contains six byte-identical copies of the binary, `HeadlessQtApp` and
`HeadlessQtApp2` … `HeadlessQtApp6`, so that up to six anchors can be registered as
separate AUTs and attached to independently (each on its own `startaut` port). Any further
copy under any name in `bin/` works the same way, since everything is found relative to the
binary's own directory.

Squish's desktop screenshot grabs the primary `QScreen`, which here is the real X display,
so the screenshot shows whatever is on the VM's screen, not the anchor (which has nothing
to show).

## Layout (this folder is what goes on the share)

```
HeadlessQtApp/
├── bin/
│   ├── HeadlessQtApp            ELF x86_64, DT_RPATH $ORIGIN/../libs/lib64
│   ├── HeadlessQtApp2 … HeadlessQtApp6   five identical copies (separate AUTs for Squish)
│   └── qt.conf                  tells Qt where plugins/ is
├── plugins/
│   ├── platforms/libqxcb.so  libqoffscreen.so  libqminimal.so
│   └── imageformats/*.so
├── libs/lib64/                  EVERY shared library except glibc, under its SONAME:
│   ├── libQt6Core.so.6  libQt6Gui.so.6  libQt6Widgets.so.6  libQt6Network.so.6
│   ├── libQt6Xml.so.6  libQt6Concurrent.so.6  libQt6PrintSupport.so.6  libQt6XcbQpa.so.6
│   ├── libicui18n.so.67  libicuuc.so.67  libicudata.so.67  libzstd.so.1
│   ├── libglib-2.0.so.0  libgthread-2.0.so.0  libpcre.so.1
│   ├── libstdc++.so.6  libgcc_s.so.1
│   ├── libxcb*.so  libX11.so.6  libX11-xcb.so.1  libXau.so.6  libxkbcommon*.so
│   └── MANIFEST.txt             where every file came from
├── main.cpp, CMakeLists.txt     the application source
└── README.md
```

No scripts, no symlinks (survives an SMB share), nothing to install, no environment
variables needed. The only things used from the machine are the kernel, glibc and the X
server. Nothing in the tree needs more than `GLIBC_2.34`, so it runs on every RHEL 9
release from 9.0 GA on. The binary links every shipped Qt module and carries a `DT_RPATH`
that is inherited by everything loaded into the process, so the Squish wrapper that
`startaut` preloads resolves its Qt 6.8.0 libraries from `libs/lib64` without
`LD_LIBRARY_PATH`. **Do not set `LD_LIBRARY_PATH`**: it is not needed and would make
Squish's own binaries load libraries from this tree.

The share must be mounted so that files on it are executable (not `noexec`, executable
bit visible): `startaut` executes `bin/HeadlessQtApp` directly.

## Environment it reacts to

| Variable | Default | Meaning |
| --- | --- | --- |
| `DISPLAY` | `:0` | the X display to attach to (the VM's own screen) |
| `XAUTHORITY` | unset | cookie file, if the X server requires authorization |
| `QT_QPA_PLATFORM` | `xcb` | `offscreen` runs it with no display at all (nothing to screenshot) |

If the output says `qt.qpa.xcb: could not connect to display :0`, the custom UI on the VM
is either on another display number, requires an X cookie (`XAUTHORITY`), or is not an X
server at all (framebuffer/DRM/Wayland). In the last case Qt cannot grab that screen and
Squish's desktop screenshots cannot show it; the anchor can still run with
`QT_QPA_PLATFORM=offscreen`.

## Checking by hand on the VM

```bash
cd /mnt/share/HeadlessQtApp
bin/HeadlessQtApp            # prints the startup line with the screen size; Ctrl-C to stop
ldd bin/HeadlessQtApp        # everything from libs/lib64 except glibc
readelf --version-info libs/lib64/libQt6Core.so.6 | grep -E 'Qt_6.8|Qt_6_PRIVATE_API'
```

## Rebuilding

Only `main.cpp` and `CMakeLists.txt` are needed; the tooling that produced the binaries
(a RHEL 9 container with the Qt 6.8.0 SDK) is not part of this repository. In any RHEL 9
environment with a Qt 6.8.0 `gcc_64` SDK and `cmake`/`g++`:

```bash
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_PREFIX_PATH=/opt/Qt/6.8.0/gcc_64 -DCMAKE_INSTALL_PREFIX="$PWD/dist"
cmake --build build --parallel && cmake --install build      # -> dist/bin/HeadlessQtApp
```

Configure stops if the SDK is not exactly 6.8.0 or its `libQt6Core.so.6` lacks
`Qt_6_PRIVATE_API`. Copy the binary to `bin/`, keep `bin/qt.conf`, and lay out the Qt
libraries and plugins as above (real files named by SONAME; RPATH `$ORIGIN` on the
libraries, `$ORIGIN/../../libs/lib64` on the plugins, `$ORIGIN/../libs/lib64` on the binary).

## What was built and tested

- **Qt 6.8.0** (what Squish for Qt 8.1.0 was built with, per its own startup message) was
  built from the `qtbase` **v6.8.0** tag (commit `b839e9b36db3a4e50dfb34521d8ef8de1fd01969`)
  with the RHEL 9 GCC 11.5 toolchain in an Oracle Linux 9.8 container (RHEL 9 binary
  compatible). Modules: Core, Gui, Widgets, Network, Xml, Concurrent, PrintSupport;
  platforms xcb, offscreen, minimal; ICU, GLib and zstd enabled; freetype/harfbuzz/png/
  jpeg/zlib/pcre2 compiled in; no fontconfig/OpenGL/DBus. Its `libQt6Core.so.6` has the
  same ELF version nodes (`Qt_6` … `Qt_6.8`, `Qt_6_PRIVATE_API`) as the official Qt 6.8.0
  library (PySide6 6.8.0 wheel) and exports a strict superset of its Qt symbols.
- ICU, glib2, zstd and the X/xcb/xkbcommon libraries are the RHEL 9 (el9) packages;
  `libgcc_s.so.1` is the RHEL 9.0 GA build so that nothing needs `GLIBC_2.35`
  (`_dl_find_object`, backported only in later 9.x); packaging verifies every file stays
  within `GLIBC_2.34`.
- Build-side validation (55 checks, including that the five copies are byte-identical): RPATH, every library/plugin resolving without
  `LD_LIBRARY_PATH`, offscreen run, xcb run against an Xvfb (reports the display's screen,
  no window created), stays in the event loop until SIGTERM, clean failure message without
  an X server.
- The tree was mounted **read-only into pristine, network-less `redhat/ubi9:9.0.0-1576`
  (RHEL 9.0 GA, glibc 2.34-28), `redhat/ubi9` (9.8) and `redhat/ubi9-micro`** containers
  with no X, ICU or glib installed, and the binary started directly: it attached to an X
  server running elsewhere (`DISPLAY=127.0.0.1:97`, 1280x800), stayed running until
  SIGTERM, and ran with `QT_QPA_PLATFORM=offscreen`; on 9.0 GA all six copies also ran
  concurrently against that display, each reporting its own name.
- **Not tested here**: Squish itself (not available). In your runs Squish attached to the
  Qt 6.8.0 tree and took desktop screenshots of the display the anchor was connected to.
  Whether image-based *clicks* reach the custom UI on the VM depends on how Squish
  dispatches them on Linux (Qt-level events only reach the AUT's own windows); the
  screenshots themselves are of the whole X display.
