# OpenVAF-Reloaded toolchain for SLES 15 / glibc 2.31 compatibility.
#
# Base: Ubuntu 20.04 (Focal) ships glibc 2.31 — the same SONAME/version
# ceiling as SLES 15 SP2–SP4. The official LLVM 18.1.8 tarball below was
# built on Ubuntu 18.04 (glibc 2.27), so neither rustc output nor libLLVM
# can pull in GLIBC symbols newer than 2.31.
#
# Do not COPY the OpenVAF sources into this image. Mount the repo at
# build time (see scripts/build-sles15.sh).

FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/opt/cargo \
    LLVM_PREFIX=/opt/LLVM \
    LLVM_SYS_181_PREFIX=/opt/LLVM \
    PATH=/opt/LLVM/bin:/opt/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Pinned official LLVM 18.1.8 linux-gnu build (Ubuntu 18.04).
# SHA256 from https://discourse.llvm.org/t/18-1-8-has-been-tagged/79726
ARG LLVM_URL=https://github.com/llvm/llvm-project/releases/download/llvmorg-18.1.8/clang+llvm-18.1.8-x86_64-linux-gnu-ubuntu-18.04.tar.xz
ARG LLVM_SHA256=54ec30358afcc9fb8aa74307db3046f5187f9fb89fb37064cdde906e062ebf36
ARG RUST_TOOLCHAIN=1.83.0

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        binutils \
        build-essential \
        ca-certificates \
        cmake \
        curl \
        file \
        git \
        libffi-dev \
        libtinfo5 \
        libxml2 \
        ninja-build \
        patchelf \
        pkg-config \
        python3 \
        xz-utils \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fL --retry 5 --retry-delay 3 -o /tmp/llvm.tar.xz "$LLVM_URL" \
    && echo "$LLVM_SHA256  /tmp/llvm.tar.xz" | sha256sum -c - \
    && mkdir -p "$LLVM_PREFIX" \
    && tar -C "$LLVM_PREFIX" --strip-components=1 -xJf /tmp/llvm.tar.xz \
    && rm /tmp/llvm.tar.xz \
    && "$LLVM_PREFIX/bin/llvm-config" --version

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain "$RUST_TOOLCHAIN" --profile minimal \
    && rustc --version \
    && cargo --version

WORKDIR /src
CMD ["bash", "scripts/build-sles15.sh", "--in-container"]
