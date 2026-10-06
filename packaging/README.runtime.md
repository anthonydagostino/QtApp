# squish-anchor (RHEL 9 x86_64 runtime package)

Headless Qt 6.6.0 anchor process for Squish attachment. No GUI, no QtWidgets/QML,
no X11/Wayland, no display required: it uses `QCoreApplication` only.

## Layout

```
squish-anchor-rhel9-x86_64/
├── bin/squish-anchor        ELF x86_64 executable, RUNPATH $ORIGIN/../lib
├── lib/libQt6Core.so.6      Qt 6.6.0 Core (exports Qt_6_PRIVATE_API) + its Qt runtime deps
├── run-squish-anchor.sh     wrapper: prepends lib/ to LD_LIBRARY_PATH, exec()s the binary
└── README.md                this file
```

The package relies on the RHEL 9 system for glibc, the dynamic loader, libstdc++,
libgcc_s, zlib and glib2. Those are intentionally not bundled.

## Run

```bash
tar -xzf squish-anchor-rhel9-x86_64.tar.gz
cd squish-anchor-rhel9-x86_64
./run-squish-anchor.sh            # runs until SIGTERM or SIGINT
./run-squish-anchor.sh --once     # logs startup and exits 0
./run-squish-anchor.sh --help
```

Startup output (stdout), example:

```
2026-01-01T12:00:00.000 squish-anchor[12345]: started pid=12345 version=1.0.0
2026-01-01T12:00:00.001 squish-anchor[12345]: qt runtime=6.6.0 built-against=6.6.0 core-library=/opt/squish-anchor-rhel9-x86_64/lib/libQt6Core.so.6.6.0
2026-01-01T12:00:00.001 squish-anchor[12345]: running event loop until SIGTERM or SIGINT
```

The wrapper `exec()`s the binary, so the PID it logs is the PID to attach Squish to.
Stop it with `kill -TERM <pid>` (or Ctrl-C); it exits with status 0.

## Validate

```bash
file bin/squish-anchor
ldd bin/squish-anchor
readelf -d bin/squish-anchor
readelf --version-info lib/libQt6Core.so.6 | grep Qt_6_PRIVATE_API
./run-squish-anchor.sh --once
```
