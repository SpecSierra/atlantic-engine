# Fullscreen 1080p YouTube choppiness — investigation

Device: Xperia 10 II, SFOS 5.1.0.11, build **605** (`atlantic-browser-1.0.0.beta7-605.1`,
`wpewebkit2-2.52.5-605.1`). Shipping video config: fence-skip 1, GL sink off,
pipelined ack 0, ack-on-sample 0. Content: m.youtube.com `/watch?v=Jm0MLlE4x0U`,
forced `hd1080` (avc1 via kYouTubeH264 → droidvdec HW decode), DOM fullscreen,
landscape 2520x1080, dpr 3.

Harness (scratchpad): `fsrun.sh` (launch + gesture-driven fullscreen via synthetic
evdev touch), `ensure_play.sh`, `cap.sh` (20 s ATLANTIC_FRAME_TRACE window +
stage stats), `arm.sh` / `ab.sh` (interleaved arms).

## CONFIRMED

- **Decode is not the problem.** `atldbg media`: 25.0 fps decoded, 0 dropped,
  droidvdec active. ftrace `reqcomp r=2` (VideoFrame) arrives every **40.0 ms**
  (p90 41, p95 42) — the source is a rock-steady 25 fps.
- **Presentation is the problem.** Composites/paints run at **20–25 fps** with
  4–13 stalls per 20 s window of **240–800 ms** (worst seen 1.7 s). p50 composite
  interval 37–42 ms; p90 50–60 ms.
- **Every stall is a full-viewport tile repaint.** Inside each gap the trace shows
  `web tilepaint dirty=20 new=0`, then 6–20 consecutive `reqcomp r=2` (VideoFrame)
  requests with **no composite at all** until the tiles land, then composition
  resumes immediately (`scrollapply thr=M` + `web composite` at the gap end).
  These repaints recur every ~5 s, in pairs.
- **Zero pipeline headroom in steady state.** Per-frame stage costs:
  comp→recv 21.8 ms (p95 37.6), recv→paint 8.3, paint→ack 8.0, ack→next comp 1.5
  ⇒ ~40 ms serialized = exactly the 25 fps budget. Any extra work drops a frame.
- **WebProcess RSS grows ~30 MB/s at 1080p only.** 240p: flat 260–320 MB.
  1080p: 355 → 1798 MB in 50 s, then memory-pressure purge sawtooth
  (1.4–1.8 GB). 1.68 GB of it is anonymous heap (kgsl 38 MB, ashmem 30 MB).

## RULED OUT

- **Memory-pressure threshold** (`WEBKIT_MEMORY_BASE_THRESHOLD_MB` 700 → 2400):
  interleaved ABAB × 2, 4 windows/arm. A: 25.1/24.7/23.8/23.4 fps,
  B: 22.8/22.1/24.1/20.8 fps; full-viewport repaints and 240–350 ms stalls present
  in both; RSS reached 1.4–1.7 GB in both. No effect. (An early apparent win was a
  fresh-process vs aged-process confound.)
- **glibc allocator tuning** (`MALLOC_ARENA_MAX=2` + `MALLOC_MMAP_THRESHOLD_=131072`,
  verified present in `/proc/PID/environ`): 82 × 64 MB arenas collapsed into a few
  large VMAs, RSS unchanged at 1.64 GB, fps 18.2–18.7 (no better). The growth is
  live/dirty heap, not arena fragmentation.
- **MSE buffer size** (`MSE_MAX_BUFFER_SIZE=video:40M,audio:6M`, verified applied —
  buffered ahead shrank 385 s → 117 s): stalls unchanged (8 full-viewport repaints,
  4 stalls per 20 s).
- **Low-res tile ladder** (`WEBKIT_LOWRES_TILE_SCALE=1.0`): halves the full-viewport
  repaints (8 → 4 per 20 s — the pairs become singles) but stalls remain
  (247/256/435/528 ms). Partial contributor, not the cause.
- **Captions** (`unloadModule('captions')` + hiding the caption container): no change.
- Previously ruled out (see memory `video-choppy-composite-pipeline`, unchanged):
  damage-limited compositing, pipelined ack (starves decode), GL video sink at 1080p.

## PRIME SUSPECT (code-level, not yet built/verified)

`Source/WebKit/WebProcess/WebPage/CoordinatedGraphics/ThreadedCompositor.cpp`,
`scheduleUpdateLocked()`:

```cpp
case State::Idle:
    m_state.state = State::Scheduled;
    if (!m_state.isWaitingForTiles && !m_suspendedCount.load())
        startRenderTimer();
    break;
```

The Idle path suppresses the render timer whenever `isWaitingForTiles` is set —
**regardless of the composition reason**. A `VideoFrame` request that arrives while
the page is rasterizing tiles is therefore parked until the tile batch completes,
which is precisely the observed 240–800 ms video stall. The correct predicate
already exists in the same file (`isOnlyRenderingUpdatePendingAndWaitingForTiles()`)
and is used in `frameComplete()`; the Idle branch does not use it. Upstream code,
not an Atlantic patch.

Secondary levers (open):
1. Nothing under an opaque fullscreen video layer needs repainting — the ~5 s
   full-viewport repaints are wasted work (source not yet attributed; DOM mutations
   observed are YT captions/progress-bar; `scrollapply thr=M` fires at each gap end).
2. ~30 MB/s allocation churn at 1080p (NV12→RGBA convert on `vqueue:src`, 43 % of a
   core) drives RSS to 1.7 GB and the purge sawtooth.
3. Structural: 40 ms serialized comp→recv→paint→ack leaves no headroom (vsync-paced
   compositing / gralloc EGLImage zero-copy remain the deep fixes).

## PRIOR ART — this exact change was tried once and reverted

- `b13215f` (2026-07-16) "Let scroll composites proceed while waiting for tiles"
  added the identical Idle-branch change as `WEBKIT_INDEPENDENT_SCROLL`'s second
  half, in `webkit-scroll-composite-tile-gate-env.patch`.
- `29b4fc7` (same day) reverted it: franceinfo scroll A/B measured 6.3 → 6.4
  composites/s, flat. Why it was inert *there*: the compositor was not gated, it
  was barely being **asked** — `reqcomp r=8` (AsyncScrolling) fired only 7.3/s
  because the WPE display link dies when the main thread stalls. The revert
  message keeps the finding alive: "The Idle-branch inconsistency … is real and
  may be worth fixing later. Re-land it if it ever pays."

The video case differs on exactly that axis: the requests **do** arrive
(`reqcomp r=2` every 40.0 ms, 6–20 parked per stall). But the revert also exposes
a hole in the evidence above: the ftrace `sched w=` marker reports
`LayerTreeHost::m_isWaitingForRenderer`, **not** `isWaitingForTiles`, so the gate
has never been directly observed — and no `tileschange` marker appears inside the
video stalls, which cuts slightly against the reading. Do not flip the default on
the inference alone.

## WRITTEN (unbuilt, default OFF)

`patches/webkit/webkit-video-composite-tile-gate-env.patch`, registered in
`scripts/patches.sh` after `webkit-frame-trace-env`; export added to
`deploy/runtime-common.sh` (`WEBKIT_VIDEO_COMPOSITE_UNGATED`, default 0):

1. **Diagnostic** (`ATLANTIC_FRAME_TRACE`, no flag needed): new
   `[ftrace] web schedupd st=/r=/wt=/tmr=` marker in `scheduleUpdateLocked()` —
   the first direct view of the tile gate and the pending reason bits.
2. **Fix** (`WEBKIT_VIDEO_COMPOSITE_UNGATED=1`): Idle branch uses
   `isOnlyRenderingUpdatePendingAndWaitingForTiles()` instead of the raw flag.

Generated mechanically (`diff -u` of an edited copy), `patch -p1 --dry-run` clean
against the fully-patched CI tree.

## OPEN — next steps, in order

1. CI build (push required). One build carries both halves.
2. With the flag OFF, capture a fullscreen 1080p window and check `schedupd`:
   the hypothesis predicts `wt=1` on the parked `r=2` requests during each stall.
   If `wt=0`, the gate is exonerated and the real blocker is elsewhere — stop and
   re-diagnose rather than flipping the flag.
3. If confirmed, 5×5 A/B (flag off/on, same page and build) on composites/s,
   stall count and stall p95; flip the default only if it clears noise.
4. Independently of this: the ~5 s full-viewport repaint under an opaque
   fullscreen video is wasted work, and the ~30 MB/s 1080p allocation churn
   (RSS → 1.7 GB) is unexplained. Both remain open.
