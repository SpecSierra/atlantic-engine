# GPU raster, fences, and tile size on the libhybris Adreno 610

**Date:** 2026-08-21 · **Device:** Xperia 10 II, Adreno 610, engine 2.52.6 (build 666)
**Status:** closed — GPU raster does not beat CPU raster; the real variable was tile size.

## Why this was re-opened

Every previous attempt at GPU tile raster (`gpu`, `gpu-sync`, `gpu-explicit`; see
[atlantic-gpu-rendering-conservative] history and `webkit-glfence-disable-env.patch`,
`webkit-raster-on-compositor-thread-env.patch`) assumed the cost was the **cross-context
fence handoff** the driver refuses to honour. All three shipped modes are different ways of
paying for that synchronization. CPU raster became the default at build 416 because it takes
tile paint off the GPU submit path entirely.

## What was measured

A probe patch (since withdrawn, see below) added `WEBKIT_GL_FENCE_CLIENT_WAIT=1`, routing
consumer-side fence waits through `eglClientWaitSync` — which this driver *does* honour —
instead of `eglWaitSyncKHR`, which it ignores. Three arms, interleaved, MDN `input/date`,
`atldbg render --scroll` (fling), 3 reps each.

### Synchronization cost is ~zero

| Arm | fps | p95 |
|---|---|---|
| CPU raster | 28.2 | 150 ms |
| GPU + client-wait | 25.4 | 194 ms |
| GPU + server-wait (driver ignores it = zero sync cost) | 25.2 | 193 ms |

The server-wait arm is the control that matters: sync is genuinely free there, and it is not
faster. **The fence was never the bottleneck.** This also bounds the "single-context
compositing" idea (unify Skia's `GrDirectContext` onto the compositor's GL context, removing
the fence entirely): its entire upside is worth ~0.2 fps here. Not worth building.

Note `PlatformDisplaySkia.cpp` keeps `s_skiaGLContext` **thread_local** via
`GLContext::createOffscreen()`, so even `gpu-explicit` (raster on the compositor thread) runs
two GL contexts on one thread. That remains true; it just does not cost what we assumed.

## The actual variable: tile size

`WEBKIT_LAYERS_TILE_SIZE` (read once in `CoordinatedBackingStoreProxy::computeTileSize`,
accepts `W` or `WxH`). Shipped default is 256, set for the CPU upload path. The Adreno 610 is
a **tiler**: every tile is a render target paying a bin/resolve cycle, so cost scales with
tile *count*. Sweeping it, MDN, 3 reps per cell:

| Tile | CPU raster | GPU raster |
|---|---|---|
| 256 (shipped) | 28.5 / p95 140 | 21.5 / p95 291 |
| 512 | 30.2 / p95 120 | 28.9 / p95 146 |
| **1024** | **31.4 / p95 101** | 30.2 / p95 118 |
| 2048 | 31.6 / p95 104 | 31.5 / p95 120 |

- GPU raster gains 40% from 256→2048; CPU raster only 10%. Only the GPU path pays bin/resolve,
  which is exactly the predicted signature.
- GPU never beats CPU at a **matched** tile size. It ties at 2048. (An earlier reading of this
  data compared `gpu-1024` against `cpu-256` and wrongly called it a GPU win — always match
  the tile size before comparing raster modes.)
- 2048 is not better than 1024: same fps within noise, p95 indistinguishable once the ~10 ms
  noise floor is accounted for, and reps scatter (29.6 / 33.8 / 31.3 vs 1024's 31.6 / 31.3 /
  31.3). **The curve saturates at ~1024**; see the rectangular section for why shape does not
  help either.
- Memory did **not** blow up: whole-run delta ~45 MB at 2048. Per-tile bytes rise 64× from 256
  to 2048, but tile count falls proportionally.

### Rectangular tiles: no effect (negative result)

`computeTileSize` accepts `WxH`. Hypothesis: at 1024 wide on a 1080 px viewport the grid has a
second column only 56 px wide, and those slivers are still render targets paying bin/resolve.
A tile >= viewport width collapses the grid to one column. CPU raster, 3 reps:

| Arm | fps | p95 |
|---|---|---|
| `1024` square (in-session baseline) | 31.4 | 111 |
| `1080x1024` (1 column) | 30.7 | 105 |
| `1080x2048` (1 column, tall) | 31.7 | 104 |
| `1080x2520` (1 column, one viewport per tile) | 31.0 | 105 |

All inside a 1 fps band. The clean test is `1080x1024` vs square `1024` — near-identical tile
area, grid collapsed from two columns to one — and it is 0.7 fps *slower*. Sliver tiles cost
nothing: tile rects are clipped to the contents rect (`tileRectForPosition`, line ~1265), so a
sliver rasterizes only its sliver of pixels. **Tile size saturates at ~1024; shape is
irrelevant.** (An earlier note in this file claimed a 2048 tile "paints half its width
off-screen" — wrong, same clipping reason.)

**Noise floor.** Square `1024` re-measured across two sessions on an unchanged config: 31.4 fps
both times, p95 **101 vs 111**. So the p95 noise floor is ~10 ms, wider than every difference in
the rectangular table and wider than the 1024-vs-2048 p95 gap. Do not read p95 deltas under
~10 ms as signal. 256 -> 1024 (p95 140 -> ~105) clears it comfortably; nothing past 1024 does.

### Confirmed on the stock engine (no patch)

| Stock RPM engine | fps | p95 |
|---|---|---|
| `cpu-256` | 28.1 | 135 ms |
| `cpu-1024` | 31.3 | 107 ms |

**+10% fps, −28% p95 for one env default.** The CPU arms never touch fence code, so this is
independent of the probe.

## Outcome

- Probe patch **withdrawn** (`BENCHMARKING.md` shipping rule: does not clear the floor). GPU
  raster stays off; CPU raster remains the conservative default.
- `clientWait()` is not free: it blocks the compositor CPU-side per tile. On franceinfo the GPU
  client-wait arm left the WebProcess main thread at 93.6% at t+30s vs 15.4% for CPU raster,
  and never became measurable (6/6 runs failed). Measured at 256 px tiles — whether that
  survives at 1024 was not retested.
- **Open, worth doing:** raising the tile-size default to 1024. Needs validation this run did
  not cover: image-heavy pages (the known texture-pool corruption reproducer, and where 4 MB
  tiles bite), tile memory with background tabs, and repaint granularity on small dirty regions
  during ordinary browsing rather than flings.

## Instrument notes (cost real time here)

- `atldbg render --scroll`'s default `fling` profile is rAF-driven and is **starved on
  franceinfo**: 12 frames in 6 s with every thread at ~2% CPU. Near-zero frames *and* near-zero
  CPU means the stimulus never fired, not a slow renderer. `--scroll-profile touch` works there.
- Measure only after `document.readyState === "complete"` plus a warm-up pass. A fixed sleep put
  the window on the tail of load: one ~3 s stall and half the frame count of a warm page.
- `build-webkit.sh` symlinks `WebKitBuild/Release/config.h -> cmakeconfig.h` after the build.
  The build root precedes `Source/WebCore` on the include path, so that symlink makes
  `#include "config.h"` resolve to the wrong header and **every manual incremental `ninja`
  fails** with `function-like macro 'USE' is not defined`. CI never hits it (created after
  `ninja`). Move it aside to iterate, restore it after.
- A raw build-dir `libWPEWebKit` has the build-host prefix baked in (`PKGLIBEXECDIR`), and
  `WEBKIT_EXEC_PATH` only works in `ENABLE(DEVELOPER_MODE)` builds. To run one on device,
  symlink `/opt/github-runner/cache/atlantic-build/wpe-sfos-prefix/{libexec,lib,share}` to the
  real `/usr` paths.
- Never edit a running bash harness: bash re-reads the script mid-execution. An edit to add
  sweep arms broke the in-flight run's tail and silently stalled the job chained behind it.
