> **Status: RESOLVED build 607** — The compositor was futex-blocked on `CoordinatedPlatformLayer::m_lock` held by the main thread. `WEBKIT_COMPOSITE_SKIP_LOCKED_LAYERS` took 33 stalls to 0 over a 5x5 A/B and is default-ON. Eight other theories are recorded as ruled out — check them before proposing a new one.

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

## RULED OUT (build 606) — the tile gate, disproven by its own diagnostic

Build 606 (`f53255e`) installed and verified on device (`schedupd` +
`WEBKIT_VIDEO_COMPOSITE_UNGATED` strings present in the shipped
`libWPEWebKit-2.0.so.1.9.9`). With the flag OFF, fullscreen 1080p, 20 s window
(24.2 fps, 3 stalls of 257/294/290 ms), **every parked `reqcomp r=2` carries
`wt=0`** — `isWaitingForTiles` is not set, so the Idle-branch gate is not what
blocks them. Same verdict as the 2026-07-16 scroll attempt, for the same reason:
the gate is innocent. `WEBKIT_VIDEO_COMPOSITE_UNGATED` is therefore inert and must
stay OFF; the `schedupd` marker keeps its value.

What `schedupd` shows instead: state (`st`) is 2 (InProgress) / 3
(ScheduledWhileInProgress) for the whole stall, with `tmr=0`. The preceding frame
completed normally (`ui recv/paint/ack` at +36/+44/+50 ms). Then a composite starts
and **does not finish for ~240 ms** — no `ui recv` for it at all. The stall is one
long composite, immediately after `tilepaint dirty=20`.

Two env A/Bs against that (both flat, ~3-4 stalls of 230-280 ms per 20 s):

- `WEBKIT_TILE_UPLOAD_REST_BUDGET_MB=2` (was 16): 25.0 / 24.8 fps, stalls
  258/282/232 and 276/274/259/280 ms. Not upload volume.
- `WEBKIT_TILE_UPLOAD_BUDGET_SCROLL_ONLY=0` + `BUDGET_MB=4` (meter every
  composite, the path documented as never blocking on still-painting buffers):
  24.8 / 25.3 fps, stalls 270/237/246 and 260/261/242/253 ms. Not the metering
  or the `waitUntilPaintingComplete` block either.

## CONFIRMED (build 606) — the stall is the MAIN thread, and part of it is ours

Per-thread sampling (`tsample2.py`, 25 ms, CLOCK_MONOTONIC, correlated with the
ftrace composite stream) over 7 stalls of 229-463 ms:

| thread | CPU during stall |
|---|---|
| `WPEWebProcess` (main, tid 30421) | **57-100 %** (states R/D) |
| `vqueue:src` | 26-58 % |
| `droidvdec0:src` / `DroidMediaCodec` | 8-26 % |
| `eadedCompositor` | **4-9 %, mostly sleeping (S)** |
| `SkiaCPUWorker` | 0-8 % |

So the compositor is not doing a long composite and is not painting — it is
*asleep*, waiting on a main thread that is pegged. (Whole-window baseline for
contrast: main 60 %, compositor 37 %.) This is the same shape as the July
franceinfo finding (main 92 %, compositor 16 %).

`atldbg profile -s 15` in fullscreen 1080p attributes the main thread:

| self-time | calls | max | call site |
|---|---|---|---|
| 1862 ms | 30 | 283 ms | `timeout` — ytmweb `c@…c3_base…` |
| **1122 ms** | **29** | **949 ms** | **`raf` — `schedule@user-script:7:127:64`** |
| 1018 ms | 84 | 490 ms | `timeout` — YT `player-plasma-ias-phone…base.js` |

`user-script:7:127` is **ours**: `WPEUserScripts::kYouTubeIconFix`
(`apps/wpe/WPEUserScripts.h:408`, the `requestAnimationFrame(run)` at :534 inside
`schedule()`). It hangs a `MutationObserver` on `document.documentElement` with
`{childList, subtree}` and re-runs a whole-document `scan()` on every mutation
batch, plus `setInterval(scan, 800)`. YouTube mutates constantly during playback
(measured: 644 mutations in 49 s — caption window ~3.5/s, progress bar ~1.7/s), so
the icon fix re-scans the document several times a second while the video plays,
for up to 949 ms in a single callback. YouTube's own timers account for the rest.

That also explains why every engine-side lever measured flat: the compositor was
never the bottleneck.

## CONFIRMED (build 606) — the compositor blocks on a futex held by the main thread

Root `/proc/<tid>/syscall` + `/proc/<tid>/stack` sampling at 20 ms
(`video-harness/tsample3.py`), correlated with the ftrace composite stream.
Seven stalls in one 24 s window (235-796 ms):

- **5 of 7: `syscall 98 = futex`**, 15-25 consecutive samples, kernel stack
  `futex_wait_queue_me -> futex_wait -> do_futex`, with the main thread reading
  `R:running` for the entire stall. Userspace lock contention, not GPU, not I/O.
- 1 of 7: compositor in `D` state with `do_page_fault` stacks — the RSS-1.7 GB
  thrash, a separate problem.
- 1 of 7: compositor in `ppoll` throughout — genuinely idle, not blocked. Looks
  like the ack handshake, not contention.

Whole-window baseline for contrast: compositor `R:running` 299 samples,
`S:73 = ppoll` 273, `S:98 = futex` 81 (nearly all inside stalls).

gdb attach-sampling (12 samples) did **not** catch the futex frame — random
attaches land in a stall only ~13 % of the time and gdb's 2-4 s attach latency
biases toward the idle state; 8 landed in the idle run loop, 3 in
`TextureMapperLayer::paintRecursive`. So the futex *address* is unnamed; the lock
identified below is from the code path, not from a backtrace.

Which lock: `CoordinatedPlatformLayer::flushCompositingState`
(`CoordinatedPlatformLayer.cpp:908`) takes the per-layer `m_lock`, and the main
thread holds that same lock across `updateBackingStore()` ->
`CoordinatedBackingStoreProxy::updateIfNeeded()` (:738) — a full-viewport tile
update, which is exactly the `tilepaint dirty=20` that precedes every stall.

## WRITTEN (unbuilt, default OFF) — the video fast path

`patches/webkit/webkit-composite-skip-locked-layers-env.patch`
(`WEBKIT_COMPOSITE_SKIP_LOCKED_LAYERS`, default 0), registered in
`scripts/patches.sh` after every other patch touching that file:
a composite carrying no `RenderingUpdate` `tryLock()`s each layer and skips the
contended ones, re-presenting their last committed state; pending changes stay
pending for the next composite. `RenderingUpdate` composites still block on
purpose — they must commit and report the flush.

## RESOLVED (build 607) — the video fast path works, default flipped ON

Interleaved 5x5 A/B, fresh launch per arm, fullscreen 1080p YouTube, 20 s
frame-trace window (`video-harness/ab_fastpath.sh`):

| arm | comp/s | p95 | stalls >100 ms | worst frame | RSS |
|---|---|---|---|---|---|
| A1 stock | 18.3 | 97.5 ms | 17 | 804 ms | 1760 MB |
| B1 fast | 25.6 | 54.4 ms | **0** | 73 ms | 733 MB |
| A2 stock | 22.6 | 66.6 ms | 6 | 429 ms | 1549 MB |
| B2 fast | 24.4 | 56.6 ms | **0** | 83 ms | 1542 MB |
| A3 stock | 23.3 | 60.6 ms | 4 | 262 ms | 699 MB |
| B3 fast | 25.3 | 54.7 ms | **0** | 74 ms | 194 MB |
| A4 stock | 25.2 | 56.8 ms | 3 | 262 ms | 498 MB |
| B4 fast | 25.3 | 57.0 ms | **0** | 71 ms | 946 MB |
| A5 stock | 24.6 | 56.5 ms | 3 | 284 ms | 1045 MB |
| B5 fast | 24.2 | 58.9 ms | **0** | 74 ms | 1677 MB |

Medians: stock 23.3 comp/s, p95 60.6 ms, 4 stalls/arm, **33 stalls total**, worst
frame 804 ms. Fast path 25.3 comp/s, p95 56.6 ms, **0 stalls in all five arms**,
worst frame 83 ms. Presentation now tracks the 25 fps source.

Internal consistency: full-viewport repaints are UNCHANGED (tilepaint dirty>=10:
6/6/8/7/7 stock vs 3/5/8/7/8 fast path). The patch does not reduce the page's
repainting — it stops that repainting from blocking presentation, which is exactly
its claim and nothing more. Sanity-checked on a text-heavy page with scrolling:
no stale or corrupt tiles.

Default flipped to 1 in `deploy/runtime-common.sh`. Kill switch:
`WEBKIT_COMPOSITE_SKIP_LOCKED_LAYERS=0` — suspect FIRST on any stale-layer or
missing-repaint report.

Note the prediction that failed: I expected the two non-contention stall classes
(page-fault thrash, idle `ppoll`) to survive at ~2-in-7. Zero stalls remain, so
either they are rarer than that sample suggested, or they were secondary effects
of the same contention.

## OPEN — next steps, in order

1. **Track A, still worth doing:** `kYouTubeIconFix` (`apps/wpe/WPEUserScripts.h:408`)
   burns up to 949 ms in a single rAF because it rescans the whole document on
   every mutation batch and YouTube mutates ~13/s during playback. The fast path
   means it no longer freezes video, but it is still our own main-thread load, and
   it is a plausible source of the ~5 s full-viewport invalidation itself.
2. The ~30 MB/s heap churn at 1080p (RSS up to 1.7 GB; 240p flat at ~280 MB) with
   NV12->RGBA convert at 43 % of a core. Unexplained and independent of the flag
   (RSS ranged 194-1677 MB across the B arms).
3. Structural, unchanged: the ~40 ms serialized comp->recv->paint->ack cycle is
   exactly the 25 fps budget, so 30 fps content stays marginal until vsync-paced
   compositing or gralloc zero-copy. See the handover doc.
4. `WEBKIT_VIDEO_COMPOSITE_UNGATED` (the disproven tile-gate theory) is still
   present and inert at default OFF — decide whether to drop the flag, keeping the
   `schedupd` marker.
