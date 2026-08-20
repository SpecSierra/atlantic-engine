#!/bin/bash
#
# Verify the patch stack without compiling anything.
#
#   scripts/verify-patch-stack.sh              # apply the stack, print a tree hash
#   scripts/verify-patch-stack.sh <hash>       # ...and fail unless it matches
#
# Applies every patch in scripts/patches.sh order to a pristine upstream tree
# reduced to just the files the stack touches (~24 MB, not 1.5 GB), then hashes
# the result. Two uses:
#
#  - CI/bump guard: catches a patch that no longer applies, in seconds.
#  - Consolidation proof: merging or reordering patches must not change the tree.
#    Record the hash before the change, pass it after. For a REMOVAL, re-apply
#    the removed patches to the output tree and check the hash returns to the
#    pre-removal one — that proves the delta is exactly those patches. This is
#    how the 117 -> 39 consolidation was validated (see patches/RATIONALE.md);
#    it caught a hand-written hunk header whose inflated line count silently
#    swallowed the next file's section.
#
# Env: WORKDIR (default a mktemp dir), KEEP=1 to leave it behind.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/versions.env"
: "${WPE_WEBKIT_VERSION:=2.52.6}"
EXPECTED="${1:-}"

WORKDIR="${WORKDIR:-$(mktemp -d)}"
trap '[ -n "${KEEP:-}" ] || rm -rf "${WORKDIR}"' EXIT
mkdir -p "${WORKDIR}"

TARBALL="${WORKDIR}/wpewebkit-${WPE_WEBKIT_VERSION}.tar.xz"
PRISTINE="${WORKDIR}/wpewebkit-${WPE_WEBKIT_VERSION}"

if [ ! -d "${PRISTINE}" ]; then
    echo "==> Fetching pristine wpewebkit-${WPE_WEBKIT_VERSION}"
    wget -q "https://wpewebkit.org/releases/wpewebkit-${WPE_WEBKIT_VERSION}.tar.xz" -O "${TARBALL}"
    tar -xf "${TARBALL}" -C "${WORKDIR}"
    rm -f "${TARBALL}"
fi

echo "==> Building the touched-file subset"
grep -hoP '^(---|\+\+\+) [ab]/\K[^\t ]+' "${SCRIPT_DIR}"/patches/webkit/*.patch \
    | sed 's/[[:space:]]*$//' | sort -u > "${WORKDIR}/subset.txt"
BASE="${WORKDIR}/base"
TREE="${WORKDIR}/tree"
rm -rf "${BASE}" "${TREE}"
while read -r f; do
    if [ -f "${PRISTINE}/$f" ]; then
        mkdir -p "${BASE}/$(dirname "$f")"
        cp -p "${PRISTINE}/$f" "${BASE}/$f"
    fi
done < "${WORKDIR}/subset.txt"
cp -a "${BASE}" "${TREE}"
echo "    $(find "${BASE}" -type f | wc -l) of $(wc -l < "${WORKDIR}/subset.txt") files (the rest are created by patches)"

echo "==> Applying the stack in scripts/patches.sh order"
fail=0
while read -r p; do
    [ -z "$p" ] && continue
    if ( cd "${TREE}" && patch -p1 --batch --forward --dry-run < "${SCRIPT_DIR}/$p" >/dev/null 2>&1 ); then
        ( cd "${TREE}" && patch -p1 --batch --forward < "${SCRIPT_DIR}/$p" >/dev/null )
    else
        echo "FAILS TO APPLY: $p"
        ( cd "${TREE}" && patch -p1 --batch --forward --dry-run < "${SCRIPT_DIR}/$p" 2>&1 \
            | grep -E '^(patching|Hunk|can.t find)' | head -10 | sed 's/^/    /' )
        fail=$((fail + 1))
    fi
done < <(grep -oP '^\s*"\Kpatches/webkit/[^"]+' "${SCRIPT_DIR}/scripts/patches.sh")

find "${TREE}" -type f \( -name '*.orig' -o -name '*.rej' \) -delete

# Hash the pristine->patched DIFF, not the tree: a file the stack no longer
# touches then contributes nothing, so the value stays comparable across changes
# to the patch set (a plain tree hash would move just because the touched-file
# list shrank).
HASH="$( { diff -ruN "${BASE}" "${TREE}" || true; } \
    | sed -E "s#^(---|\\+\\+\\+) [^\t]*/(Source/)#\\1 \\2#; s#\t[0-9]{4}-[0-9]{2}-[0-9]{2}.*\$##" \
    | sha256sum | awk '{print $1}')"

echo ""
echo "stack hash: ${HASH}"
[ "${fail}" -eq 0 ] || { echo "FAIL: ${fail} patch(es) did not apply" >&2; exit 1; }

if [ -n "${EXPECTED}" ] && [ "${HASH}" != "${EXPECTED}" ]; then
    echo "FAIL: expected ${EXPECTED}" >&2
    exit 1
fi
echo "OK"
