#!/usr/bin/env python3
"""Compare the engine's scroll-velocity ESTIMATE against ground truth.

Ground truth = per-rAF window.scrollY deltas measured in the page.
Engine estimate = the speed= field the ladder computes from visibleRect deltas.

Both observe the same motion over the same window, so their distributions should
agree.  Any systematic gap is estimator error, and estimator error on a
threshold trigger is exactly a false-engage / false-miss rate.
"""
import asyncio
import statistics
import sys

sys.path.insert(0, "/release/workspace/atlantic-engine/scripts/devtools")
from atldbg import cdp, scroll  # noqa: E402


def pcts(vals, label):
    if not vals:
        print(f"  {label}: (none)")
        return None
    v = sorted(vals)
    n = len(v)
    out = {p: scroll.pct(v, p) for p in (50, 75, 90, 95, 99)}
    print(f"  {label:22s} n={n:4d}  p50={out[50]:8.0f}  p75={out[75]:8.0f}  "
          f"p90={out[90]:8.0f}  p95={out[95]:8.0f}  max={v[-1]:9.0f}")
    return out


async def main():
    seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 15.0
    profile = sys.argv[2] if len(sys.argv) > 2 else "fling"
    mark = scroll.log_mark()
    async with cdp.connect_session() as s:
        url = await s.eval_value("location.href", default="?")
        desc = await scroll.start(s, profile, speed=3500.0)
        print(f"page: {url}\nstimulus: {desc}\nwindow: {seconds}s\n")
        if profile == "touch":
            await asyncio.to_thread(scroll.drive_touch, seconds)
        else:
            await asyncio.sleep(seconds)
        page_v = await scroll.read_velocities(s)
        await scroll.stop(s)

    tier = scroll.read_tier_log(mark)
    eng_v = tier["speeds"] if tier else []

    print("velocity distributions (px/s):")
    p = pcts(page_v, "page (ground truth)")
    e = pcts(eng_v, "engine estimate")
    if p and e:
        print()
        print(f"  engine/page ratio at p50: {e[50]/max(1,p[50]):.1f}x   "
              f"p90: {e[90]/max(1,p[90]):.1f}x")

    print("\ntier occupancy implied by each:")
    for name, vals in (("page (should-be)", page_v), ("engine (actual)", eng_v)):
        occ = scroll.classify(vals)
        if occ:
            print(f"  {name:18s} none={100*occ['none']:5.1f}%  "
                  f"low-res={100*occ['low-res']:5.1f}%  "
                  f"checkerboard={100*occ['checkerboard']:5.1f}%")

    # False-engage rate: engine says degrade while the page is genuinely slow.
    if page_v and eng_v:
        fe = sum(1 for v in eng_v if v >= scroll.LOWRES_THRESHOLD_PXS) / len(eng_v)
        gt = sum(1 for v in page_v if v >= scroll.LOWRES_THRESHOLD_PXS) / len(page_v)
        print(f"\n  degraded fraction: engine={100*fe:.0f}%  truth={100*gt:.0f}%  "
              f"-> over-engage {100*(fe-gt):+.0f} pp")


asyncio.run(main())
