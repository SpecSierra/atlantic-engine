# franceinfo scroll freeze — root cause, shipped fix, and the remaining decouple

**Date:** 2026-07-14  **Repo:** `SpecSierra/atlantic-engine` (master)

## Symptom
franceinfo (and some other heavy sites) scroll = "content freezes then jumps":
the scroll position advances but the screen doesn't update for 1–3 s (worst
measured 34 s), then snaps to the new position. Random timing.

## Root cause (fully diagnosed, device-proven)
A **production stall**: during scroll the WebProcess composites nothing for
1–3 s between acking one frame and the next composite, because the compositor is
lock-stepped to a large main-thread tile-repaint batch (`isWaitingForTiles` /
`m_isWaitingForRenderer`). The batch is large because **each scroll rendering
update repaints ~the whole viewport** (~2280 tiles). Two contributors:

1. **(FIXED) Full-page repaint from a :root custom-property change.** franceinfo
   writes `--offset-sticky-top/-bottom` onto `<html>` every scroll frame (sticky
   positioning). `RenderBox::styleWillChange` treats any Repaint-level style
   change on `<html>`/`<body>` as `view().repaintRootContents()` — a full
   ~93000px page repaint — even though a custom-property change doesn't paint on
   the root itself. This was the dominant cause (9× per capture, full page).
2. **(RESIDUAL) Legitimate rendering work.** Carousel `RenderFlexibleBox` relayout
   (`repaintAfterLayoutIfNeeded`) and lazysizes image loads
   (`RenderImage::imageChanged`) as content scrolls into view — real tiles for
   real new content, not a bug.

## Shipped fix (commit 56db78f, build 522+, SHIPPED ON build 523+)
`patches/webkit/webkit-root-customprop-repaint-skip-env.patch` +
`WEBKIT_SKIP_ROOT_CUSTOMPROP_REPAINT=1` (now default-on in `deploy/runtime-common.sh`):
`RenderBox::styleWillChange` skips `repaintRootContents()` when the `<html>`/`<body>`
change is a custom property (`!customPropertiesEqual`). Device-verified: full-page
repaints → 0, worst scroll freeze ~34 s → ~3.3 s, no visual regression. A/B with
`WEBKIT_SKIP_ROOT_CUSTOMPROP_REPAINT=0`.

## The remaining work: decouple scroll from the main-thread rendering update
Residual freezes (~1–3 s, occasional; p95 frame ~150 ms ≈ 10 fps during scroll)
remain because:
- The residual repaints are **legitimate** (new content) — no more over-invalidation
  to kill cheaply.
- **Scroll input is main-thread-coupled**: touch/scroll events hit-test on the main
  thread (`EventHandler::handleWheelEvent → Document::hitTest →
  wheelEventWasProcessedByMainThread → lockSlow`), so while the main thread paints
  the tile batch (~3 s), scroll input can't flow and the **scrolling thread stops
  producing scroll frames** (`ftrace` shows `scrollapply=0` during every freeze).

**Decouple goal:** let the scrolling thread keep compositing already-painted content
at vsync (checkerboard/low-res for not-yet-painted regions) while new tiles paint
async — i.e. scroll smoothness independent of repaint volume.

**Important dead-ends / gotchas learned:**
- `ThreadedCompositor::scheduleUpdateLocked`'s `isWaitingForTiles` gate (Idle case)
  is NOT the blocker — the `Scheduled` case starts the render timer regardless. The
  block is upstream: the scrolling thread isn't *requesting* AsyncScrolling composites
  during the freeze. So a scheduleUpdateLocked tweak alone won't help.
- This is the `composition←tiles←flush` / `m_isWaitingForRenderer` handshake that the
  load-rendering-throttle effort found deadlock-prone and abandoned (see memory
  `franceinfo-load-slowness-analysis`). Do NOT defer rendering updates.
- Likely needs: (a) route scroll input to the scrolling thread without a blocking
  main-thread hit-test (extend `WEBKIT_FORCE_ASYNC_SCROLL` / the touch-ack path), and/or
  (b) let the scrolling thread self-drive AsyncScrolling composites during a main-thread
  update. Env-gate everything; expect several iterations.

## Diagnostic tooling (built, shipped default-off, reuse for the decouple)
- `ATLANTIC_FRAME_TRACE=1` — `[ftrace]` CLOCK_MONOTONIC markers across the pipeline
  (`web composite/reqcomp/sched/rupd/rupd-end/scrollapply/wtiles-set/tileschange/
  tilepaint`, `ui recv/paint/ack`). Patch: `webkit-frame-trace-env.patch` (WebProcess)
  + `qt5-plugin/WPEQtViewBackend.cpp` (UI).
- `/root/ftrace.py` — pulls `/tmp/atl.log`, finds production/present freezes, verdicts
  (production stall / tiles-painting / stuck-flag / scheduler-starved).
- `WEBKIT_PAINT_LOG=1` — `[paintlog] GLC ... RECT`, `proxy PAINT/INVAL` (invalidation
  rects + tile counts).
- `ATLANTIC_REPAINT_BT=1` — throttled symbolized backtrace at each large repaint-rect
  invalidation (names the trigger). Symbolize offsets with
  `addr2line -f -C -e /opt/github-runner/cache/atlantic-build/wpe-sfos-prefix/lib/libWPEWebKit-2.0.so.1.9.8 0xOFFSET`
  (device lib symbols need debuginfo; the build-host lib has full DWARF).
- Device tunnel is flaky under scroll load: `grep` on-device then `scp` the subset;
  `cat` of the big log truncates. Symbolization + ftrace are the oracle for any fix.
