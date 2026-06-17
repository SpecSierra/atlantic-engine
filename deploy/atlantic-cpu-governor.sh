#!/bin/sh
# Force the big CPU cluster to the performance governor.
#
# Why: on the Xperia 10 II (Sony "seine", Snapdragon 665) the vendor init
# /vendor/etc/init/init.seine.pwr.rc sets every cluster to "powersave" early in
# boot and is supposed to flip the big cluster to "schedutil" in its `on boot`
# block. Under libhybris that flip lands for the little cluster but not the big
# one (the big cores are governor-written then onlined, so they fall back to the
# kernel-default "powersave"), leaving cpu4-7 pinned at 300 MHz. Atlantic taskset's
# the browser + WPE helpers (WebProcess/Network/GPU, incl. the compositor/paint
# threads) onto exactly that cluster, so they would run ~6.7x slower than the
# 2.016 GHz the cores are capable of. This service repairs that at boot.
#
# Device-agnostic: it targets the cpufreq policy that governs the highest-indexed
# CPU (Atlantic's "upper half = big cores" convention, derived from nproc), and
# only acts when that policy is currently in "powersave" -- so a correctly
# configured cluster (e.g. the future Mali/Dimensity device) is left untouched.
set -eu

last=$(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | sed 's#.*/cpu##' | sort -n | tail -1)
[ -n "${last:-}" ] || exit 0

pol="/sys/devices/system/cpu/cpu${last}/cpufreq"
gov="${pol}/scaling_governor"
[ -w "${gov}" ] || exit 0

# Only intervene on the known-bad state; never override a deliberate config.
cur=$(cat "${gov}" 2>/dev/null || echo "")
[ "${cur}" = "powersave" ] || exit 0

avail=$(cat "${pol}/scaling_available_governors" 2>/dev/null || echo "")
case " ${avail} " in
    *" performance "*) target=performance ;;   # let the big cores fully rev
    *" schedutil "*)   target=schedutil ;;      # fallback: ramp under load
    *) exit 0 ;;
esac

echo "${target}" > "${gov}"
echo "atlantic-cpu-governor: cpu${last} cluster ${cur} -> $(cat "${gov}")"
