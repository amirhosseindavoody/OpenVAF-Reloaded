#!/usr/bin/env bash
# Verify an ELF binary (and optional bundled .so files) need no GLIBC
# symbol newer than 2.31. Prints a verification log to stdout.
set -euo pipefail

MAX_ALLOWED="2.31"
if [[ $# -lt 1 ]]; then
    echo "usage: $0 <elf> [elf...]" >&2
    exit 2
fi

version_gt() {
    # return 0 if $1 > $2 (dotted numeric versions)
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

fail=0
for elf in "$@"; do
    if [[ ! -f "$elf" ]]; then
        echo "ERROR: missing file: $elf" >&2
        fail=1
        continue
    fi

    echo "===== $(readlink -f "$elf") ====="
    file "$elf" || true
    echo
    echo "--- ldd ---"
    ldd "$elf" || true
    echo
    echo "--- GLIBC symbol versions (objdump -T) ---"
    # Dynamic version requirements from the GNU version table.
    versions=$(
        objdump -T "$elf" 2>/dev/null \
            | grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' \
            | sort -u
    )
    if [[ -z "$versions" ]]; then
        echo "(no GLIBC_* versions found — static or no libc symbols)"
    else
        echo "$versions"
    fi

    max_needed="0.0"
    while read -r ver; do
        [[ -z "$ver" ]] && continue
        num="${ver#GLIBC_}"
        if version_gt "$num" "$max_needed"; then
            max_needed="$num"
        fi
        if version_gt "$num" "$MAX_ALLOWED"; then
            echo "ERROR: $elf requires $ver (> GLIBC_$MAX_ALLOWED)" >&2
            fail=1
        fi
    done <<< "$versions"

    echo
    echo "Highest GLIBC version needed: GLIBC_${max_needed}"
    if version_gt "$max_needed" "$MAX_ALLOWED"; then
        echo "RESULT: FAIL (ceiling is GLIBC_${MAX_ALLOWED})"
    else
        echo "RESULT: PASS (GLIBC_${max_needed} <= GLIBC_${MAX_ALLOWED})"
    fi
    echo
done

if [[ $fail -ne 0 ]]; then
    echo "Verification failed: one or more files require GLIBC newer than ${MAX_ALLOWED}." >&2
    exit 1
fi
echo "All checked files are compatible with glibc ${MAX_ALLOWED}."
