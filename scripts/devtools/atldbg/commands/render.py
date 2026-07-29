"""render — debug rendering / frame pacing / paint.

Measures frame cadence with an injected requestAnimationFrame meter (using
in-page performance.now(), which — unlike this build's inspector Timeline records,
whose timestamps come back as 0 — gives real per-frame deltas).  Reports fps,
p50/p95 frame time, jank (frames over the 33 ms budget) and the worst frame.

--scroll drives motion during the window so the raster/paint path is actually
exercised.  Pick the stimulus with --scroll-profile:

  fling  (default)  impulse + kinetic decay + dwell at rest, repeated.  Crosses
                    every velocity threshold and reaches true rest, so engage /
                    degrade / settle / sharpen transitions all get exercised.
  touch             real touchscreen flicks through /dev/input — the actual
                    UIProcess touch + APZ path a finger takes.  Least
                    deterministic, highest fidelity.
  ramp              legacy y+=24 per rAF.  Constant ~1440 px/s, never settles.
                    Kept only to reproduce older numbers; see the warning it
                    prints.

The run always reports the velocity distribution it actually produced and which
scroll tier that lands in, because the recurring trap in this area is assuming
the stimulus instead of measuring it.  With the browser launched under
WEBKIT_SCROLLTIER_LOG=1 it also reports the engine's own tier decisions.
"""
from __future__ import annotations

import asyncio
import json

from .. import cdp, device, scroll, ui
from . import cpu as cpu_cmd

_FPS = r"""
(function(){
  var st = window.__atldbg_fps || (window.__atldbg_fps = {deltas:[], gen:0});
  st.deltas = []; st.last = performance.now();
  var gen = ++st.gen;                 // invalidate any previous running loop
  function tick(now){
    if (gen !== st.gen) return;       // a newer run superseded us
    st.deltas.push(now - st.last); st.last = now; requestAnimationFrame(tick);
  }
  requestAnimationFrame(tick);
  st.stop = function(){ st.gen++; return st.deltas; };
  return 'started';
})()
"""


def _pct(sorted_vals, p):
    return scroll.pct(sorted_vals, p)


def _report_stimulus(vels, th):
    """Print what velocity the run actually produced, and its tier occupancy."""
    if not vels:
        return
    vs = sorted(vels)
    dpr = scroll.DEVICE_PIXEL_RATIO
    print()
    ui.info("scroll stimulus actually produced (page ground truth):")
    ui.kv("velocity (CSS px/s)", f"p50={_pct(vs,50):.0f}  p95={_pct(vs,95):.0f}  "
                                 f"max={vs[-1]:.0f}")
    ui.kv("thresholds in force",
          f"low-res {th['lowres']:.0f}  checkerboard "
          f"{th['checkerboard']:.0f} device px/s"
          + ui.c(f"  (= {th['lowres']/dpr:.0f} / {th['checkerboard']/dpr:.0f} "
                 f"CSS px/s at dpr={dpr:.0f})", "grey"))
    ui.kv("", ui.c(f"source: {th['source']}", "grey"))
    occ = scroll.classify(vs, th, css_px=True)
    parts = []
    for name, style in (("none", "green"), ("low-res", "yellow"),
                        ("checkerboard", "red")):
        frac = occ.get(name, 0.0)
        parts.append(ui.c(f"{name} {100*frac:.0f}%", style if frac > 0.05 else "grey"))
    ui.kv("tier occupancy", "  ".join(parts))
    if occ.get("none", 0) < 0.05:
        ui.warn("this run never reached the full-res tier — it cannot observe a "
                "paint-path change, only how well tiles are AVOIDED.")
        ui.info("to measure the raster path: --env WEBKIT_LOWRES_TILE_SCALE=1.0 "
                "--env WEBKIT_CHECKERBOARD_DURING_SCROLL=0 at launch.")


def _report_tier_log(tier, vels):
    if not tier:
        return
    print()
    ui.info("engine scroll-tier decisions (WEBKIT_SCROLLTIER_LOG):")
    total = max(1, tier["armed"])
    for t, n in sorted(tier["tiers"].items()):
        ui.kv(scroll.TIER_NAMES.get(t, f"tier {t}"),
              f"{n:5d}  ({100.0*n/total:.0f}%)")
    # The estimator check: the engine's speed and the page's own scroll velocity
    # observe the same motion, so a systematic gap is estimator error -- and on a
    # threshold trigger, estimator error IS a false-engage rate.
    if tier["speeds"] and vels:
        es, ps = sorted(tier["speeds"]), sorted(vels)
        ratio = _pct(es, 50) / max(1.0, _pct(ps, 50))
        style = "red" if ratio > 1.5 or ratio < 0.67 else "green"
        ui.kv("engine vs page p50",
              ui.c(f"{ratio:.1f}x", style) +
              f"  (engine {_pct(es,50):.0f} vs page {_pct(ps,50):.0f})")
        if ratio > 1.5:
            ui.warn(f"the engine over-estimates scroll velocity by {ratio:.1f}x — "
                    "it is comparing DEVICE px against page-px intuition.")
    if tier["skips"]:
        sk = sorted(tier["skips"])
        ui.kv("gate rejections", f"{len(sk)} ({100*tier['skip_frac']:.0f}% of samples)"
                                 f"  dt p50={_pct(sk,50):.2f}s max={sk[-1]:.2f}s")
    else:
        ui.kv("gate rejections", ui.c("0", "green") + "  (dt<0.2 gate not firing)")


async def _run(args):
    profile = getattr(args, "scroll_profile", "fling")
    tier_mark = scroll.log_mark() if args.scroll else 0

    async with cdp.connect_session(match=getattr(args, "tab", None)) as s:
        url = await s.eval_value("location.href", default="?")
        ui.heading(f"render — {url}")
        if await s.eval_value("document.hidden", default=False):
            ui.warn("this tab is HIDDEN (screen off, or it's a background tab) — "
                    "rAF is suspended, so no frames will be measured.")
            ui.info("wake the device and bring this page to the foreground, then re-run.")
        await s.eval_value(f"({_FPS})")

        touch_flicks = 0
        if args.scroll:
            desc = await scroll.start(
                s, profile, speed=args.scroll_speed, step=args.scroll_step)
            if profile == "ramp":
                ui.warn("profile 'ramp' is a constant ~1440 px/s and never settles; "
                        "it is pinned inside the low-res tier. Prefer --scroll-profile "
                        "fling (or touch) for anything velocity-gated.")
            ui.info(f"stimulus: {desc}")
            ui.info(f"measuring frames for {args.seconds:.0f}s…")
        else:
            ui.info(f"measuring frames for {args.seconds:.0f}s — scroll/animate now…")

        # sample compositor/raster CPU in parallel with the frame window
        procs = device.processes()
        sample_pids = ([procs["ui"]] if procs["ui"] else []) + procs["web"]
        a = cpu_cmd._read_stats(sample_pids) if sample_pids else {}

        if args.scroll and profile == "touch":
            # host-driven; runs synchronously for the window
            touch_flicks = await asyncio.to_thread(scroll.drive_touch, args.seconds)
        else:
            await asyncio.sleep(args.seconds)

        b = cpu_cmd._read_stats(sample_pids) if sample_pids else {}

        vels = await scroll.read_velocities(s)
        deltas = await s.eval_value("JSON.stringify(window.__atldbg_fps.stop())",
                                    default="[]")
        if args.scroll:
            await scroll.stop(s)

    deltas = [d for d in (json.loads(deltas) if isinstance(deltas, str) else deltas)
              if d and d > 0]
    print()
    if not deltas or len(deltas) < 2:
        ui.warn("no animation frames captured — the page wasn't rendering "
                "(compositor-thread scroll doesn't tick rAF; try --scroll).")
    else:
        deltas.sort()
        n = len(deltas)
        avg = sum(deltas) / n
        fps = 1000.0 / avg if avg else 0
        p50, p95, worst = _pct(deltas, 50), _pct(deltas, 95), deltas[-1]
        jank = sum(1 for d in deltas if d > 33.3)
        fstyle = "green" if fps >= 50 else "yellow" if fps >= 30 else "red"
        ui.kv("frames", f"{n} over {args.seconds:.0f}s")
        ui.kv("avg fps", ui.c(f"{fps:5.1f}", fstyle) + f"  ({avg:.1f} ms/frame)")
        ui.kv("frame time", f"p50={p50:.1f}ms  p95={p95:.1f}ms  worst={worst:.1f}ms")
        ui.kv("jank (>33ms)", (ui.c(str(jank), "red") if jank else ui.c("0", "green"))
              + f"  ({100.0*jank/n:.0f}% of frames)")
        if touch_flicks:
            ui.kv("touch flicks", str(touch_flicks))

    if args.scroll:
        _report_stimulus(vels, scroll.read_thresholds())
        _report_tier_log(scroll.read_tier_log(tier_mark), vels)

    # compositor / raster thread hotspots during the window
    rows = []
    for tid, (comm, j1, owner) in b.items():
        if tid in a:
            dj = j1 - a[tid][1]
            if dj > 0:
                rows.append((dj / (args.seconds * cpu_cmd.CLK_TCK) * 100.0, comm))
    rows.sort(reverse=True)
    hot = [r for r in rows if any(k in r[1].lower() for k in
           ("compos", "scroll", "raster", "skia", "paint", "gl", "render"))][:6]
    if hot:
        print()
        ui.info("render-path threads this window:")
        for pct_, comm in hot:
            print(f"    {ui.c(f'{pct_:5.1f}%', 'yellow')}  {comm}")

    if not args.no_shot:
        try:
            path = device.screenshot(args.shot)
            ui.ok(f"screenshot → {path}  (open it to check for tile corruption)")
        except Exception as e:
            ui.warn(f"screenshot failed: {e}")
    return 0


def run(args):
    return asyncio.run(_run(args))
