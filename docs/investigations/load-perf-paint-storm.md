> **Status: PARTLY CLOSED** — The load-rendering throttle is abandoned as unfixable (compositor `composition<-tiles<-flush` deadlock) — do not retry. The remaining open job is the per-frame layout/repaint storm.
>
> Archived `handover/load-perf-paint-storm-handover.md` (build host `/root`), 2026-07-30.

# Load-time performance / paint storm — Handover

**Date:** 2026-07-08
**Repo:** `SpecSierra/atlantic-engine` (all commits on `master`)
**State as of build 472 (`130f060`):** load-rendering throttle DROPPED ENTIRELY — unfixable freeze. Back to build 468's stock rendering. Jobs 1 & 2 are CLOSED (won't-fix); Job 3 remains open.

> **UPDATE 2026-07-08 — throttle abandoned (do not retry).** Coalescing
> main-thread rendering updates during load fundamentally deadlocks the
> compositor `composition<-tiles<-flush` handshake: moving during a load reveals
> content whose tiles are painted by `updateRendering()`, and deferring that
> paint sticks `m_isWaitingForRenderer` true forever = permanent freeze. Tried
> every enforcement point and all froze on move-during-load: parts 2/3 (465-467,
> timer in scheduleRenderingUpdate), observer-defer (469), observer + one-shot
> `WebCore::Timer` wakeup (470, fixed quiet-load but onche still froze), and
> observer+timer + `isCompositionRequiredOrOngoing()` gate (471, onche STILL
> froze). The freeze state itself (`m_isWaitingForRenderer` stuck) makes the
> observer return early before any gate/cap runs, so it can't be gated out. It
> also never moved DCL (raster is on Skia worker threads) — upside was only
> battery/thermals. Both patches (`-env`, `-observer`) + the env var are removed;
> `-layertreehost`/`-lossproof` deleted. **If revisited, target style-recalc /
> layout coalescing OFF the compositor path — never rendering-update cadence.**
> Full detail in memory `franceinfo-load-slowness-analysis.md`.
**Full investigation log:** `~/.claude/projects/-root/memory/franceinfo-load-slowness-analysis.md`

Context: franceinfo.fr (proxy for "heavy news site") loads in DCL 5–10s. Root-caused:
main thread is CPU-bound ~8s per load, ~half serialized ES-module JS evaluation,
~half repeated restyle→layout→paint passes. The paint side is a genuine storm:
**8,856 renderer repaint rects per load, all via `repaintAfterLayoutIfNeeded`**
(one pass per landing script/stylesheet/image), re-rastering the visible tiles
~100× (396 tile-paint passes, ~340 Mpx = 130 screenfuls). The invalidations are
*correct* — the problem is cadence, not breadth.

---

## Job 1 — Verify build 468 fixed the rendering freeze (URGENT, blocks everything)

Builds 465–467 shipped a "load rendering throttle" that caused rendering freezes:
pages stop repainting during load (deterministic repro: **swipe while reddit.com
is loading**); 467 made it worse (pages never fully render). Build 468 reverts the
two LayerTreeHost patches and ships `WEBKIT_LOAD_RENDERING_INTERVAL_MS=0`.

To do once the device tunnel is back:
1. `zypper ref atlantic-ci-v2 && zypper up wpewebkit2 wpewebkit2-qt5 atlantic-browser` → confirm `wpewebkit2-2.52.4-468.1`.
2. Run the repro: openUrl reddit.com; ~2s in, 4× `swipe.py 540 1900 540 700`; then
   via inspector arm a rAF counter (`window.__c=0; rAF loop incrementing`) and read
   it twice a few seconds apart. **Counter advancing = fixed.** On 466/467 it
   wedged at 0 permanently (page taps did NOT unstick it; only Qt-chrome interaction did).
3. Also sanity-load reddit.com / onche.org / franceinfo.fr by hand.

Why the freeze happened (so nobody re-introduces it): the RenderingUpdate
RunLoopObserver in `LayerTreeHost` is **`Type::Repeating`** — it fires every
main-loop iteration until `updateRendering()` invalidates it, so stock can never
lose a pending update even when `m_isWaitingForRenderer` blocks it for a while.
Part 2 deferred the observer *scheduling* with a one-shot timer, breaking that
self-healing; part 3 added recovery flags built on a wrong "dropped latch" theory.

Reference (removed from build, files kept):
- `patches/webkit/webkit-load-rendering-throttle-layertreehost.patch` (part 2)
- `patches/webkit/webkit-load-rendering-throttle-lossproof.patch` (part 3)
- Still applied but inert: `webkit-load-rendering-throttle-env.patch` (part 1,
  Page-side clamp — this port paces updates in LayerTreeHost, not
  RenderingUpdateScheduler/DisplayLink, so it does nothing; env ships =0).

## Job 2 — Retry load-time paint coalescing, done right (optional, ~1.5–2.5s + battery)

The measured win exists: with throttling active, painted pixels per load dropped
35–50% (231–359 Mpx vs 458–468 Mpx control) with clean visuals (3s mid-load
screenshot fine). But DCL did not move (noise-bound 3.7–5.9s warm) — raster is
mostly on Skia worker threads. Value = battery/thermals/bandwidth + fewer
worst-case stalls, NOT headline load time. Decide if it's worth it before coding.

Hard constraints learned (violating either = 465-style freeze):
- **Never defer the run-loop observer scheduling.** Throttle *inside*
  `LayerTreeHost::updateRendering()` (early-return while leaving the repeating
  observer scheduled — it will re-fire next iteration) or at the
  dirty-region/paint level (`CoordinatedBackingStoreProxy::updateIfNeeded`:
  accumulate dirty tiles, only paint every N ms during load).
- Beware the compositor tiles handshake: `requestCompositionForRenderingUpdate`
  sets `isWaitingForTiles` when the scene has bufferless pending tiles; the
  scroll-ladder (checkerboard/low-res) patches create exactly those. Any change
  that delays the flush that paints them risks a
  composition⇠tiles⇠flush⇠composition cycle.
- The load window signal (ProgressTracker → `Page::setRenderingThrottledForLoad`,
  part-1 patch) works and can be reused; add a max-duration cap (~10s) — reddit/
  onche keep progress open indefinitely.

Measurement kit (all device-proven):
- `WEBKIT_PAINT_LOG=1` diagnostic patch (in build): `[paintlog]` lines on the
  launcher's stdout — `PAINT dirtyTiles/union`, `GLC FULL/RECT`, `INVAL`,
  `DROP-ALL`. Aggregate with `scratchpad paintrects.py`-style scripts.
- gdb breakpoints work (lib unstripped, NO DWARF: no member reads, symbols only;
  `timeout` doesn't exist on device; re-pgrep pid each run).
- Launch-env gotcha: after the browser was opened from the phone UI, ssh launches
  land in firejail and DROP shell env — profile env lines live in
  `/etc/sailjail/permissions/atlantic-browser.profile` (regenerated each build).
  Reboot gives a clean slate. `pkill -f` patterns matching your own ssh cmdline
  kill your session — bracket-escape (`atlantic-browser.bi[n]`).

## Job 3 — The bigger rocks: JS module eval + repeated full-page layouts

What actually dominates franceinfo's 8s of main-thread time (post-cache,
post-governor fixes):
- **~3–4s: serialized top-level evaluation of ~41 ES-module scripts** (+ analytics
  `sdk.js`). Not timers/rAF (those total <40ms) — module boot code. Invisible to
  atldbg profile; visible as JIT frames in gdb samples.
- **~2–3s: ~20 full-page (1080×95714!) flex layouts + 37 style recalcs** — one per
  landing resource batch. JS-forced sync layouts bypass any rendering-update
  batching. Stacks: `Style::TreeResolver`/pseudo-elements, `RenderFlexibleBox`
  (carousel strips 23460×1269, 31080×864).

Ideas not yet explored (in rough order of promise):
1. Style-recalc batching: each late-arriving stylesheet invalidates the whole
   document (42 sheets on franceinfo). Look at coalescing sheet-arrival
   invalidations during load.
2. Off-main-thread / deferred module compilation knobs (JSC has background
   compile; check what this build enables for modules).
3. Layout containment heuristics are OFF the table (`content-visibility` halved
   fps on reddit — see memory reddit-perf-content-visibility).
4. Measure first with the Timeline event-count harness (`tlcount.py` pattern —
   NOTE: Timeline timestamps are all 0 in this build, counts only) + gdb sampling.

## Quick device-testing crib

```sh
SSH="sshpass -p root ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null defaultuser@localhost"
# clean instrumented launch (after reboot, or after pkilling firejail/invoker/bwrap/WPEWebProcess):
$SSH 'export XDG_RUNTIME_DIR=/run/user/100000; export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/100000/dbus/user_bus_socket
export WEBKIT_INSPECTOR_HTTP_SERVER=0.0.0.0:9224 WEBKIT_PAINT_LOG=1
setsid /usr/bin/atlantic-browser >/tmp/atl.log 2>&1 </dev/null &'
# inspector tunnel (run detached; never pkill with a pattern that matches this cmdline):
sshpass -p root ssh -p 2222 ... -N -L 9224:127.0.0.1:9224 defaultuser@localhost &
# eval JS in visible tab: /root/wkeval.py '<js>'   (stale tunnel: kill the sshd pid holding :2222 on THIS host and the device re-establishes)
```

Timeline of relevant commits (all `atlantic-engine` master):
`ec96dac` layer-resize repaint fix (shipped 462+, verified harmless, kept) →
`7ad0ac6` WEBKIT_PAINT_LOG diagnostic (kept, off by default) →
`4ac8a7a` throttle part 1 (kept, inert) → `8023ffb` part 2 (REMOVED from build) →
`61dd966` part 3 (REMOVED from build) → `d760fee` revert = build 468.
