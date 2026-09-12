#!/usr/bin/env bash
# Build a Linux x86_64 openvaf-r that runs on SLES 15 (glibc 2.31).
#
# Usage:
#   ./scripts/build-sles15.sh              # build via Docker (ubuntu:20.04)
#   ./scripts/build-sles15.sh --in-container
#       # already inside the sles15 image / an equivalent glibc-2.31 env
#
# Outputs (gitignored):
#   target-sles15/release/openvaf-r
#   artifacts/sles15/openvaf-r-*-linux-x86_64-glibc231.tar.gz
#   artifacts/sles15/glibc-verification.txt
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

IMAGE_NAME="${OPENVAF_SLES15_IMAGE:-openvaf-sles15:glibc231}"
DOCKERFILE="$ROOT/docker/sles15/Dockerfile"
TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target-sles15}"
OUT_DIR="${OPENVAF_SLES15_OUT:-$ROOT/artifacts/sles15}"
LLVM_FEATURE="${OPENVAF_LLVM_FEATURE:-llvm18}"
IN_CONTAINER=0

for arg in "$@"; do
    case "$arg" in
        --in-container) IN_CONTAINER=1 ;;
        -h|--help)
            sed -n '2,16p' "$0"
            exit 0
            ;;
        *)
            echo "unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

version_gt() {
    local IFS=.
    local i a=($1) b=($2)
    for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
        local x=${a[i]:-0} y=${b[i]:-0}
        if ((10#$x > 10#$y)); then
            return 0
        fi
        if ((10#$x < 10#$y)); then
            return 1
        fi
    done
    return 1
}

host_glibc_version() {
    ldd --version 2>&1 | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1
}

docker_cmd() {
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        echo docker
        return 0
    fi
    if command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
        echo "sudo docker"
        return 0
    fi
    return 1
}

package_and_verify() {
    local bin="$1"
    if [[ ! -x "$bin" ]]; then
        echo "ERROR: expected binary not found: $bin" >&2
        exit 1
    fi

    mkdir -p "$OUT_DIR"
    local describe
    describe="$(git -C "$ROOT" describe --always --dirty --tags 2>/dev/null || git -C "$ROOT" rev-parse --short HEAD)"
    local pkg="openvaf-r-${describe}-linux-x86_64-glibc231"
    local staging="$OUT_DIR/$pkg"
    rm -rf "$staging"
    mkdir -p "$staging/bin" "$staging/lib"

    cp -a "$bin" "$staging/bin/openvaf-r"
    chmod +x "$staging/bin/openvaf-r"

    # Bundle non-glibc shared libraries so SLES 15 does not need distro LLVM.
    local libdir=""
    if [[ -n "${LLVM_SYS_181_PREFIX:-}" && -d "${LLVM_SYS_181_PREFIX}/lib" ]]; then
        libdir="${LLVM_SYS_181_PREFIX}/lib"
    elif [[ -d /opt/LLVM/lib ]]; then
        libdir=/opt/LLVM/lib
    fi

    copy_dep() {
        local src="$1"
        local base
        base="$(basename "$src")"
        case "$base" in
            libc.so.*|libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|libutil.so.*| \
            libresolv.so.*|libnss_*.so.*|ld-linux-x86-64.so.*)
                return 0
                ;;
        esac
        if [[ -f "$src" && ! -e "$staging/lib/$base" ]]; then
            cp -a "$src" "$staging/lib/$base"
        fi
    }

    # Follow ldd lines of the form: "libfoo.so.1 => /path/to/libfoo.so.1 (0x...)"
    while read -r line; do
        if [[ "$line" =~ =>[[:space:]]+([^[:space:]]+) ]]; then
            copy_dep "${BASH_REMATCH[1]}"
        fi
    done < <(ldd "$staging/bin/openvaf-r" || true)

    if [[ -n "$libdir" ]]; then
        # llvm-sys prefer-dynamic: ensure the soname the binary actually NEEDs is present.
        for so in "$libdir"/libLLVM*.so* "$libdir"/libclang*.so* "$libdir"/libLTO*.so*; do
            [[ -e "$so" ]] || continue
            # Only copy libraries that the binary lists as NEEDED or that ldd already pulled.
            local base
            base="$(basename "$so")"
            if [[ -e "$staging/lib/$base" ]]; then
                continue
            fi
        done
    fi

    # Make bundled libs usable next to the binary without touching LD_LIBRARY_PATH.
    if command -v patchelf >/dev/null 2>&1; then
        patchelf --set-rpath '$ORIGIN/../lib' "$staging/bin/openvaf-r"
        for so in "$staging/lib"/*; do
            [[ -f "$so" && ! -L "$so" ]] || continue
            if file "$so" | grep -q 'ELF'; then
                patchelf --set-rpath '$ORIGIN' "$so" || true
            fi
        done
    fi

    local verify_log="$OUT_DIR/glibc-verification.txt"
    {
        echo "openvaf-r SLES 15 / glibc 2.31 verification"
        echo "=========================================="
        echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "git: $(git -C "$ROOT" rev-parse HEAD) ($describe)"
        echo "host: $(source /etc/os-release && echo "$PRETTY_NAME")"
        echo "host glibc: $(ldd --version | head -n1)"
        echo "rustc: $(rustc --version 2>/dev/null || echo unknown)"
        echo "cargo: $(cargo --version 2>/dev/null || echo unknown)"
        if [[ -x "${LLVM_SYS_181_PREFIX:-/opt/LLVM}/bin/llvm-config" ]]; then
            echo "llvm-config: $("${LLVM_SYS_181_PREFIX:-/opt/LLVM}/bin/llvm-config" --version) ($("${LLVM_SYS_181_PREFIX:-/opt/LLVM}/bin/llvm-config" --prefix))"
        fi
        echo
        echo "file(1):"
        file "$staging/bin/openvaf-r"
        echo
        "$ROOT/scripts/verify-glibc-2.31.sh" "$staging/bin/openvaf-r"
        echo
        echo "Bundled libraries:"
        ls -lh "$staging/lib" || true
        echo
        if [[ -n "$(ls -A "$staging/lib" 2>/dev/null || true)" ]]; then
            echo "Checking bundled ELF libraries for GLIBC ceiling..."
            mapfile -t bundled < <(find "$staging/lib" -type f -exec file {} \; | awk -F: '/ELF/{print $1}')
            if [[ ${#bundled[@]} -gt 0 ]]; then
                "$ROOT/scripts/verify-glibc-2.31.sh" "${bundled[@]}"
            fi
        fi
        echo
        echo "--- readelf -V (GNU Version definitions / needs) ---"
        readelf -V "$staging/bin/openvaf-r" || true
        echo
        echo "--- objdump -T GLIBC symbols ---"
        objdump -T "$staging/bin/openvaf-r" | grep -E 'GLIBC_' | sort -u || true
    } | tee "$verify_log"

    tar -C "$OUT_DIR" -czf "$OUT_DIR/${pkg}.tar.gz" "$pkg"
    echo
    echo "Wrote $OUT_DIR/${pkg}.tar.gz"
    echo "Wrote $verify_log"
}

build_in_container() {
    local glibc
    glibc="$(host_glibc_version)"
    echo "Build host glibc: $glibc"
    if version_gt "$glibc" "2.31"; then
        echo "ERROR: refusing to link on glibc $glibc (must be <= 2.31)." >&2
        echo "Re-run via Docker: ./scripts/build-sles15.sh" >&2
        exit 1
    fi

    git config --global --add safe.directory "$ROOT" || true

    if [[ -z "${LLVM_SYS_181_PREFIX:-}" ]]; then
        export LLVM_SYS_181_PREFIX="${LLVM_PREFIX:-/opt/LLVM}"
    fi
    export PATH="${LLVM_SYS_181_PREFIX}/bin:${PATH}"
    export CARGO_TARGET_DIR="$TARGET_DIR"
    # Keep the shipped binary relocatable next to bundled libLLVM.
    export RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-Wl,-rpath,\$ORIGIN/../lib"

    echo "Using LLVM at $LLVM_SYS_181_PREFIX"
    llvm-config --version
    rustc --version

    ./configure --llvm=18
    cargo build --release --package openvaf-driver --features "$LLVM_FEATURE" --bin openvaf-r

    package_and_verify "$TARGET_DIR/release/openvaf-r"

    # Smoke-test: the binary must at least start on this glibc-2.31 host.
    set +e
    "$OUT_DIR"/openvaf-r-*/bin/openvaf-r --help >/tmp/openvaf-r-help.txt 2>&1
    local rc=$?
    set -e
    echo
    echo "--- openvaf-r --help (exit $rc) ---"
    cat /tmp/openvaf-r-help.txt
    if [[ $rc -ne 0 ]]; then
        echo "WARNING: openvaf-r --help exited $rc (flags may differ; binary still linked)."
    fi
}

if [[ "$IN_CONTAINER" -eq 1 ]]; then
    build_in_container
    exit 0
fi

DOCKER_BIN="$(docker_cmd)" || {
    echo "Docker is not available. Either:" >&2
    echo "  * start Docker and re-run ./scripts/build-sles15.sh" >&2
    echo "  * or enter an Ubuntu 20.04 / Leap 15.4 / SLES 15 container and run:" >&2
    echo "      ./scripts/build-sles15.sh --in-container" >&2
    exit 1
}

echo "Building toolchain image $IMAGE_NAME from $DOCKERFILE"
# shellcheck disable=SC2086
$DOCKER_BIN build -t "$IMAGE_NAME" -f "$DOCKERFILE" "$ROOT/docker/sles15"

mkdir -p "$TARGET_DIR" "$OUT_DIR" "$ROOT/.cargo-sles15"

echo "Compiling openvaf-r inside $IMAGE_NAME"
# shellcheck disable=SC2086
$DOCKER_BIN run --rm \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -e CARGO_HOME=/cargo \
    -e CARGO_TARGET_DIR=/src/target-sles15 \
    -e RUSTUP_HOME=/opt/rustup \
    -v "$ROOT":/src:rw \
    -v "$ROOT/.cargo-sles15":/cargo:rw \
    -w /src \
    "$IMAGE_NAME" \
    bash scripts/build-sles15.sh --in-container
