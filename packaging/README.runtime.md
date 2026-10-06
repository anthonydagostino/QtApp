# squish-anchor (RHEL 9 x86_64 runtime package)

Headless Qt 6.6.0 anchor process for Squish attachment. No GUI, no QtWidgets/QML,
no X11/Wayland, no display required: it uses `QCoreApplication` only.

**Self-contained.** Nothing has to be installed on the target machine: no Qt, no
container runtime, no extra packages, no network. Unpack and run. The only things used
from the host are glibc (the dynamic loader, libc, libm, libdl, libpthread, librt),
libstdc++ and libgcc_s, which every RHEL 9 system has; for the last two the package even
carries fallback copies that the wrapper uses automatically if the host lacks them.

## Layout

```
squish-anchor-rhel9-x86_64/
├── bin/squish-anchor        ELF x86_64 executable, RUNPATH $ORIGIN/../lib
├── lib/libQt6Core.so.6      Qt 6.6.0 Core (exports Qt_6_PRIVATE_API) + its runtime deps (ICU)
├── lib/fallback/            libstdc++.so.6 / libgcc_s.so.1, used only if the host has none
├── run-squish-anchor.sh     wrapper: prepends lib/ to LD_LIBRARY_PATH, exec()s the binary
├── validate.sh              self-check (needs only bash and ldd; file/readelf optional)
└── README.md                this file
```

## Run

```bash
tar -xzf squish-anchor-rhel9-x86_64.tar.gz
cd squish-anchor-rhel9-x86_64
./run-squish-anchor.sh            # runs until SIGTERM or SIGINT
./run-squish-anchor.sh --once     # logs startup and exits 0
./run-squish-anchor.sh --help
```

`bin/squish-anchor` can also be started directly (its RUNPATH finds `lib/`), but the
wrapper is the supported entry point: it preserves an existing `LD_LIBRARY_PATH`, adds
`lib/` in front of it and `exec()`s the binary, so the PID it logs is the PID to attach
Squish to.

Startup output (stdout), example:

```
2026-01-01T12:00:00.000 squish-anchor[12345]: started pid=12345 version=1.0.0
2026-01-01T12:00:00.001 squish-anchor[12345]: qt runtime=6.6.0 built-against=6.6.0 core-library=/opt/squish-anchor-rhel9-x86_64/lib/libQt6Core.so.6.6.0
2026-01-01T12:00:00.001 squish-anchor[12345]: running event loop until SIGTERM or SIGINT
```

Stop it with `kill -TERM <pid>` (or Ctrl-C); it logs the signal and exits with status 0.

## Validate

```bash
./validate.sh                     # automated checks, works without file/readelf installed
```

or by hand (`file` and `readelf` need the `file` and `binutils` packages; `ldd` is part of glibc):

```bash
file bin/squish-anchor
ldd bin/squish-anchor
readelf -d bin/squish-anchor
readelf --version-info lib/libQt6Core.so.6 | grep Qt_6_PRIVATE_API
./run-squish-anchor.sh --once
```
