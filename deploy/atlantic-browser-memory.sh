#!/bin/sh
# Atlantic: enlarge compressed swap + create a memory-contained cgroup for the
# browser, so a heavy page (e.g. reddit) can't OOM-crash the whole phone.
#
# Why: the Xperia 10 II (3.5 GB RAM) ships ~1 GB zram swap which a heavy web app
# exhausts during scroll — once compressed swap AND physical RAM are gone the
# kernel OOM-killer fires and the device hard-reboots. Device profiling showed
# reddit's WebProcess RSS balloons on scroll (system MemAvailable cratered to
# ~344 MB) while the render path sits idle — a memory problem, not a paint one.
#
# Two levers, both device-agnostic and best-effort (never fail the boot):
#   1. Add a 2 GB lz4 zram device on top of the vendor zram0. zram is compressed
#      RAM (~3.3x on this content) so 2 GB logical costs only ~600 MB physical
#      worst-case. Added via hot_add (additive) so we NEVER swapoff/resize the
#      in-use vendor device (that would fault its contents back into RAM and can
#      itself OOM).
#   2. Create a v1 memory cgroup with a RAM+swap ceiling. The browser .bin
#      self-joins at startup (main.cpp joinBrowserMemoryCgroup), so a runaway
#      page gets its own WebProcess OOM-killed (a tab dies) instead of the phone.
#
# Idempotent: a run marker prevents double-adding zram on service restart.
set -u

MARKER=/run/atlantic-browser-memory.done
[ -e "${MARKER}" ] && exit 0

# Small-RAM devices only (the class this was measured and tuned on). On a
# >= 6 GB device (e.g. the future 12 GB Mali target) the extra zram is pointless
# resident overhead and the 2.0/2.75 GB cgroup ceilings would WRONGLY constrain
# the browser — skip everything. This self-gate is what makes the service safe
# to ship in the public all-in-one bundle for unknown devices.
mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
if [ "${mem_kb:-0}" -ge 6291456 ] 2>/dev/null; then
    echo "atlantic-browser-memory: ${mem_kb} kB RAM >= 6 GB — no swap/cgroup tuning needed"
    : > "${MARKER}" 2>/dev/null || true
    exit 0
fi

# ── 1. Add a 2 GB lz4 zram swap device ───────────────────────────────────────
if [ -w /sys/class/zram-control/hot_add ]; then
    n=$(cat /sys/class/zram-control/hot_add 2>/dev/null || echo "")
    if [ -n "${n}" ] && [ -e "/sys/block/zram${n}/disksize" ]; then
        # lz4 = fast, ~3.3x here (falls through if the algo isn't offered)
        echo lz4 > "/sys/block/zram${n}/comp_algorithm" 2>/dev/null || true
        echo 2147483648 > "/sys/block/zram${n}/disksize" 2>/dev/null || true
        if command -v mkswap >/dev/null 2>&1 && mkswap "/dev/zram${n}" >/dev/null 2>&1; then
            # priority above the vendor zram0 (-2) so the new headroom is used first
            swapon -p 10 "/dev/zram${n}" 2>/dev/null \
                && echo "atlantic-browser-memory: added zram${n} (2G, lz4) as swap"
        fi
    fi
fi

# ── 2. Memory-contained cgroup for the browser (v1 memory controller) ─────────
CG=/sys/fs/cgroup/memory/atlantic
if [ -d /sys/fs/cgroup/memory ]; then
    mkdir -p "${CG}" 2>/dev/null || true
    if [ -d "${CG}" ]; then
        # 2.0 GB physical before swapping; 2.75 GB RAM+swap hard ceiling. Beyond
        # the ceiling the cgroup OOM-killer reclaims a process INSIDE the cgroup.
        # All writes below are idempotent and run every boot — NOT gated on dir
        # creation — so a cgroup left over from a prior run still gets its limits
        # and (critically) its cgroup.procs made writable for the browser join.
        echo 2147483648 > "${CG}/memory.limit_in_bytes" 2>/dev/null || true
        echo 2952790016 > "${CG}/memory.memsw.limit_in_bytes" 2>/dev/null || true
        # charge anon+file pages on immigrate so the cap reflects real usage
        echo 3 > "${CG}/memory.move_charge_at_immigrate" 2>/dev/null || true
        # let the (non-root) browser add itself (unconfined launch path)
        chmod 0666 "${CG}/cgroup.procs" "${CG}/tasks" 2>/dev/null || true
        echo "atlantic-browser-memory: cgroup ${CG} ready (2.0G RAM / 2.75G RAM+swap)"
    fi
fi

: > "${MARKER}" 2>/dev/null || true
exit 0
