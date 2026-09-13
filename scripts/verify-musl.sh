#!/usr/bin/env bash
# Verify an ELF is a musl linux-x86_64 binary with no glibc dependency.
# Prefer fully static ("not a dynamic executable" / no PT_INTERP).
# A musl-dynamic binary (interpreter ld-musl-*, NEEDED only musl/compiler
# libs — never libc.so.6) is accepted and reported as such.
#
# Prints a verification log to stdout. Exits 1 on glibc or other failure.
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <elf> [elf...]" >&2
    exit 2
fi

fail=0

has_glibc_versions() {
    local elf="$1"
    if command -v objdump >/dev/null 2>&1; then
        objdump -T "$elf" 2>/dev/null | grep -qE 'GLIBC_[0-9]' && return 0
    fi
    if command -v readelf >/dev/null 2>&1; then
        readelf -V "$elf" 2>/dev/null | grep -qE 'GLIBC_[0-9]' && return 0
    fi
    return 1
}

is_static() {
    local elf="$1"
    local interp=""
    interp="$(readelf -l "$elf" 2>/dev/null | awk '/Requesting program interpreter/{print $NF}' | tr -d '[]' || true)"
    if [[ -n "$interp" ]]; then
        return 1
    fi
    # No PT_INTERP. Confirm there are no NEEDED shared libs.
    if readelf -d "$elf" 2>/dev/null | grep -q 'NEEDED'; then
        return 1
    fi
    return 0
}

for elf in "$@"; do
    if [[ ! -f "$elf" ]]; then
        echo "ERROR: missing file: $elf" >&2
        fail=1
        continue
    fi

    echo "===== $(readlink -f "$elf") ====="
    echo
    echo "--- file(1) ---"
    file "$elf" || true
    echo
    echo "--- readelf -h (ELF header) ---"
    readelf -h "$elf" || true
    echo
    echo "--- readelf -l (program interpreter) ---"
    readelf -l "$elf" | awk '/INTERP|Requesting program interpreter|Type:/{print}' || true
    echo
    echo "--- readelf -d (dynamic section / NEEDED) ---"
    if readelf -d "$elf" 2>/dev/null | grep -E 'NEEDED|RPATH|RUNPATH|SONAME'; then
        :
    else
        echo "(no NEEDED / RPATH / RUNPATH — statically linked or no dynamic section)"
        readelf -d "$elf" 2>/dev/null | head -n 20 || true
    fi
    echo
    echo "--- ldd ---"
    set +e
    ldd_out="$(ldd "$elf" 2>&1)"
    ldd_rc=$?
    set -e
    printf '%s\n' "$ldd_out"
    echo

    glibc=0
    if has_glibc_versions "$elf"; then
        glibc=1
    fi
    if echo "$ldd_out" | grep -qE 'libc\.so\.6|ld-linux-x86-64\.so'; then
        glibc=1
    fi
    if echo "$ldd_out" | grep -qi 'statically linked'; then
        : # ldd wording for a static binary (glibc ldd) — not a glibc dep
    fi

    echo "--- GLIBC symbol versions (objdump -T) ---"
    versions="$(
        objdump -T "$elf" 2>/dev/null \
            | grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' \
            | sort -u || true
    )"
    if [[ -z "$versions" ]]; then
        echo "(no GLIBC_* versions found)"
    else
        echo "$versions"
        echo "ERROR: $elf carries GLIBC version needs (not a musl binary)" >&2
        fail=1
        glibc=1
    fi
    echo

    echo "--- musl / libc symbols (readelf -s, sample) ---"
    # musl binaries often have no versioned libc symbols. Show a few
    # allocated symbols so the log is not empty on a static link.
    readelf -s "$elf" 2>/dev/null | awk '
        /musl|__libc_|__memcpy_chk|__stack_chk/ { print; n++; if (n >= 20) exit }
    ' || true
    echo

    if [[ "$glibc" -ne 0 ]]; then
        echo "RESULT: FAIL (glibc dependency detected)"
        fail=1
    elif is_static "$elf"; then
        echo "RESULT: PASS (fully static musl; no PT_INTERP, no NEEDED, no GLIBC_*)"
    elif echo "$ldd_out" | grep -qiE 'not a dynamic executable|statically linked'; then
        echo "RESULT: PASS (ldd reports static / not a dynamic executable; no GLIBC_*)"
    elif echo "$ldd_out" | grep -q 'ld-musl-'; then
        echo "RESULT: PASS (musl-dynamic; no glibc). Runtime needs a musl loader."
        echo "NEEDED libraries:"
        readelf -d "$elf" 2>/dev/null | awk '/NEEDED/{print}' || true
    else
        echo "RESULT: FAIL (not static, not musl-dynamic, or unrecognized link)"
        fail=1
    fi
    echo
done

if [[ $fail -ne 0 ]]; then
    echo "Verification failed: one or more files are not musl (or are missing)." >&2
    exit 1
fi
echo "All checked files are musl (static or musl-only; no glibc)."
