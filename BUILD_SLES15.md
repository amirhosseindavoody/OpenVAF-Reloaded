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
3. Bundle non-glibc shared libraries (notably `libLLVM`) next to the binary with `$ORIGIN/../lib`.
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

## GitHub Actions artifact

Workflow: [`.github/workflows/sles15-binary.yml`](.github/workflows/sles15-binary.yml).

On `workflow_dispatch`, and on pushes/PRs that touch the compiler or this
recipe, it runs `./scripts/build-sles15.sh` on `ubuntu-latest` (which provides
Docker) and uploads:

- `openvaf-r-linux-x86_64-glibc231` — the `.tar.gz` plus `glibc-verification.txt`

Download from the Actions run (or a GitHub Release, if a maintainer attaches
the same tarball).

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

`libLLVM` is bundled because `mir_llvm` enables `llvm-sys`'s `prefer-dynamic`
feature. System `libc` / `libm` / `libpthread` come from SLES 15 itself.

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

Filled in after the first successful image build on this branch. Until then
treat CI's `glibc-verification.txt` artifact as the source of truth — do not
assume a binary is 2.31-safe without that log.

```
(pending first successful build — this section is updated in a follow-up commit)
```

## What this does *not* do

- It does not change the default `release.yml` Linux job, which still builds
  on Ubuntu 24.04 (glibc 2.39) for users who do not need SLES 15.
- It does not vendor the ~1 GiB LLVM tarball in git.
- It does not statically link LLVM (link RAM/time; `prefer-dynamic` is
  upstream's default for `mir_llvm`).
