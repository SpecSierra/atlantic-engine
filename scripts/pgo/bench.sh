#!/bin/bash
# Host A/B of two engine builds: Speedometer 3.1 through atl-headless,
# interleaved (A B A B ...) so drift on the build host hits both equally.
#
#   bench.sh LABEL_A=PREFIX_A LABEL_B=PREFIX_B [ROUNDS]
#
# This measures DOM/style/layout/JS throughput on the build host's CPU. It says
# nothing about scrolling or the phone's GPU path: a win here still needs the
# on-device A/B (docs/BENCHMARKING.md) before it becomes the default.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
arm_a="${1:?usage: bench.sh LABEL_A=PREFIX_A LABEL_B=PREFIX_B [ROUNDS]}"
arm_b="${2:?usage: bench.sh LABEL_A=PREFIX_A LABEL_B=PREFIX_B [ROUNDS]}"
rounds="${3:-3}"
workdir="${PGO_WORKDIR:-$(mktemp -d /var/tmp/atlantic-pgo-bench.XXXXXX)}"

source "${here}/headless-env.sh"
atl_headless_setup "${arm_a#*=}" "${workdir}"
export WEBKIT_SKIA_ENABLE_CPU_RENDERING=1
unset LLVM_PROFILE_FILE

results="${workdir}/results.tsv"
: > "${results}"
for round in $(seq 1 "${rounds}"); do
    for arm in "${arm_a}" "${arm_b}"; do
        label="${arm%%=*}"
        prefix="${arm#*=}"
        log="${workdir}/${label}-${round}.log"
        timeout --kill-after=30 1500 \
            env LD_PRELOAD="${ATL_HEADLESS_PRELOAD}" LD_LIBRARY_PATH="${prefix}/lib:${ATL_HEADLESS_ICU_DIR}" "${ATL_HEADLESS}" \
            "${here}/workloads/10-speedometer.txt" > "${log}" 2>&1 || true
        atl_headless_wait_helpers "${prefix}"
        score="$(sed -n 's/^\[atl-headless\]   result: //p' "${log}" | head -1)"
        echo "round ${round}  ${label}: ${score:-FAILED}"
        printf '%s\t%s\n' "${label}" "${score:-nan}" >> "${results}"
    done
done

python3 - "${results}" "${arm_a%%=*}" "${arm_b%%=*}" <<'PY'
import statistics, sys
path, a, b = sys.argv[1:4]
scores = {a: [], b: []}
for line in open(path):
    label, value = line.split("\t")
    try:
        scores[label].append(float(value))
    except ValueError:
        pass
print()
print("| build | runs | Speedometer 3.1 (median) | min | max |")
print("|---|---|---|---|---|")
for label in (a, b):
    v = scores[label]
    if v:
        print(f"| {label} | {len(v)} | {statistics.median(v):.2f} | {min(v):.2f} | {max(v):.2f} |")
    else:
        print(f"| {label} | 0 | failed | | |")
if scores[a] and scores[b]:
    ma, mb = statistics.median(scores[a]), statistics.median(scores[b])
    print()
    print(f"{b} vs {a}: {100 * (mb / ma - 1):+.1f}% (noise floor = the min..max spread above)")
PY
