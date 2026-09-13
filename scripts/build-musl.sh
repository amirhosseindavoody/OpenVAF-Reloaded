#!/usr/bin/env bash
# Build a Linux x86_64 openvaf-r against musl (preferably fully static).
#
# Usage:
#   ./scripts/build-musl.sh              # build via Docker (alpine:3.21)
#   ./scripts/build-musl.sh --in-container
#       # already inside the musl image / an equivalent Alpine env
#
# Outputs (gitignored tarball; verification log is committed when recorded):
#   target-musl/x86_64-unknown-linux-musl/release/openvaf-r
#   artifacts/musl/openvaf-r-*-linux-x86_64-musl.tar.gz
#   artifacts/musl/musl-verification.txt
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

IMAGE_NAME="${OPENVAF_MUSL_IMAGE:-openvaf-musl:x86_64}"
DOCKERFILE="$ROOT/docker/musl/Dockerfile"
TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target-musl}"
OUT_DIR="${OPENVAF_MUSL_OUT:-$ROOT/artifacts/musl}"
LLVM_FEATURE="${OPENVAF_LLVM_FEATURE:-llvm18}"
RUST_TARGET="x86_64-unknown-linux-musl"
IN_CONTAINER=0

for arg in "$@"; do
    case "$arg" in
        --in-container) IN_CONTAINER=1 ;;
        -h|--help)
            sed -n '2,17p' "$0"
            exit 0
            ;;
        *)
            echo "unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

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

is_musl_host() {
    # Alpine / musl: ldd is a symlink to the musl loader and prints musl.
    if ldd --version 2>&1 | grep -qi musl; then
        return 0
    fi
    if [[ -f /lib/ld-musl-x86_64.so.1 ]]; then
        return 0
    fi
    if command -v rustc >/dev/null 2>&1; then
        rustc -vV 2>/dev/null | grep -q 'host: x86_64-unknown-linux-musl' && return 0
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
    # Release workflow sets OPENVAF_MUSL_PKG=openvaf-r-<tag>-linux-x86_64-musl
    local pkg="${OPENVAF_MUSL_PKG:-openvaf-r-${describe}-linux-x86_64-musl}"
    local staging="$OUT_DIR/$pkg"
    rm -rf "$staging"
    mkdir -p "$staging/bin" "$staging/lib"

    cp -a "$bin" "$staging/bin/openvaf-r"
    chmod +x "$staging/bin/openvaf-r"

    copy_dep() {
        local src="$1"
        local base
        base="$(basename "$src")"
        case "$base" in
            # Never bundle the host glibc loader (we should not have these).
            ld-linux-x86-64.so.*|libc.so.6)
                echo "ERROR: refusing to bundle glibc dependency $src" >&2
                exit 1
                ;;
        esac
        if [[ -e "$src" && ! -e "$staging/lib/$base" ]]; then
            local real
            real="$(readlink -f "$src")"
            if [[ -f "$real" ]]; then
                local realbase
                realbase="$(basename "$real")"
                if [[ ! -e "$staging/lib/$realbase" ]]; then
                    cp -a "$real" "$staging/lib/$realbase"
                fi
                if [[ "$realbase" != "$base" ]]; then
                    ln -sfn "$realbase" "$staging/lib/$base"
                fi
            fi
        fi
    }

    local static=0
    if ! readelf -l "$staging/bin/openvaf-r" | grep -q 'Requesting program interpreter'; then
        if ! readelf -d "$staging/bin/openvaf-r" 2>/dev/null | grep -q 'NEEDED'; then
            static=1
        fi
    fi

    if [[ "$static" -eq 0 ]]; then
        # musl-dynamic: bundle non-libc shared libs and, if present, the
        # musl loader so the tree can be relocated with $ORIGIN.
        while read -r dep; do
            [[ -n "$dep" && -e "$dep" ]] || continue
            copy_dep "$dep"
        done < <(ldd "$staging/bin/openvaf-r" 2>/dev/null | awk '/=>/ {print $3}')

        local musl_ld=""
        for cand in /lib/ld-musl-x86_64.so.1 /usr/lib/ld-musl-x86_64.so.1; do
            if [[ -f "$cand" ]]; then
                musl_ld="$cand"
                break
            fi
        done
        if [[ -n "$musl_ld" ]]; then
            copy_dep "$musl_ld"
        fi

        if command -v patchelf >/dev/null 2>&1; then
            patchelf --set-rpath '$ORIGIN/../lib' "$staging/bin/openvaf-r"
            if [[ -n "$musl_ld" && -e "$staging/lib/$(basename "$musl_ld")" ]]; then
                patchelf --set-interpreter '$ORIGIN/../lib/'"$(basename "$musl_ld")" \
                    "$staging/bin/openvaf-r" || true
            fi
            for so in "$staging/lib"/*; do
                [[ -f "$so" && ! -L "$so" ]] || continue
                if file "$so" | grep -q 'ELF'; then
                    patchelf --set-rpath '$ORIGIN' "$so" || true
                fi
            done
        fi
    fi

    local verify_log="$OUT_DIR/musl-verification.txt"
    {
        echo "openvaf-r Linux x86_64 musl verification"
        echo "======================================="
        echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "git: $(git -C "$ROOT" rev-parse HEAD) ($describe)"
        if [[ -f /etc/os-release ]]; then
            echo "host: $(. /etc/os-release && echo "$PRETTY_NAME")"
        else
            echo "host: unknown"
        fi
        echo "host libc: $(ldd --version 2>&1 | awk 'NR==1 {print; exit}')"
        echo "rustc: $(rustc --version 2>/dev/null || echo unknown)"
        echo "cargo: $(cargo --version 2>/dev/null || echo unknown)"
        if [[ -x "${LLVM_SYS_181_PREFIX:-/opt/LLVM}/bin/llvm-config" ]]; then
            echo "llvm-config: $("${LLVM_SYS_181_PREFIX:-/opt/LLVM}/bin/llvm-config" --version) ($("${LLVM_SYS_181_PREFIX:-/opt/LLVM}/bin/llvm-config" --prefix))"
            echo "llvm-config --shared-mode: $("${LLVM_SYS_181_PREFIX:-/opt/LLVM}/bin/llvm-config" --shared-mode 2>/dev/null || echo unknown)"
        fi
        echo "RUSTFLAGS: ${RUSTFLAGS:-}"
        echo "static_link_attempted: ${OPENVAF_MUSL_STATIC:-1}"
        echo
        "$ROOT/scripts/verify-musl.sh" "$staging/bin/openvaf-r"
        echo
        echo "Bundled libraries:"
        if [[ -n "$(ls -A "$staging/lib" 2>/dev/null || true)" ]]; then
            ls -lh "$staging/lib"
            echo
            echo "Checking bundled ELF files for glibc..."
            mapfile -t bundled < <(find "$staging/lib" -type f -exec file {} \; | awk -F: '/ELF/{print $1}')
            if [[ ${#bundled[@]} -gt 0 ]]; then
                "$ROOT/scripts/verify-musl.sh" "${bundled[@]}"
            fi
        else
            echo "(none — fully static binary; lib/ is empty by design)"
        fi
        echo
        echo "--- readelf -d (full dynamic section) ---"
        readelf -d "$staging/bin/openvaf-r" || true
        echo
        echo "--- readelf -V (version needs) ---"
        readelf -V "$staging/bin/openvaf-r" || true
    } | tee "$verify_log"

    # Drop an empty lib/ so the tarball matches the static layout.
    if [[ "$static" -eq 1 ]]; then
        rmdir "$staging/lib" 2>/dev/null || true
    fi

    tar -C "$OUT_DIR" -czf "$OUT_DIR/${pkg}.tar.gz" "$pkg"
    echo
    echo "Wrote $OUT_DIR/${pkg}.tar.gz"
    echo "Wrote $verify_log"

    set +e
    "$staging/bin/openvaf-r" --help >/tmp/openvaf-r-help.txt 2>&1
    local rc=$?
    set -e
    echo
    echo "--- openvaf-r --help (exit $rc) ---"
    cat /tmp/openvaf-r-help.txt
    if [[ $rc -ne 0 ]]; then
        echo "WARNING: openvaf-r --help exited $rc (flags may differ; binary still linked)."
    fi
}

build_in_container() {
    if ! is_musl_host; then
        echo "ERROR: refusing to link on a non-musl host." >&2
        echo "A glibc LLVM/toolchain would sneak glibc into the binary." >&2
        echo "Re-run via Docker: ./scripts/build-musl.sh" >&2
        exit 1
    fi

    git config --global --add safe.directory "$ROOT" || true

    if [[ -z "${LLVM_SYS_181_PREFIX:-}" ]]; then
        export LLVM_SYS_181_PREFIX="${LLVM_PREFIX:-/opt/LLVM}"
    fi
    if [[ ! -x "${LLVM_SYS_181_PREFIX}/bin/llvm-config" ]]; then
        if [[ -x "$ROOT/docker/musl/setup-llvm-prefix.sh" ]]; then
            LLVM_PREFIX="$LLVM_SYS_181_PREFIX" "$ROOT/docker/musl/setup-llvm-prefix.sh"
        fi
    fi
    export PATH="${LLVM_SYS_181_PREFIX}/bin:${PATH}"
    export CARGO_TARGET_DIR="$TARGET_DIR"
    export CC="${CC:-gcc}"
    export CXX="${CXX:-g++}"

    # libstdc++.a lives in gcc's private libdir, not /usr/lib.
    local gcc_libdir
    gcc_libdir="$(dirname "$(g++ -print-file-name=libstdc++.a)")"
    local stub_dir="$TARGET_DIR/link-stubs"
    mkdir -p "$stub_dir"
    # musl folds librt/libdl/libpthread into libc. llvm-config --system-libs
    # still emits -lrt -ldl -lpthread; provide empty archives if needed.
    for stub in rt dl pthread util; do
        if [[ ! -e "$stub_dir/lib${stub}.a" ]]; then
            if [[ -e "/usr/lib/lib${stub}.a" ]]; then
                ln -sfn "/usr/lib/lib${stub}.a" "$stub_dir/lib${stub}.a"
            elif [[ -e "/usr/lib/libc.a" ]]; then
                ln -sfn /usr/lib/libc.a "$stub_dir/lib${stub}.a"
            fi
        fi
    done

    # Prefer a fully static link. crt-static + -static tells rustc/ld to
    # not emit a PT_INTERP. link-self-contained=no uses Alpine's musl
    # libc.a so it matches Alpine's libstdc++ / LLVM objects.
    local rustflags_common="-C link-arg=-L${stub_dir} -C link-arg=-L${gcc_libdir}"
    if [[ "${OPENVAF_MUSL_STATIC:-1}" != "0" ]]; then
        export RUSTFLAGS="${RUSTFLAGS:-} -C target-feature=+crt-static -C link-self-contained=no -C link-arg=-static ${rustflags_common}"
    else
        export RUSTFLAGS="${RUSTFLAGS:-} ${rustflags_common} -C link-arg=-Wl,-rpath,\$ORIGIN/../lib"
    fi

    echo "Using LLVM at $LLVM_SYS_181_PREFIX"
    llvm-config --version
    echo "llvm-config --libdir: $(llvm-config --libdir)"
    echo "llvm-config --shared-mode: $(llvm-config --shared-mode 2>/dev/null || echo n/a)"
    rustc --version
    echo "RUSTFLAGS=$RUSTFLAGS"
    echo "g++ libstdc++: $(g++ -print-file-name=libstdc++.a)"

    ./configure --llvm=18
    cargo build --release --package openvaf-driver --features "$LLVM_FEATURE" \
        --bin openvaf-r --target "$RUST_TARGET" \
        --config "target.${RUST_TARGET}.linker=\"g++\""

    local bin=""
    if [[ -x "$TARGET_DIR/$RUST_TARGET/release/openvaf-r" ]]; then
        bin="$TARGET_DIR/$RUST_TARGET/release/openvaf-r"
    elif [[ -x "$TARGET_DIR/release/openvaf-r" ]]; then
        bin="$TARGET_DIR/release/openvaf-r"
    else
        echo "ERROR: cargo succeeded but openvaf-r was not found under $TARGET_DIR" >&2
        exit 1
    fi

    package_and_verify "$bin"
}

if [[ "$IN_CONTAINER" -eq 1 ]]; then
    build_in_container
    exit 0
fi

DOCKER_BIN="$(docker_cmd)" || {
    echo "Docker is not available. Either:" >&2
    echo "  * start Docker and re-run ./scripts/build-musl.sh" >&2
    echo "  * or enter an Alpine 3.21 (musl) container and run:" >&2
    echo "      ./scripts/build-musl.sh --in-container" >&2
    exit 1
}

echo "Building toolchain image $IMAGE_NAME from $DOCKERFILE"
# --network=host: required when dockerd has no user-bridge (nested CI / this agent).
# Harmless on a normal Docker host / GitHub Actions runner.
# shellcheck disable=SC2086
$DOCKER_BIN build --network=host -t "$IMAGE_NAME" -f "$DOCKERFILE" "$ROOT/docker/musl"

mkdir -p "$TARGET_DIR" "$OUT_DIR" "$ROOT/.cargo-musl"

echo "Compiling openvaf-r inside $IMAGE_NAME"
# shellcheck disable=SC2086
$DOCKER_BIN run --rm \
    --network=host \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -e CARGO_HOME=/cargo \
    -e CARGO_TARGET_DIR=/src/target-musl \
    -e CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}" \
    -e OPENVAF_MUSL_PKG="${OPENVAF_MUSL_PKG:-}" \
    -e OPENVAF_MUSL_STATIC="${OPENVAF_MUSL_STATIC:-1}" \
    -e RUSTUP_HOME=/opt/rustup \
    -v "$ROOT":/src:rw \
    -v "$ROOT/.cargo-musl":/cargo:rw \
    -w /src \
    "$IMAGE_NAME" \
    bash scripts/build-musl.sh --in-container
