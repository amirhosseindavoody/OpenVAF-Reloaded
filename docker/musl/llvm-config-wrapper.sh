#!/bin/sh
# Static-only llvm-config for the musl build.
#
# llvm-sys is compiled with the prefer-dynamic feature (see mir_llvm).
# That tries `llvm-config --libnames --link-shared` first and falls back
# to --link-static if it fails. This wrapper:
#   * fails every --link-shared query so the fallback is taken
#   * reports --libdir/--prefix/--bindir/--shared-mode against /opt/LLVM
#     (which contains only .a archives; see setup-llvm-prefix.sh)
set -eu

REAL="${OPENVAF_REAL_LLVM_CONFIG:-/usr/lib/llvm18/bin/llvm-config}"
PREFIX="${LLVM_SYS_181_PREFIX:-/opt/LLVM}"

# Concatenate args with spaces so we can match flags regardless of order.
args=" $* "

case "$args" in
    *" --link-shared "*)
        echo "llvm-config: shared LLVM is hidden in this prefix (static-only musl build)" >&2
        exit 1
        ;;
    *" --shared-mode "*)
        echo static
        exit 0
        ;;
    *" --libdir "*)
        echo "$PREFIX/lib"
        exit 0
        ;;
    *" --bindir "*)
        echo "$PREFIX/bin"
        exit 0
        ;;
    *" --prefix "*)
        echo "$PREFIX"
        exit 0
        ;;
    *" --includedir "*)
        if [ -d "$PREFIX/include" ]; then
            echo "$PREFIX/include"
        else
            exec "$REAL" "$@"
        fi
        exit 0
        ;;
esac

exec "$REAL" "$@"
