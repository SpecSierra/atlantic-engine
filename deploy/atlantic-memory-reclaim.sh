#!/bin/sh
# Atlantic: reclaim leaked driver-pool memory when free RAM runs low.
#
# Why: the Xperia 10 II vendor kernel (Sony seine 4.14 + CAF) accumulates
# pages in driver pools (ION page pool + an unaccounted pool flagged by
# "BUG: Bad rss-counter state ... idx:4" at WebProcess exit) that its
# shrinkers never release on their own — not even at MemFree ~15 MB with the
# phone swap-thrashing. Device-measured 2026-07-11: after heavy browser use,
# a manual drop_caches recovered 1.6 GB (476 MB ION pool + ~750 MB
# unaccounted pool + page cache) with the phone otherwise "at 2 GB used with
# nothing open"; only a reboot recovered it before.
#
# What: when MemFree drops below the threshold, force the kernel's reclaim
# shrinkers with drop_caches=2 (slab + registered pool shrinkers; page cache
# untouched). If free memory is still critical afterwards, escalate once to
# drop_caches=3 (also drops page cache — costs some reload I/O, far cheaper
# than the OOM reboot it prevents).
#
# Runs from atlantic-memory-reclaim.timer every 2 minutes; each run is a
# no-op unless the threshold is crossed. Best-effort: never fails.
set -u

# Same self-gate as atlantic-browser-memory.sh: this compensates for a
# vendor-kernel bug on the 3.5 GB Adreno device class; on >= 6 GB devices
# (future Mali target) do nothing.
mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
if [ "${mem_kb:-0}" -ge 6291456 ] 2>/dev/null; then
    exit 0
fi

THRESHOLD_KB=${ATLANTIC_RECLAIM_THRESHOLD_KB:-409600}   # 400 MB
CRITICAL_KB=${ATLANTIC_RECLAIM_CRITICAL_KB:-262144}     # 256 MB

free_kb() { awk '/^MemFree:/{print $2}' /proc/meminfo 2>/dev/null || echo 0; }

before=$(free_kb)
[ "${before}" -ge "${THRESHOLD_KB}" ] 2>/dev/null && exit 0

sync
echo 2 > /proc/sys/vm/drop_caches 2>/dev/null || exit 0
sleep 1
after=$(free_kb)

if [ "${after}" -lt "${CRITICAL_KB}" ] 2>/dev/null; then
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    sleep 1
    after=$(free_kb)
    echo "atlantic-memory-reclaim: escalated to drop_caches=3: MemFree ${before} -> ${after} kB"
else
    echo "atlantic-memory-reclaim: drop_caches=2: MemFree ${before} -> ${after} kB"
fi

exit 0
