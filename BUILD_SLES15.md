# Building `openvaf-r` for SLES 15 (glibc 2.31)

This document is the reproducible recipe for a **Linux x86_64** `openvaf-r`
that runs on **SLES 15** (SP2–SP6) and any other distro whose glibc is 2.31
or newer, without requiring GLIBC symbols newer than `GLIBC_2.31`.

A stock `cargo build --release` on Ubuntu 24.04 / a modern Cursor VM is **not**
sufficient: those hosts ship glibc 2.39+, and the resulting binary plus the
distro `libLLVM` will request symbols such as `GLIBC_2.32`–`GLIBC_2.38`.

## Why this toolchain

| Piece | Pin | Why |
| --- | --- | --- |
| Container base | `ubuntu:20.04` (Focal) | Distro glibc **2.31** — same ceiling as SLES 15. |
| LLVM | Official `clang+llvm-18.1.8-x86_64-linux-gnu-ubuntu-18.04.tar.xz` | Built on Ubuntu 18.04 (glibc 2.27). SHA256 `54ec30358afcc9fb8aa74307db3046f5187f9fb89fb37064cdde906e062ebf36`. Matches the repo's `llvm18` Cargo feature / `llvm-sys` 181. |
| Rust | rustup toolchain `1.98.1` (minimal profile) | Current stable; required for `clap` 4.6 (`edition2024`). Still runs on glibc 2.31. Recorded in the verification log. |
| Cargo invocation | `cargo build --release --package openvaf-driver --features llvm18 --bin openvaf-r` | Same CLI the README/`build.sh` use, pinned to LLVM 18. |

The image definition is [`docker/sles15/Dockerfile`](docker/sles15/Dockerfile).
The driver script is [`scripts/build-sles15.sh`](scripts/build-sles15.sh).

openSUSE Leap 15.4 (also glibc 2.31) is an equally valid host if you install
the same LLVM tarball and rustup inside it; Ubuntu 20.04 is used here because
the official LLVM tarball and rustup installers are routinely tested on it.

## Build (recommended: Docker)

On a machine with Docker:

```bash
./scripts/build-sles15.sh
```

That will:

1. `docker build --network=host` the `openvaf-sles15:glibc231` image (Ubuntu 20.04 + LLVM 18.1.8 + rustc 1.98.1). Host networking is used so the build works when dockerd has no user-bridge (nested environments); it is harmless on a normal Docker host.
2. Run the compile **inside** that image (`--in-container`), so the linker sees glibc 2.31.
3. Bundle non-glibc shared libraries next to the binary with `$ORIGIN/../lib`.
   LLVM 18.1.8 from the official tarball is **statically** linked (the tarball
   ships `.a` archives; `ldd` does not show `libLLVM`). The remaining runtime
   deps that SLES 15 may not have (`libtinfo.so.5`, plus `libstdc++` /
   `libgcc_s` / `libz` for a self-contained tree) are copied as real files.
4. Write:
   - `artifacts/sles15/openvaf-r-<git-describe>-linux-x86_64-glibc231.tar.gz`
   - `artifacts/sles15/glibc-verification.txt`

The first image build downloads ~1 GiB of LLVM. Re-runs reuse the image layers
and a host-side Cargo registry cache at `.cargo-sles15/` (gitignored).

### Already inside Ubuntu 20.04 / Leap 15.4 / SLES 15

Install the same LLVM tarball under `/opt/LLVM`, rustup 1.98.1, and:

```bash
export LLVM_SYS_181_PREFIX=/opt/LLVM
export PATH=/opt/LLVM/bin:$PATH
./scripts/build-sles15.sh --in-container
```

The script refuses to link if `ldd --version` reports glibc **newer than 2.31**.

## GitHub Actions artifact and GitHub Release

Two workflows produce this tarball:

- [`.github/workflows/sles15-binary.yml`](.github/workflows/sles15-binary.yml)
  — CI / `workflow_dispatch`. Uploads Actions artifact
  `openvaf-r-linux-x86_64-glibc231` (`.tar.gz` + `glibc-verification.txt`).
- [`.github/workflows/release.yml`](.github/workflows/release.yml) job
  `linux-x86_64-glibc231` — on `v*` tags (or a manual Release dispatch with a
  tag). Uses the same `./scripts/build-sles15.sh` and names the archive
  `openvaf-r-<tag>-linux-x86_64-glibc231.tar.gz`. The `publish` job attaches it
  to the GitHub Release next to the Ubuntu 24.04 Linux, Windows, and macOS
  assets.

Set `OPENVAF_SLES15_PKG` to override the archive directory/tarball name
(Release does this from the tag).

## Install and run on SLES 15

```bash
tar -xzf openvaf-r-*-linux-x86_64-glibc231.tar.gz
cd openvaf-r-*-linux-x86_64-glibc231
./bin/openvaf-r --help
# compile a Verilog-A model, same as any other openvaf-r:
# ./bin/openvaf-r path/to/model.va
```

The wrapper rpath is `$ORIGIN/../lib`, so you do **not** need SLES LLVM
packages and you should not need `LD_LIBRARY_PATH`. Keep `bin/` and `lib/`
together.

System `libc` / `libm` / `libpthread` / `libdl` come from SLES 15 itself.
LLVM is linked in statically from the Ubuntu 18.04 official tarball. The
tarball still ships `libtinfo.so.5` (ncurses 5 ABI; SLES 15 is often ncurses 6
only) and Ubuntu 20.04 `libstdc++.so.6.0.28` so the tree is self-contained.

## Verification

After linking, the build script runs [`scripts/verify-glibc-2.31.sh`](scripts/verify-glibc-2.31.sh):

```bash
file artifacts/sles15/openvaf-r-*/bin/openvaf-r
# expected: ELF 64-bit LSB executable, x86-64, ... dynamically linked

ldd artifacts/sles15/openvaf-r-*/bin/openvaf-r
objdump -T artifacts/sles15/openvaf-r-*/bin/openvaf-r | grep -oE 'GLIBC_[0-9.]+' | sort -u
readelf -V artifacts/sles15/openvaf-r-*/bin/openvaf-r
```

**Pass criterion:** the highest `GLIBC_*` version needed by `openvaf-r` *and*
every bundled `.so` is **≤ 2.31**. The machine-readable log is copied to
`artifacts/sles15/glibc-verification.txt` (and, after a successful agent
build, into the Cursor artifacts folder).

### Latest recorded verification

Built 2026-09-12 inside `ubuntu:20.04` (glibc 2.31) with LLVM 18.1.8 and
rustc 1.98.1. Binary `file(1)`:

```
ELF 64-bit LSB pie executable, x86-64, version 1 (SYSV), dynamically linked,
interpreter /lib64/ld-linux-x86-64.so.2, for GNU/Linux 3.2.0, with debug_info
```

(`file` may say "shared object" for a PIE; `readelf -h` reports
`Type: DYN (Position-Independent Executable file)`, `Machine: Advanced Micro
Devices X86-64`.)

Unique `GLIBC_*` versions needed by `openvaf-r` (from `objdump -T`):

```
GLIBC_2.12
GLIBC_2.14
GLIBC_2.15
GLIBC_2.16
GLIBC_2.17
GLIBC_2.18
GLIBC_2.2.5
GLIBC_2.25
GLIBC_2.27
GLIBC_2.28
GLIBC_2.29
GLIBC_2.3
GLIBC_2.3.4
GLIBC_2.30
GLIBC_2.4
GLIBC_2.9
```

**Highest: `GLIBC_2.30` (≤ 2.31). PASS.**

`readelf -V` version-needs for `libc.so.6` (excerpt):

```
File: libc.so.6
  GLIBC_2.2.5
  GLIBC_2.3
  GLIBC_2.3.4
  GLIBC_2.4
  GLIBC_2.9
  GLIBC_2.14
  GLIBC_2.15
  GLIBC_2.16
  GLIBC_2.17
  GLIBC_2.18
  GLIBC_2.25
  GLIBC_2.28
  GLIBC_2.29
  GLIBC_2.30
```

Bundled libraries (all PASS, max needed shown):

| library | max GLIBC |
| --- | --- |
| `libz.so.1.2.11` | 2.14 |
| `libtinfo.so.5.9` | 2.16 |
| `libstdc++.so.6.0.28` | 2.18 |
| `libgcc_s.so.1` | 2.14 |

`openvaf-r --help` and `--version` were run successfully both inside the
Ubuntu 20.04 (glibc 2.31) container and on a glibc 2.39 host using the
bundled `$ORIGIN/../lib` tree.

The machine-readable copy of this log is
[`artifacts/sles15/glibc-verification.txt`](artifacts/sles15/glibc-verification.txt).

## What this does *not* do

- It does not change the default `release.yml` Linux job, which still builds
  on Ubuntu 24.04 (glibc 2.39) for users who do not need SLES 15.
- It does not vendor the ~1 GiB LLVM tarball in git.
- It does not require a SLES LLVM RPM. The official LLVM 18.1.8 static
  archives are linked into `openvaf-r`.
