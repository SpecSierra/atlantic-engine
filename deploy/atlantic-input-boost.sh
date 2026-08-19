#!/bin/sh
# Atlantic: arm the SoC's per-touch CPU boost, which SFOS leaves switched off.
#
# Why this is not the governor script's job. atlantic-cpu-governor.sh REPAIRS a
# broken sugov instance so the big cluster can ramp at all; once repaired,
# schedutil is purely REACTIVE — it raises frequency in response to utilization
# that has already been observed (PELT, ~32 ms half-life on this 4.14 kernel).
# So the order after a finger lands is always: touch -> browser wakes -> its
# threads run AT THE IDLE FLOOR -> utilization accumulates -> frequency rises.
# The first work after every touch runs slow, and no governor tunable changes
# that ordering, because the governor's input is load that has not happened yet.
#
# Qualcomm's cpu_boost driver is a different mechanism: it registers its own
# handler on the touchscreen input device and imposes a frequency floor on the
# touch EVENT, before any load exists. It is compiled into this kernel and
# configured to do nothing — SFOS never populates it (Android would).
#
# Device-measured on the Xperia 10 II (build 646.2, 2026-08-18), idle system,
# touch injected and frequency sampled from one process so they share a clock:
#
#   input_boost_freq all zero (the shipped state): 3/3 taps, policy4 never left
#     its 1 056 000 floor within 350 ms.
#   input_boost_freq 1401600 on cpu4-7:            3/3 taps, 1 401 600 reached
#     4-5 ms after touch-down.
#
# SCOPE WARNING: this is system-wide, not browser-scoped. cpu_boost fires on any
# touch anywhere in the OS (lipstick, launcher, other apps). That is why it ships
# DEFAULT OFF and behind an explicit opt-in file rather than simply being set.
#
# Config: /etc/atlantic/input-boost.conf, e.g.
#     ATLANTIC_INPUT_BOOST=1
#     ATLANTIC_INPUT_BOOST_FREQ=1401600   # kHz, applied to the big cluster
#     ATLANTIC_INPUT_BOOST_MS=80          # boost window per touch
#     ATLANTIC_INPUT_BOOST_SCHED=0        # also bias task PLACEMENT to big cores
#
# Best-effort throughout: never fail the boot transaction.
set -u

PARAMS=/sys/module/cpu_boost/parameters
CONF=/etc/atlantic/input-boost.conf

# Default OFF. Absent config = do nothing at all.
ATLANTIC_INPUT_BOOST=0
ATLANTIC_INPUT_BOOST_FREQ=1401600
ATLANTIC_INPUT_BOOST_MS=80
ATLANTIC_INPUT_BOOST_SCHED=0
# shellcheck source=/dev/null
[ -r "${CONF}" ] && . "${CONF}"

[ "${ATLANTIC_INPUT_BOOST}" = "1" ] || {
    echo "atlantic-input-boost: disabled (${CONF} absent or ATLANTIC_INPUT_BOOST!=1)"
    exit 0
}

[ -d "${PARAMS}" ] || {
    echo "atlantic-input-boost: no cpu_boost module on this kernel — nothing to do"
    exit 0
}

# Which CPUs are the big cluster? Derive it rather than hardcoding 4-7, so this
# stays correct on the future Mali target. The big cluster is the policy with
# the highest cpuinfo_max_freq; every CPU sharing that policy gets the floor.
big_cpus=""
best=0
for pol in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -r "${pol}/cpuinfo_max_freq" ] || continue
    f=$(cat "${pol}/cpuinfo_max_freq" 2>/dev/null || echo 0)
    if [ "${f}" -gt "${best}" ] 2>/dev/null; then
        best="${f}"
        big_cpus=$(cat "${pol}/related_cpus" 2>/dev/null || echo "")
    fi
done

[ -n "${big_cpus}" ] || {
    echo "atlantic-input-boost: could not identify the big cluster — skipping"
    exit 0
}

# Never ask for more than the cluster can actually do.
freq="${ATLANTIC_INPUT_BOOST_FREQ}"
if [ "${freq}" -gt "${best}" ] 2>/dev/null; then
    freq="${best}"
fi

# cpu_boost wants a "cpu:freq" pair for EVERY cpu; unlisted ones are not
# implicitly zero on all kernel versions, so state all of them explicitly.
spec=""
ncpu=0
for c in /sys/devices/system/cpu/cpu[0-9]*; do
    n=${c##*/cpu}
    case "${n}" in *[!0-9]*) continue ;; esac
    ncpu=$((ncpu + 1))
done
i=0
while [ "${i}" -lt "${ncpu}" ]; do
    val=0
    for b in ${big_cpus}; do
        [ "${b}" = "${i}" ] && val="${freq}"
    done
    spec="${spec}${i}:${val} "
    i=$((i + 1))
done
# The kernel param parser rejects a trailing separator with EINVAL (device-
# confirmed: the identical string with a trailing space fails, without it
# succeeds), so trim it rather than letting the write silently no-op.
spec="${spec% }"

echo "${spec}" > "${PARAMS}/input_boost_freq" 2>/dev/null || {
    echo "atlantic-input-boost: input_boost_freq not writable — skipping"
    exit 0
}
echo "${ATLANTIC_INPUT_BOOST_MS}" > "${PARAMS}/input_boost_ms" 2>/dev/null || :

# Placement half: bias freshly-woken tasks onto the big cores instead of letting
# them start on a little core and migrate once they have built up utilization.
# Separate knob because it is the untested half — frequency was measured, this
# was not.
if [ -w "${PARAMS}/sched_boost_on_input" ]; then
    echo "${ATLANTIC_INPUT_BOOST_SCHED}" > "${PARAMS}/sched_boost_on_input" 2>/dev/null || :
fi

echo "atlantic-input-boost: big cluster [${big_cpus}] -> ${freq} kHz for ${ATLANTIC_INPUT_BOOST_MS} ms/touch (sched_boost=${ATLANTIC_INPUT_BOOST_SCHED})"
exit 0
