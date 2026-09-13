# Linux x86_64 musl artifacts

This directory holds the **verification log** after a real musl link
(`scripts/build-musl.sh` writes `musl-verification.txt` from `file`,
`ldd`, and `readelf`). The latest recorded run is a **fully static
static-pie** (`file` says `static-pie linked`; no `PT_INTERP`, no
`NEEDED`, no `GLIBC_*`). The
`openvaf-r-*-linux-x86_64-musl.tar.gz` binary tarball is **not**
stored in git. Produce it locally or download the GitHub Actions
artifact `openvaf-r-linux-x86_64-musl`:

```bash
./scripts/build-musl.sh
```

See [BUILD_MUSL.md](../../BUILD_MUSL.md) for the toolchain pin, when to
use musl vs glibc231 vs the default Linux build, and the pass criterion
(no `GLIBC_*`; prefer fully static).
