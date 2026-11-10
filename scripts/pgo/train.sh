#!/bin/bash
# Run the training workload on an INSTRUMENTED engine (ATLANTIC_PGO=generate)
# and merge what it recorded into the profile the release build consumes.
#
#   train.sh INSTRUMENTED_PREFIX OUTPUT.profdata
#
# Everything runs on the build host with no display (atl-headless.c). The
# workload is scripts/pgo/workloads/*.txt; each file is one browser session.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
prefix="${1:?usage: train.sh INSTRUMENTED_PREFIX OUTPUT.profdata}"
output="${2:?usage: train.sh INSTRUMENTED_PREFIX OUTPUT.profdata}"
workdir="${PGO_WORKDIR:-$(mktemp -d /var/tmp/atlantic-pgo-train.XXXXXX)}"
raw="${workdir}/raw"

if [ ! -f "${prefix}/lib/atlantic-pgo-exit-hook.o" ]; then
    echo "ERROR: ${prefix} is not an instrumented (ATLANTIC_PGO=generate) build" >&2
    exit 1
fi

source "${here}/headless-env.sh"
atl_headless_setup "${prefix}" "${workdir}"
rm -rf "${raw}"
mkdir -p "${raw}"

# %m: one file per instrumented binary, which every process of that binary
# merges its counters into (under a file lock) as it exits.
export LLVM_PROFILE_FILE="${raw}/atlantic-%m.profraw"

# Each session runs twice, once per painting path, because the two target
# phones differ: the Adreno one paints tiles on the CPU, the Mali one through
# Skia's GPU backend. A path that never ran in training is compiled as cold.
for painting in cpu gpu; do
    for workload in "${here}"/workloads/*.txt; do
        echo "=== $(basename "${workload}") [${painting} painting] ==="
        if [ "${painting}" = cpu ]; then
            export WEBKIT_SKIA_ENABLE_CPU_RENDERING=1
        else
            unset WEBKIT_SKIA_ENABLE_CPU_RENDERING
        fi
        # A session that crashes or hangs loses only its own data.
        timeout --signal=TERM --kill-after=30 "${PGO_SESSION_TIMEOUT:-3600}" \
            env LD_PRELOAD="${ATL_HEADLESS_PRELOAD}" LD_LIBRARY_PATH="${prefix}/lib:${ATL_HEADLESS_ICU_DIR}" "${ATL_HEADLESS}" "${workload}" \
            || echo "  session ended abnormally (status $?), continuing" >&2
        atl_headless_wait_helpers "${prefix}"
    done
done

shopt -s nullglob
raw_files=("${raw}"/*.profraw)
if [ "${#raw_files[@]}" -eq 0 ]; then
    echo "ERROR: the training run left no profile in ${raw}" >&2
    exit 1
fi
ls -l "${raw_files[@]}"

mkdir -p "$(dirname "${output}")"
llvm-profdata-18 merge -o "${output}.tmp" "${raw_files[@]}"
llvm-profdata-18 show "${output}.tmp" | tee "${output}.txt"

# A profile in which almost nothing ran means the engine never got to load a
# page (no network, a crash at startup...). Using it would mark the whole
# engine cold and ship a SLOWER build, so refuse it.
# IR profiles have no per-function "Function count" line; --value-cutoff=1
# prints how many functions have any counter that ran at least once.
executed="$(llvm-profdata-18 show --value-cutoff=1 "${output}.tmp" 2>/dev/null \
    | sed -n 's/^Number of functions with maximum count (>= 1): //p')"
executed="${executed:-0}"
echo "Functions executed during training: ${executed}"
echo "functions_executed=${executed}" >> "${output}.txt"
if [ "${executed}" -lt "${PGO_MIN_EXECUTED_FUNCTIONS:-30000}" ]; then
    echo "ERROR: only ${executed} functions executed; refusing this profile" >&2
    rm -f "${output}.tmp"
    exit 1
fi
mv "${output}.tmp" "${output}"
echo "Profile written: ${output} ($(du -h "${output}" | cut -f1))"
