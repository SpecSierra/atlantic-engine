#!/usr/bin/env python3
"""Interleaved A/B harness for scroll/raster env toggles.

Usage:  ab.py <spec.json>

spec = {
  "url": "file:///home/defaultuser/light.html",
  "seconds": 10, "reps": 5, "profile": "fling", "speed": 3500,
  "arms": [ {"label":"lowres-off","env":{...}}, {"label":"lowres-on","env":{...}} ]
}

Follows the harness rules in the build-server README: arms are INTERLEAVED
(ABAB, never AABB) so thermal drift loads every arm equally, exactly one browser
instance is asserted per run, and a second independent signal (raster-thread CPU)
is collected alongside fps because fps saturates at the display rate.
"""
import asyncio
import json
import statistics
import sys
import time

sys.path.insert(0, "/release/workspace/atlantic-engine/scripts/devtools")
from atldbg import cdp, device, scroll  # noqa: E402
from atldbg.commands import cpu as cpu_cmd  # noqa: E402

RASTER_KEYS = ("skia", "raster", "compos", "paint")


async def one_run(url, seconds, profile, speed):
    mark = scroll.log_mark()
    procs = device.processes()
    if procs["ui"] is None:
        raise RuntimeError("no browser UI process")
    pids = [procs["ui"]] + procs["web"]
    async with cdp.connect_session() as s:
        await s.eval_value(
            "(function(){var st=window.__f||(window.__f={d:[],g:0});st.d=[];"
            "st.last=performance.now();var g=++st.g;"
            "function t(n){if(g!==st.g)return;st.d.push(n-st.last);st.last=n;"
            "requestAnimationFrame(t);}requestAnimationFrame(t);"
            "st.stop=function(){st.g++;return st.d;};return 1;})()")
        await scroll.start(s, profile, speed=speed)
        a = cpu_cmd._read_stats(pids)
        if profile == "touch":
            await asyncio.to_thread(scroll.drive_touch, seconds)
        else:
            await asyncio.sleep(seconds)
        b = cpu_cmd._read_stats(pids)
        vels = await scroll.read_velocities(s)
        raw = await s.eval_value("JSON.stringify(window.__f.stop())", default="[]")
        await scroll.stop(s)

    deltas = sorted(d for d in json.loads(raw) if d and d > 0)
    if len(deltas) < 5:
        raise RuntimeError("too few frames captured")
    avg = sum(deltas) / len(deltas)
    raster = 0.0
    for tid, (comm, j1, _o) in b.items():
        if tid in a and any(k in comm.lower() for k in RASTER_KEYS):
            dj = j1 - a[tid][1]
            if dj > 0:
                raster += dj / (seconds * cpu_cmd.CLK_TCK) * 100.0
    tier = scroll.read_tier_log(mark)
    # NB: this is the fraction of samples where the tier ARMED, which is not the
    # same as "painted low-res".  WEBKIT_LOWRES_SCROLL_SPEED arms the ladder even
    # when WEBKIT_LOWRES_TILE_SCALE=1.0 has disabled low-res painting, so a
    # control arm legitimately shows ~85% here.  Use it to confirm both arms saw
    # the SAME stimulus, not to infer what was painted.
    return {
        "fps": 1000.0 / avg,
        "p50": scroll.pct(deltas, 50), "p95": scroll.pct(deltas, 95),
        "jank": 100.0 * sum(1 for d in deltas if d > 33.3) / len(deltas),
        "rasterCPU": raster,
        "vel_p50": scroll.pct(sorted(vels), 50) if vels else 0,
        "vel_p95": scroll.pct(sorted(vels), 95) if vels else 0,
        "tier_armed": (100.0 * (tier["tiers"].get(1, 0) + tier["tiers"].get(2, 0))
                       / max(1, tier["armed"])) if tier else None,
    }


def med(rows, key):
    vals = [r[key] for r in rows if r.get(key) is not None]
    return statistics.median(vals) if vals else None


async def main():
    spec = json.load(open(sys.argv[1]))
    url, seconds = spec["url"], spec.get("seconds", 10)
    profile, speed = spec.get("profile", "fling"), spec.get("speed", 3500)
    reps, arms = spec.get("reps", 5), spec["arms"]
    results = {a["label"]: [] for a in arms}

    for rep in range(reps):
        for arm in arms:                      # interleaved: ABAB, never AABB
            label = arm["label"]
            print(f"[{rep+1}/{reps}] {label} …", flush=True)
            device.launch(url, extra_env=arm.get("env", {}), wait=4.0)
            time.sleep(spec.get("settle", 5))
            procs = device.processes()
            if procs["ui"] is None:
                print("   ! no UI process, skipping"); continue
            try:
                r = await one_run(url, seconds, profile, speed)
            except Exception as e:
                print(f"   ! run failed: {e}"); continue
            results[label].append(r)
            print(f"   fps={r['fps']:.1f} p95={r['p95']:.0f}ms jank={r['jank']:.0f}% "
                  f"raster={r['rasterCPU']:.0f}% velp50={r['vel_p50']:.0f}"
                  + (f" armed={r['tier_armed']:.0f}%"
                     if r["tier_armed"] is not None else ""))

    print("\n" + "=" * 78)
    keys = ("fps", "p50", "p95", "jank", "rasterCPU", "vel_p50", "tier_armed")
    print(f"{'arm':16s}" + "".join(f"{k:>12s}" for k in keys) + f"{'n':>4s}")
    print("-" * 78)
    base = None
    for arm in arms:
        rows = results[arm["label"]]
        if not rows:
            print(f"{arm['label']:16s}  (no data)"); continue
        line = f"{arm['label']:16s}"
        for k in keys:
            m = med(rows, k)
            line += f"{m:12.1f}" if m is not None else f"{'-':>12s}"
        print(line + f"{len(rows):4d}")
        if base is None:
            base = {k: med(rows, k) for k in keys}
        else:
            d = ""
            for k in ("fps", "p95", "rasterCPU"):
                m, b = med(rows, k), base.get(k)
                if m is not None and b:
                    d += f"  {k} {100*(m-b)/b:+.1f}%"
            print(f"{'':16s}  vs first arm:{d}")
    # spread, so a delta can be judged against the noise floor
    print("\nper-arm fps spread (min…max):")
    for arm in arms:
        rows = results[arm["label"]]
        if rows:
            f = sorted(r["fps"] for r in rows)
            print(f"  {arm['label']:16s} {f[0]:.1f} … {f[-1]:.1f}  "
                  f"(median {statistics.median(f):.1f})")


asyncio.run(main())
