# Handover — decouple video presentation from the main thread

**Date:** 2026-07-23
**Repos:** `SpecSierra/atlantic-engine` (master, pushed through `9e0569a`),
`SpecSierra/atlantic-browser` (untouched so far)
**Device build at handover:** `wpewebkit2-2.52.5-606.1`, `atlantic-browser-1.0.0.beta7-606.1`
**Running investigation log:** `/release/workspace/atlantic-engine/INVESTIGATION.md`
**Harness:** `/root/handover/video-harness/` (copied out of the session scratchpad)

## The ask

Fullscreen 1080p YouTube has been choppy since the browser's early days. This
session root-caused it. The answer is *not* the decode path and *not* the
compositor: **presentation is coupled to the main thread, and any long main-thread
pass freezes the video for its whole duration.** This handover is for building
that decoupling.

Note the honest split of the remaining work:

- **Track A (cheap, ours, do it first):** one of the long main-thread passes is our
  own injected user script. Removing it is a browser-side change, no WebKit
  rebuild. It will visibly help but it does not make video robust.
- **Track B (this document):** YouTube's own timers also run 283-490 ms on the
  main thread and we cannot fix those. As long as presentation waits on the main
  thread, any heavy page will stutter video. Track B is the real fix.

## What is measured and settled

Reproduce with: `/root/handover/video-harness/fsrun.sh --env ATLANTIC_FRAME_TRACE=1`
then `ensure_play.sh`, then `cap.sh out.log 20`. (`fsrun.sh` enters DOM fullscreen
by arming a `touchend` handler and firing a synthetic evdev touch — no phone
interaction needed. Device stays in landscape, 2520x1080, dpr 3.)

1. **Decode is clean.** 25.0 fps decoded, 0 dropped, droidvdec HW path.
   `reqcomp r=2` (VideoFrame) arrives every 40.0 ms, p95 42 ms.
2. **Presentation is not.** 20-25 fps composites with 3-13 stalls per 20 s window
   of 230-800 ms (worst seen 1.7 s). That bursty pattern is the judder.
3. **Each stall is a pegged main thread, not compositor work.** Per-thread
   sampling (`tsample2.py`, 25 ms, CLOCK_MONOTONIC, correlated to the ftrace
   composite stream) over 7 stalls:

   | thread | during stall | whole window |
   |---|---|---|
   | `WPEWebProcess` (main) | **57-100 %**, R/D | 60 % |
   | `eadedCompositor` | **4-9 %, sleeping (S)** | 37 % |
   | `SkiaCPUWorker` | 0-8 % | low |
   | `vqueue:src` | 26-58 % | 42 % |

4. **The compositor is parked, mid-composite.** `schedupd` (new marker, see below)
   shows `st=2/3` (InProgress / ScheduledWhileInProgress) with `tmr=0` for the
   whole stall, and `wt=0` — it is *not* the tile gate. The previous frame's
   `ui recv/paint/ack` completed normally at +36/+44/+50 ms.
5. **Main-thread attribution** (`atldbg profile -s 15`, fullscreen 1080p):

   | self-time | calls | max | call site |
   |---|---|---|---|
   | 1862 ms | 30 | 283 ms | `timeout` — ytmweb `c@…c3_base…` |
   | 1122 ms | 29 | **949 ms** | `raf` — `schedule@user-script:7:127` = **ours**, `kYouTubeIconFix` |
   | 1018 ms | 84 | 490 ms | `timeout` — YT `player…base.js` |

6. **Side finding, unexplained:** 1080p playback churns ~30 MB/s of heap
   (RSS 355 -> 1798 MB in 50 s; 240p is flat at ~280 MB), with NV12->RGBA convert
   burning 43 % of a core on `vqueue:src`. Not the cause of the stalls (the
   memory-pressure threshold A/B was flat) but it is a real 3.5 GB-device problem.

## The suspected coupling — verify this first

`ThreadedCompositor::renderLayerTree()` runs, in order (2.52.5,
`Source/WebKit/WebProcess/WebPage/CoordinatedGraphics/ThreadedCompositor.cpp`):

```
willRenderFrame -> flushCompositingState(reasons) -> paintToCurrentGLContext(...)
```

The ftrace `web composite` marker is emitted at the top of
`paintToCurrentGLContext` (:355), i.e. **after** the flush. The compositor sleeps
through the stall and the marker only appears at the end, so the block is almost
certainly inside `flushCompositingState()` — which walks every committed layer:

- `ThreadedCompositor::flushCompositingState` (:307-350) calls
  `m_sceneState->rootLayer().flushCompositingState(reasons)` and the same for each
  `m_sceneState->committedLayers()`.
- `CoordinatedPlatformLayer::flushCompositingState`
  (`Source/WebCore/platform/graphics/texmap/coordinated/CoordinatedPlatformLayer.cpp:908`)
  starts with `Locker locker { m_lock };` — a **per-layer lock**.
- The main thread takes that same `m_lock` in ~10 places (setters, backing-store /
  contents updates) while it services a rendering update.

So: main thread inside a long JS/style/layout/paint pass holds layer locks ->
compositor blocks in the flush -> VideoFrame composites cannot present, even
though the video buffer is already in the proxy and needs none of that state.

**Confirm before designing:** attach gdb to the WebProcess and grab the
`eadedCompositor` backtrace *inside* a stall. Stalls recur every ~5 s and last
230-460 ms, so a stop/`bt`/continue loop at ~100 ms lands in one within a few
dozen samples. Device lib is unstripped and gdb-loop sampling is known to work
here (see memory `reddit-style-resolver-purge-thrash`). Do **not** gdb a core file
(6 GB, thrashes the phone). What we need from the backtrace: the exact wait —
`CoordinatedPlatformLayer::m_lock`, `m_sceneState` lock, the scrolling-tree lock,
or `waitUntilPaintingComplete`.

If it is the scrolling-tree lock, note `WEBKIT_COMPOSITE_SCROLL_SYNC` (default ON,
`webkit-composite-scroll-sync-*` patches) holds `scrollingTree->treeLock()` across
the whole flush — but only for `RenderingUpdate`/`AsyncScrolling` reasons, so a
VideoFrame-only composite should skip it. Cheap env A/B: `=0`.

## Design directions, cheapest first

1. **Video-frame fast path.** A `VideoFrame`-only composite needs the video layer's
   contents buffer and the existing scene; it does not need to flush pending layer
   changes at all. `flushCompositingState` already early-outs per layer when
   `m_pendingChanges.isEmpty()` — but it must take `m_lock` to find that out.
   Options: `tryLock()` and skip the layer this frame when the main thread holds it
   (a VideoFrame composite may safely render last-committed state), or hoist an
   atomic "has pending changes" flag checked before locking. Small, targeted,
   env-gated. Risk: a layer whose changes are skipped shows one stale frame — the
   same trade the tile-upload budget already makes.
2. **Vsync-paced compositing.** The deeper fix noted since July: composites driven
   by the display refresh instead of the ack handshake. Also removes the zero
   headroom below. Medium/large; interacts with `ATLANTIC_PIPELINED_FRAME_ACK`
   (currently 0 because a free-running compositor starves decode) and
   `ATLANTIC_ACK_ON_SAMPLE`.
3. **Zero-copy video (gralloc EGLImage import + video subsurface).** Removes the
   per-frame NV12->RGBA CPU convert (43 % of a core, and the suspected source of
   the 30 MB/s churn) and, with a subsurface, takes video presentation off the
   web-content composite path entirely. Biggest win, biggest job; RooTitanium-class.

Independent of all three: **steady state has zero headroom.** comp->recv 21.8 +
recv->paint 8.3 + paint->ack 8.0 + 1.5 = ~40 ms serialized, exactly the 25 fps
budget. Even a perfect fix leaves 30 fps content marginal until (2) or (3).

## Do not repeat these — ruled out with device evidence

| Lever | Verdict |
|---|---|
| `WEBKIT_VIDEO_COMPOSITE_UNGATED` (Idle-branch tile gate, `f53255e`) | **Inert.** `schedupd` shows `wt=0` on every parked request. Keep default OFF. Second time this idea has been disproven — the first was `b13215f`/`29b4fc7` for scroll. |
| `WEBKIT_MEMORY_BASE_THRESHOLD_MB` 700 vs 2400 | Flat (interleaved ABAB x2). |
| `MALLOC_ARENA_MAX` / `MALLOC_MMAP_THRESHOLD_` | RSS unchanged, fps slightly worse. |
| `MSE_MAX_BUFFER_SIZE` (cap verified applied) | Stalls unchanged. |
| `WEBKIT_TILE_UPLOAD_REST_BUDGET_MB=2` | Flat. |
| `WEBKIT_TILE_UPLOAD_BUDGET_SCROLL_ONLY=0` + `BUDGET_MB=4` | Flat. |
| `WEBKIT_LOWRES_TILE_SCALE=1.0` | Halves the full-viewport repaints (8->4 per 20 s), stalls remain. |
| Captions off | No change. |
| Damage compositing, pipelined ack, GL video sink at 1080p | Previously ruled out, see memory `video-choppy-composite-pipeline`. |

## Tooling added this session

- **`[ftrace] web schedupd st= r= wt= tmr=`** (in
  `patches/webkit/webkit-video-composite-tile-gate-env.patch`, active whenever
  `ATLANTIC_FRAME_TRACE=1`): compositor state machine + pending composition
  reasons + `isWaitingForTiles` at each schedule call. This is the marker that
  killed the tile-gate theory. Note the older `web sched w=` marker reports
  `LayerTreeHost::m_isWaitingForRenderer`, which is a different flag — do not
  confuse them.
  Reason bits: 1 RenderingUpdate, 2 VideoFrame, 4 Animation, 8 AsyncScrolling,
  16 TileDrain. States: 0 Idle, 1 Scheduled, 2 InProgress, 3 ScheduledWhileInProgress.
- **`/root/handover/video-harness/`**
  - `fsrun.sh [--env K=V …]` — relaunch, force 1080p, enter fullscreen via synthetic touch
  - `ensure_play.sh` — YT autoplay is flaky and a tap toggles pause; this retries until `playing:1920`
  - `cap.sh <out.log> [s]` — capture an ftrace window and print source/composite/paint rates, full-viewport tilepaints, stall list
  - `arm.sh` / `ab.sh` / `armE.sh` — fresh-launch arms and interleaved A/B
  - `tsample.py <comm> <s> [ms]`, `tsample2.py <s> [ms]` — per-thread state/CPU sampling on CLOCK_MONOTONIC (run on device, `devel-su -p python3`)
  - `rssslope.sh <quality> <s>` — RSS growth vs video resolution
  - `vbench.sh` — `requestVideoFrameCallback` presented-frame cadence (noisy in WPE; prefer ftrace)

## Traps that cost time here

- **Aged process vs fresh process.** A browser that has been playing for minutes
  measures much worse than a fresh one (RSS 1.7 GB, more stalls). An early
  "memory threshold fixes it" result was entirely this confound. Always relaunch
  per arm and interleave ABAB.
- **The tap that enters fullscreen also toggles play/pause** on the YT player.
  Always verify `paused=false` and `videoWidth=1920` before a capture — several
  captures measured a paused page (composites at 41/s, no `r=2`) before
  `ensure_play.sh` existed.
- `atldbg eval` occasionally lands in a cross-origin subframe (`SecurityError`);
  just retry.
- `atldbg` opens its own inspector tunnel — kill any manual `-L 9224` first.
- `pgrep -f`/`pkill -f` match the invoking shell's own argv; bracket-escape, and
  never chain a `pkill` with the run it is killing.

## Suggested order of work

1. gdb-confirm the compositor's wait inside a stall (above). Everything else keys
   off which lock it is.
2. Track A: fix `kYouTubeIconFix` (`apps/wpe/WPEUserScripts.h:408`) — debounce the
   scan, scope the `MutationObserver` to the player controls instead of
   `document.documentElement` with `subtree:true`, and skip while a video is
   playing / fullscreen. It re-scans the whole document on every mutation batch and
   YouTube mutates ~13/s during playback. Browser-side; also a plausible source of
   the ~5 s `dirty=20` full-viewport invalidation (the scan writes inline styles).
3. Track B design 1 (video-frame fast path), env-gated default OFF, then 5x5 A/B
   on composites/s, stall count and stall p95 with the harness above.
4. Revisit the ~30 MB/s 1080p heap churn; it is the other half of why this device
   struggles with fullscreen video.
5. Decide whether to drop the now-inert `WEBKIT_VIDEO_COMPOSITE_UNGATED` flag
   (keep the `schedupd` marker regardless).
