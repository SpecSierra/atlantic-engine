#!/bin/sh
# Repair the big CPU cluster's cpufreq governor after vendor init breaks it.
#
# Why: on the Xperia 10 II (Sony "seine", Snapdragon 665) the vendor init
# /vendor/etc/init/init.seine.pwr.rc writes cluster governors while the big
# cores are still being onlined, and under libhybris that race leaves the big
# cluster's governor broken. Two flavours seen on device:
#   - SFOS 5.1.0.7:  cpu4-7 stuck on "powersave" at 300 MHz (the boot-time
#     flip to schedutil never landed) — ~6.7x below the 2.016 GHz the cores do.
#   - SFOS 5.1.0.11: governor READS "schedutil" but its sugov instance is dead:
#     with the WebProcess pegged at 100% for 14+ s the cluster never left the
#     1.056 GHz policy floor (device-proven 2026-07-06). Every CPU-bound page
#     load ran at 52% of achievable clock — theverge DOMContentLoaded 8.7 s
#     stuck vs 2.0 s repaired.
#
# The repair for both flavours is the same: REWRITE the governor, which tears
# down and re-creates the governor instance. A rewritten schedutil ramps
# correctly (device-proven: floor -> 2.016 GHz within 0.5 s of pinned load).
# Belt and braces: after the rewrite, load-probe the policy; if it still can't
# leave the floor, escalate to "performance".
#
# Device-agnostic: targets the cpufreq policy of the highest-indexed CPU
# (Atlantic's "upper half = big cores" convention) and only intervenes when
# that policy currently reads "powersave" or "schedutil" — any other governor
# is a deliberate config and is left untouched. On a healthy device the
# schedutil rewrite is a no-op and the probe passes on the first tick.
set -u

last=$(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | sed 's#.*/cpu##' | sort -n | tail -1)
[ -n "${last:-}" ] || exit 0

pol="/sys/devices/system/cpu/cpu${last}/cpufreq"
gov="${pol}/scaling_governor"
[ -w "${gov}" ] || exit 0

cur=$(cat "${gov}" 2>/dev/null || echo "")
case "${cur}" in
    powersave|schedutil) ;;   # the two known vendor-init-broken states
    *) exit 0 ;;              # never override a deliberate config
esac

avail=$(cat "${pol}/scaling_available_governors" 2>/dev/null || echo "")
case " ${avail} " in
    *" schedutil "*) ;;
    *" performance "*)
        # No schedutil on this kernel — powersave here can only mean broken.
        echo performance > "${gov}" 2>/dev/null || exit 0
        echo "atlantic-cpu-governor: cpu${last} cluster ${cur} -> performance (no schedutil offered)"
        exit 0
        ;;
    *) exit 0 ;;
esac

# The rewrite is the repair: re-creating the governor instance revives a dead
# sugov and replaces a stuck powersave.
echo schedutil > "${gov}" 2>/dev/null || exit 0

# Load-probe the rewritten governor: pin a spinner to this policy's CPUs and
# require the frequency to leave the policy floor within 3 s. Without taskset
# the spinner could land on another cluster and fail the probe spuriously, so
# skip it — the rewrite alone has fixed every broken state seen so far.
ramped=probe-skipped
if command -v taskset >/dev/null 2>&1; then
    floor=$(cat "${pol}/scaling_min_freq" 2>/dev/null || echo 0)
    cpus=$(cat "${pol}/affected_cpus" 2>/dev/null | tr ' ' ',')
    if [ -n "${cpus}" ] && [ "${floor}" -gt 0 ] 2>/dev/null; then
        taskset -c "${cpus}" sh -c 'while :; do :; done' 2>/dev/null &
        spin=$!
        ramped=0
        for _ in 1 2 3 4 5 6; do
            sleep 0.5
            f=$(cat "${pol}/scaling_cur_freq" 2>/dev/null || echo 0)
            if [ "${f}" -gt "${floor}" ] 2>/dev/null; then
                ramped=1
                break
            fi
        done
        kill "${spin}" 2>/dev/null || true
        if [ "${ramped}" = "0" ]; then
            case " ${avail} " in
                *" performance "*)
                    echo performance > "${gov}" 2>/dev/null || true
                    echo "atlantic-cpu-governor: cpu${last} schedutil still floor-stuck after rewrite -> performance"
                    exit 0
                    ;;
            esac
        fi
    fi
fi

echo "atlantic-cpu-governor: cpu${last} cluster ${cur} -> $(cat "${gov}" 2>/dev/null) (rewritten, ramp-probe=${ramped})"
