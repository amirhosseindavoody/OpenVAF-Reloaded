# OpenVAF-Reloaded toolchain for a musl linux-x86_64 openvaf-r.
#
# Base: Alpine 3.21 (musl libc). LLVM 18.1.8 comes from Alpine's
# llvm18-dev + llvm18-static packages, so every object we link is
# musl-built — unlike the official clang+llvm Ubuntu tarball (glibc).
#
# Do not COPY the OpenVAF sources into this image. Mount the repo at
# build time (see scripts/build-musl.sh).

FROM alpine:3.21

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/opt/cargo \
    LLVM_PREFIX=/opt/LLVM \
    LLVM_SYS_181_PREFIX=/opt/LLVM \
    PATH=/opt/LLVM/bin:/opt/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# rustc 1.83 cannot parse clap 4.6 (edition 2024). 1.98.1 matches the
# SLES 15 recipe and is current stable as of that pin.
ARG RUST_TOOLCHAIN=1.98.1

# community hosts clang18 / llvm18-static on some Alpine branches.
RUN printf '%s\n' \
        "https://dl-cdn.alpinelinux.org/alpine/v3.21/main" \
        "https://dl-cdn.alpinelinux.org/alpine/v3.21/community" \
        > /etc/apk/repositories \
    && apk add --no-cache \
        bash \
        binutils \
        build-base \
        ca-certificates \
        clang18 \
        cmake \
        curl \
        file \
        git \
        libffi-dev \
        libxml2-dev \
        libxml2-static \
        libunwind-dev \
        libunwind-static \
        linux-headers \
        llvm18-dev \
        llvm18-static \
        musl-dev \
        ncurses-dev \
        ncurses-static \
        ninja \
        patchelf \
        pkgconf \
        python3 \
        xz-dev \
        xz-static \
        zlib-dev \
        zlib-static \
        zstd-dev \
        zstd-static

# Static-only prefix so llvm-sys prefer-dynamic falls back to .a archives.
COPY llvm-config-wrapper.sh setup-llvm-prefix.sh /opt/image-scripts/
RUN chmod 755 /opt/image-scripts/*.sh \
    && /opt/image-scripts/setup-llvm-prefix.sh \
    && chmod -R a+rX /opt/LLVM

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain "$RUST_TOOLCHAIN" --profile minimal \
    && . /opt/cargo/env \
    && rustup target add x86_64-unknown-linux-musl \
    && rustc --version \
    && cargo --version \
    && chmod -R a+rX /opt/rustup /opt/cargo

WORKDIR /src
CMD ["bash", "scripts/build-musl.sh", "--in-container"]
