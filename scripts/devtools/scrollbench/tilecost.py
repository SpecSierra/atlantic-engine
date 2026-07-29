#!/usr/bin/env python3
"""O2: measure per-tile raster cost on a page, via WEBKIT_TILECOST_LOG=1.

Usage:  tilecost.py <page-basename> [seconds]

Launches the browser on file:///home/defaultuser/<page>.html with tile-cost
logging on, drives a fling, and reports the distribution of raster nanoseconds
per painted pixel that the engine measured.

This is the term the scroll ladder is missing. The question it answers: does
raster cost separate a cheap page from an expensive one by enough that a
cost-based trigger could discriminate where a speed-based one cannot? A spread
under ~2x means cost triggering buys nothing over speed; 10x+ validates the
redesign.

Low-res is DISABLED for the measurement (WEBKIT_LOWRES_TILE_SCALE=1.0 plus
WEBKIT_LOWRES_SCROLL_SPEED=99999 so the ladder never arms -- setting the scale
alone does not stop it arming). Otherwise the page would be measured partly at
0.3x scale and the comparison would reflect the controller's own decisions rather
than the content's cost.
"""
import asyncio
import re
import statistics
import sys

sys.path.insert(0, "/release/workspace/atlantic-engine/scripts/devtools")
from atldbg import cdp, device, scroll  # noqa: E402

LINE_RE = re.compile(
    r"\[tilecost\] buf=(\d+)x(\d+) px=([\d.]+) ms=([\d.]+) ns/px=([\d.]+) "
    r"ewma=([\d.]+) n=(\d+)")

ENV = {
    "WEBKIT_TILECOST_LOG": "1",
    "WEBKIT_LOWRES_TILE_SCALE": "1.0",
    "WEBKIT_LOWRES_SCROLL_SPEED": "99999",
    "WEBKIT_CHECKERBOARD_DURING_SCROLL": "0",
}


def summarise(vals, label, unit=""):
    if not vals:
        print(f"  {label}: (no samples)")
        return None
    v = sorted(vals)
    print(f"  {label:24s} n={len(v):4d}  p50={scroll.pct(v,50):8.1f}  "
          f"p90={scroll.pct(v,90):8.1f}  mean={statistics.mean(v):8.1f}{unit}")
    return scroll.pct(v, 50)


async def measure(page, seconds):
    url = f"file:///home/defaultuser/{page}.html"
    device.launch(url, extra_env=ENV, wait=4.0)
    await asyncio.sleep(4)
    mark = scroll.log_mark()
    async with cdp.connect_session() as s:
        await scroll.start(s, "fling", speed=3500)
        await asyncio.sleep(seconds)
        await scroll.stop(s)
    raw = device.ssh(f"tail -n +{mark+1} /tmp/atl.log 2>/dev/null | grep tilecost")
    rows = [LINE_RE.search(l) for l in raw.stdout.splitlines()]
    rows = [m for m in rows if m]
    return {
        "ns_per_px": [float(m.group(5)) for m in rows],
        "ms_per_tile": [float(m.group(4)) for m in rows],
        "px": [float(m.group(3)) for m in rows],
        "ewma": [float(m.group(6)) for m in rows],
    }


async def main():
    pages = sys.argv[1].split(",") if len(sys.argv) > 1 else ["light", "heavy"]
    seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 12.0
    out = {}
    for p in pages:
        print(f"\n=== {p} ===")
        r = await measure(p, seconds)
        if not r["ns_per_px"]:
            print("  ! no [tilecost] lines — is the instrumentation in this build?")
            continue
        out[p] = summarise(r["ns_per_px"], "raster ns per pixel")
        summarise(r["ms_per_tile"], "ms per tile", " ms")
        summarise(r["px"], "painted px per tile")
        print(f"  final EWMA: {r['ewma'][-1]:.1f} ns/px")

    if len(out) >= 2:
        keys = list(out)
        lo, hi = min(out.values()), max(out.values())
        print(f"\nSPREAD across {keys}: {hi/max(lo,1e-9):.1f}x "
              f"(p50 {lo:.1f} -> {hi:.1f} ns/px)")
        print("  <2x  => cost triggering separates pages no better than speed does")
        print("  10x+ => validates the cost-based redesign")


asyncio.run(main())
