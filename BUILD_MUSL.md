# Building `openvaf-r` for Linux x86_64 musl

This document is the reproducible recipe for a **Linux x86_64** `openvaf-r`
that does **not** depend on glibc (so it is not limited by `GLIBC_2.31`,
`GLIBC_2.39`, or any other GNU libc ceiling).

The default Release Linux job (`ubuntu-24.04`) and the
[SLES 15 / glibc 2.31](BUILD_SLES15.md) job both link against **glibc**.
Use this musl build when you need a binary that runs on old or unusual
Linux userlands, in a container that only has musl, or when you want a
fully static compiler binary.

## Which Linux artifact should I use?

| Artifact | libc | Typical host | Use when |
| --- | --- | --- | --- |
| `openvaf-r-*-linux-x86_64.tar.gz` | glibc (Ubuntu 24.04) | Ubuntu 24.04+ / Fedora / recent Debian | You are on a modern glibc distro and want the default binary. |
| `openvaf-r-*-linux-x86_64-glibc231.tar.gz` | glibc ≤ 2.31 | SLES 15, Ubuntu 20.04, older RHEL | The default binary dies with `GLIBC_2.3x not found`. See [BUILD_SLES15.md](BUILD_SLES15.md). |
| `openvaf-r-*-linux-x86_64-musl.tar.gz` | musl (preferably static) | Alpine, Void musl, or *any* Linux if static | You want **no glibc version dependency**. Prefer this for “runs everywhere” Linux. |

The musl artifact is an **additional** Release asset. It does not replace
the glibc or glibc231 jobs.

## Why this toolchain

A stock `cargo build --release --target x86_64-unknown-linux-musl` on
Ubuntu is **not** sufficient: `llvm-sys` still links the host
(glibc) LLVM, and the official
`clang+llvm-*-x86_64-linux-gnu-ubuntu-*.tar.xz` tarballs are glibc
objects. Statically linking those `.a` files would pull GNU libc
symbols into the binary.

| Piece | Pin | Why |
| --- | --- | --- |
| Container base | `alpine:3.21` | Distro libc is **musl**. No glibc in the link. |
| LLVM | Alpine `llvm18-dev` + `llvm18-static` (18.1.8) | Musl-built archives. Matches the repo `llvm18` Cargo feature / `llvm-sys` 181. |
| Static prefix | `/opt/LLVM` (wrapper `llvm-config`) | `mir_llvm` enables llvm-sys `prefer-dynamic`. The wrapper fails `--link-shared` and exposes only `.a` files so the crate falls back to `--link-static`. |
| Rust | rustup toolchain `1.98.1` (minimal profile) + target `x86_64-unknown-linux-musl` | Same pin as the SLES 15 recipe (`clap` 4.6 / edition 2024). |
| Cargo invocation | `cargo build --release --package openvaf-driver --features llvm18 --bin openvaf-r --target x86_64-unknown-linux-musl` | Same package/features as the other Linux jobs. |
| Link flags | `-C target-feature=+crt-static -C link-self-contained=no -C link-arg=-static` | Prefer a fully static binary. `link-self-contained=no` uses Alpine's `libc.a` so it matches Alpine libstdc++ / LLVM. Override with `OPENVAF_MUSL_STATIC=0` for musl-dynamic. |

The image definition is [`docker/musl/Dockerfile`](docker/musl/Dockerfile).
The driver script is [`scripts/build-musl.sh`](scripts/build-musl.sh).

## Build (recommended: Docker)

On a machine with Docker:

```bash
./scripts/build-musl.sh
```

That will:

1. `docker build --network=host` the `openvaf-musl:x86_64` image
   (Alpine 3.21 + LLVM 18.1.8 static + rustc 1.98.1). Host networking is
   used so the build works when dockerd has no user-bridge (nested
   environments); it is harmless on a normal Docker host.
2. Run the compile **inside** that image (`--in-container`), so the
   linker sees musl and musl-built LLVM.
3. Try a **fully static** link first. If you pass
   `OPENVAF_MUSL_STATIC=0`, link musl-dynamic and bundle remaining
   shared libraries (plus `ld-musl-x86_64.so.1`) under `lib/` with
   `$ORIGIN`.
4. Write:
   - `artifacts/musl/openvaf-r-<git-describe>-linux-x86_64-musl.tar.gz`
   - `artifacts/musl/musl-verification.txt`

Re-runs reuse the image layers and a host-side Cargo registry cache at
`.cargo-musl/` (gitignored).

### Already inside Alpine 3.21 (or another musl x86_64 env)

Install `llvm18-dev`, `llvm18-static`, `clang18`, `build-base`,
`musl-dev`, and the `*-static` packages listed in the Dockerfile,
plus rustup 1.98.1, then:

```bash
export LLVM_SYS_181_PREFIX=/opt/LLVM
./docker/musl/setup-llvm-prefix.sh
export PATH=/opt/LLVM/bin:$PATH
./scripts/build-musl.sh --in-container
```

The script **refuses** to link if the host is not musl (no
`ld-musl-x86_64.so.1` / musl `ldd`). That is intentional: a glibc
host would contaminate the binary.

## GitHub Actions artifact and GitHub Release

Two workflows produce this tarball:

- [`.github/workflows/musl-binary.yml`](.github/workflows/musl-binary.yml)
  — `workflow_dispatch`, or a push/PR that touches the musl Docker
  recipe / scripts / this workflow. Uploads Actions artifact
  `openvaf-r-linux-x86_64-musl` (`.tar.gz` + `musl-verification.txt`).
  It does **not** run on every `openvaf/**` change (that compile is
  expensive); Release always builds it.
- [`.github/workflows/release.yml`](.github/workflows/release.yml) job
  `linux-x86_64-musl` — on `v*` tags (or a manual Release dispatch with a
  tag). Uses the same `./scripts/build-musl.sh` and names the archive
  `openvaf-r-<tag>-linux-x86_64-musl.tar.gz`. The `publish` job attaches
  it to the GitHub Release next to the Ubuntu 24.04, glibc231, Windows,
  and macOS assets.

Set `OPENVAF_MUSL_PKG` to override the archive directory/tarball name
(Release does this from the tag). Do **not** use `${{ env.* }}` in a
workflow `env:` mapping — GitHub rejects that (it already broke Release
once). Derive the package name in a `run:` step and write
`OPENVAF_MUSL_PKG` to `$GITHUB_ENV`.

## Install and run

```bash
tar -xzf openvaf-r-*-linux-x86_64-musl.tar.gz
cd openvaf-r-*-linux-x86_64-musl
./bin/openvaf-r --help
# ./bin/openvaf-r path/to/model.va
```

**Fully static** (preferred): `lib/` is absent or empty. `ldd` reports
“not a dynamic executable” / “statically linked”. The binary has no
`PT_INTERP` and no `NEEDED` entries. Copy `bin/openvaf-r` anywhere.

**Musl-dynamic** (fallback): keep `bin/` and `lib/` together. The
wrapper rpath is `$ORIGIN/../lib`. The interpreter is musl
(`ld-musl-x86_64.so.1`), never `/lib64/ld-linux-x86-64.so.2`. This
still has **no glibc** dependency; it needs the bundled musl loader
(or an Alpine-like `/lib/ld-musl-x86_64.so.1` on the target).

## Verification

After linking, the build script runs [`scripts/verify-musl.sh`](scripts/verify-musl.sh):

```bash
file artifacts/musl/openvaf-r-*/bin/openvaf-r
ldd artifacts/musl/openvaf-r-*/bin/openvaf-r
readelf -h artifacts/musl/openvaf-r-*/bin/openvaf-r
readelf -d artifacts/musl/openvaf-r-*/bin/openvaf-r
readelf -V artifacts/musl/openvaf-r-*/bin/openvaf-r
objdump -T artifacts/musl/openvaf-r-*/bin/openvaf-r | grep -oE 'GLIBC_[0-9.]+' | sort -u
```

**Pass criterion:** no `GLIBC_*` version needs, and either

1. fully static (no program interpreter, no `NEEDED`), or
2. musl-dynamic (`ld-musl-*` interpreter; `NEEDED` never includes
   `libc.so.6`).

The machine-readable log is written to
`artifacts/musl/musl-verification.txt` by `scripts/build-musl.sh` from
real `file` / `ldd` / `readelf` output (uploaded as a Release/Actions
artifact). Commit that file only after a real run — do not invent
`file`/`ldd` lines.

### Latest recorded verification

Built 2026-09-13 inside `alpine:3.21` (musl) with Alpine LLVM 18.1.8
static archives and rustc 1.98.1. Binary `file(1)`:

```
ELF 64-bit LSB pie executable, x86-64, version 1 (SYSV), static-pie linked
```

(`readelf -h` reports `Type: DYN (Position-Independent Executable file)`,
`Machine: Advanced Micro Devices X86-64`. There is **no**
`PT_INTERP` and **no** `NEEDED` entry.)

`objdump -T` / `readelf -V`: **no `GLIBC_*` versions**.

Alpine `ldd` still prints `/lib/ld-musl-x86_64.so.1` for a static-pie
(known musl ldd quirk). On Ubuntu 24.04 (glibc 2.39) the same binary
reports:

```
ldd: statically linked
```

and `openvaf-r --help` / `--version` both exit 0, including under
`env -i PATH=/usr/bin`. No bundled `lib/` directory.

The machine-readable copy of this log is
[`artifacts/musl/musl-verification.txt`](artifacts/musl/musl-verification.txt).

## What this does *not* do

- It does not change the default `release.yml` Linux job (Ubuntu 24.04
  glibc) or the glibc231 / SLES 15 job.
- It does not vendor Alpine LLVM packages in git.
- It does not build LLVM from source. If Alpine's `llvm18-static` is
  ever insufficient, rebuild LLVM 18.1.8 *on musl* (same CMake flags as
  the README) and point `LLVM_SYS_181_PREFIX` at that prefix. A glibc
  LLVM build cannot be rescued with `-static`.
