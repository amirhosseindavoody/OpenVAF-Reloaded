#!/bin/sh
# Build a static-only LLVM prefix at $LLVM_PREFIX (default /opt/LLVM).
#
# Alpine ships both llvm18-libs (.so) and llvm18-static (.a). Pointing
# llvm-sys at a prefix that contains only archives makes prefer-dynamic
# fall back to static linking — the same situation as the official
# clang+llvm Ubuntu tarball used by the SLES 15 recipe.
set -eu

PREFIX="${LLVM_PREFIX:-${LLVM_SYS_181_PREFIX:-/opt/LLVM}}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REAL_CFG=""

for cand in \
    /usr/lib/llvm18/bin/llvm-config \
    /usr/bin/llvm-config-18 \
    /usr/bin/llvm18-config
do
    if [ -x "$cand" ]; then
        REAL_CFG="$cand"
        break
    fi
done

if [ -z "$REAL_CFG" ] && command -v llvm-config >/dev/null 2>&1; then
    REAL_CFG="$(command -v llvm-config)"
fi

if [ -z "$REAL_CFG" ] || [ ! -x "$REAL_CFG" ]; then
    echo "setup-llvm-prefix: no llvm-config-18 found" >&2
    exit 1
fi

REAL_LIBDIR="$("$REAL_CFG" --libdir)"
REAL_INCLUDE="$("$REAL_CFG" --includedir)"

mkdir -p "$PREFIX/bin" "$PREFIX/lib"

# Wrapper reports this prefix and rejects --link-shared. See
# llvm-config-wrapper.sh.
cp "$SCRIPT_DIR/llvm-config-wrapper.sh" "$PREFIX/bin/llvm-config.real"
cat > "$PREFIX/bin/llvm-config" <<EOF
#!/bin/sh
export OPENVAF_REAL_LLVM_CONFIG="$REAL_CFG"
export LLVM_SYS_181_PREFIX="$PREFIX"
exec /bin/sh "$PREFIX/bin/llvm-config.real" "\$@"
EOF
chmod 755 "$PREFIX/bin/llvm-config" "$PREFIX/bin/llvm-config.real"

if [ -d "$REAL_INCLUDE" ]; then
    ln -sfn "$REAL_INCLUDE" "$PREFIX/include"
fi

# osdi/build.rs looks for \$PREFIX/bin/clang to emit bitcode.
for clang in /usr/bin/clang-18 /usr/lib/llvm18/bin/clang /usr/bin/clang; do
    if [ -x "$clang" ]; then
        ln -sfn "$clang" "$PREFIX/bin/clang"
        break
    fi
done
for clangxx in /usr/bin/clang++-18 /usr/lib/llvm18/bin/clang++ /usr/bin/clang++; do
    if [ -x "$clangxx" ]; then
        ln -sfn "$clangxx" "$PREFIX/bin/clang++"
        break
    fi
done

link_archive() {
    src="$1"
    [ -f "$src" ] || return 0
    base="$(basename "$src")"
    if [ ! -e "$PREFIX/lib/$base" ]; then
        ln -sfn "$src" "$PREFIX/lib/$base"
    fi
}

for dir in "$REAL_LIBDIR" /usr/lib/llvm18/lib /usr/lib; do
    [ -d "$dir" ] || continue
    find "$dir" -maxdepth 1 -type f \( -name 'libLLVM*.a' -o -name 'libclang*.a' \) \
        | while IFS= read -r arc; do
            link_archive "$arc"
        done
done

if libnames="$("$REAL_CFG" --link-static --libnames 2>/dev/null)"; then
    for name in $libnames; do
        case "$name" in
            lib*.a) ;;
            *.a) name="lib$name" ;;
            *) name="lib${name}.a" ;;
        esac
        for dir in "$REAL_LIBDIR" /usr/lib/llvm18/lib /usr/lib; do
            if [ -f "$dir/$name" ]; then
                link_archive "$dir/$name"
                break
            fi
        done
    done
fi

count="$(find "$PREFIX/lib" -maxdepth 1 -name '*.a' | wc -l | tr -d ' ')"
if [ "$count" -lt 1 ]; then
    echo "setup-llvm-prefix: no static LLVM archives found (install llvm18-static)" >&2
    exit 1
fi

echo "setup-llvm-prefix: $PREFIX ($count static archives, real llvm-config=$REAL_CFG)"
"$PREFIX/bin/llvm-config" --version
"$PREFIX/bin/llvm-config" --libdir
