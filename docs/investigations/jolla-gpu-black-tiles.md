# Black tiles under GPU tile painting on the Jolla Phone 2

**Date:** 2026-09-25 → 2026-09-27 · **Device:** Jolla Phone 2 (MT6858, Mali-G610 MC2,
dpr 2.5, 1032 px wide), engine 2.54.0, builds 716–722
**Status:** **root cause OPEN.** Mitigation `WEBKIT_TILE_GPU_READBACK_SYNC=1` (722)
prevents it (0/12 vs 7/18) and keeps most of the GPU win (heavy +15.5% fps vs CPU).
Default OFF; the J2 still paints tiles on the CPU. Flipping the J2 to GPU paint +
readback is the next decision (see *Next step*).

## Why it matters

GPU tile painting (`ATLANTIC_GPU_FORCE_GPU_PAINT=1`, or `ATLANTIC_GPU_CONSERVATIVE=0`) is
~48% faster than CPU painting on the J2's heavy fling bench (~56 vs 38 fps, p95 20 vs
170 ms, build 716). It can't ship because root-layer tiles go black mid-fling. The
Xperia 10 II (Adreno) is unaffected by any of this: it stays on CPU painting.

## The symptom, precisely

- A full-width band exactly one or two 1024-px tiles tall is black. Anything painted
  later by a *partial* update (image-load repaints, a tapped link's hover state) shows
  correctly on top of the black.
- It is **persistent**: the tile stays black at rest until some later full repaint of
  it (seconds later). It is not a one-frame glitch.
- It is **deterministic per page state**: on Wikimedia Commons (mobile) it is always the
  same tile (layer y=10240, sometimes also 11264), whose one whole-tile paint is always
  the same recording (`record=1032x1024+0+10240`, 94 ops, no image atlases), made at the
  same stage of the load.
- CPU painting replays **that very recording** correctly (0/4 black).
- The recording is correct (op dump, level 4): its first op is a whole-tile white
  `drawRect` with `blend=Src`, then borders, text and three 40-px raster icons. The tile
  above (9216) has the same kinds of ops and the same icon and comes out fine. So the
  **entire replay** of the tile is lost on the GPU, not one op; even the Src fill is
  missing.

## Reproduce

Cold Commons load + flings during the load. `swipe.py` needs the J2 touchscreen, which
`evtouch.py` now finds by itself (`hyn_ts` on event5; event2 is the GPIO keys).

```sh
atldbg launch --env ATLANTIC_GPU_FORCE_GPU_PAINT=1 --env WEBKIT_TILE_RESET_LOG=2 \
    https://commons.wikimedia.org/wiki/Main_Page
sleep 0.5; for i in 1 2 3 4; do swipe 516 2000 516 500; sleep 0.25; done   # 4 flicks
sleep ~4; screenshot
```

4 flicks stop the scroll near the footer, where the black tile is on screen at rest:
~7/10 runs. 6 flicks mid-fling screenshots: ~6/12. Score **margin** pixels (x=8/20 and
w-8/20) for black; a plain black-pixel count is fooled by dark photos. Map a band to a
tile via an element's document position: `layer_y = css_y × 2.5`; tiles are 1024².

## Instruments (all default OFF, engine patches)

| Env | Patch | Logs |
|---|---|---|
| `WEBKIT_TILE_RESET_LOG=1` | `webkit-tile-reset-log-env.patch` | partial update onto a discarded texture; tiles skipped for lack of a texture |
| `=2` | same + | `[tileupd]` every tile update (swap/adopt/copy, sizes, alpha, opaque before→after, low-res); `[tilepaint]` every whole-tile replay (record rect, op count, fences, atlases) |
| `=3` | same | + 3-pixel readback after playback (**this cures the bug**, so it can't observe it) |
| `=4` | `webkit-tile-op-log-env.patch` | + `[tileop]` every op of each whole-tile recording, no readback |
| `WEBKIT_TILE_ALLOC_SYNC=1/2` | `webkit-tile-alloc-sync-env.patch` | glFlush/glFinish after the main-thread pool allocation (experiment, inert) |
| `WEBKIT_TILE_GPU_READBACK_SYNC=1` | `webkit-tile-gpu-readback-sync-env.patch` | the mitigation |

## Ruled out (do not retry)

| Theory | Test | Result |
|---|---|---|
| Partial update landing on a discarded/pool texture | level-1 log | 0 events in 7 runs with a band |
| Tile skipped for lack of a texture | level-1 log | 0 events |
| Transparent content composited as opaque (swap loses the flag) | `swapTexture` swaps flags; op dump shows a Src white fill | no |
| Unfinished paint / fence not honoured | `WPE_GL_FENCE_DISABLED=1` (producer flush + glFinish) | 6/12 black (control 6/12) |
| Main-thread pool allocation (`glTexImage2D` in the main thread's Skia context) not flushed before another context paints | `WEBKIT_TILE_ALLOC_SYNC=1` / `=2` | 6/12, 4/12 |
| MSAA resolve | tile surfaces use sample count 0 | n/a |
| Empty / wrong recording | op dump + CPU replays the same recording fine | recording correct |
| A specific op | op dump: black tile vs fine neighbour have the same op kinds and image | nothing distinguishes them |
| Page overlays (`mw-mf-page-center__mask`, `main-menu-mask`) | computed style | opacity 0 **and** visibility hidden; would be 80% black anyway, not pure black |
| `buffer->canvas()` returning null (skips the paint silently) | `NO-CANVAS` log | never |
| Damage-limited fragment path | needs an identity transform; would draw one union rect | doesn't match the picture |

Earlier (build 716 sweep): seen in every GPU mode incl. gpu-sync, with the scroll ladder
on or off; pool cap / pool off / upload budget off don't cure it.

## What is known to cure it

A `canvas->readPixels` on the tile surface right after playback, before
`completePainting()`: level 3 = **0/12** vs level 2 = **6/12** on the same build
(p≈0.014). A glFinish at the same point (via `completePainting`) does **not** cure it,
so the readback's effect is not "wait for the GPU".

## Open leads for next time

1. **Why a readback cures and a glFinish doesn't.** readPixels goes through Skia's
   `GrSurfaceContext::readPixels`: it binds the surface FBO for reading and resolves the
   render target, not just flushes. Suspects:
   - Mali tile-based deferred rendering discarding the render pass: if the pass
     ends with an invalidate/discard (Skia's `discardAttachments`/load-store ops), or the
     FBO is deleted/reattached before the driver resolves tile memory, a whole pass is
     lost. A readback forces the resolve first. Check what Skia does to the FBO when the
     wrapping `SkSurface` is destroyed (`CoordinatedAcceleratedTileBuffer` teardown).
   - Skia GL state cache going stale in the compositor thread's Skia context (FBO/texture
     bindings changed behind its back), so the replay draws into the wrong framebuffer.
     Test: `GrDirectContext::resetContext()` before playback.
2. **Why only that tile.** Deterministic, so it's likely an ordering fact: e.g. which
   tile is first to get a fresh pool texture after a given event, or a texture id being
   reused. Log the GL texture id and FBO id per replay and compare the black tile with
   its neighbours.
3. **Does it happen without `WEBKIT_RASTER_ON_COMPOSITOR_THREAD`** (plain gpu mode with
   worker threads)? The 716 sweep says yes, but that was before the deterministic repro
   existed; re-check with the 4-flick recipe.

## Mitigation

`WEBKIT_TILE_GPU_READBACK_SYNC=1`: one 1-pixel readback after each whole-tile GPU replay
(non-DDL). Costs one GPU round trip per whole-tile paint.

### Does it cure it? (build 722, 4-flick recipe, black at rest)

| Arm | Black |
|---|---|
| GPU paint | **7/18** |
| GPU paint + `WEBKIT_TILE_GPU_READBACK_SYNC=1` | **0/12** |

Fisher p≈0.02. (With `WEBKIT_TILE_RESET_LOG=2` on, the control rate is higher, ~7/10:
the logging's timing makes it more likely.)

### What does it cost? (build 722, `scrollbench/ab.py`, fling @8000, 4 reps, interleaved)

| Page | Arm | fps | p95 | raster CPU |
|---|---|---|---|---|
| heavy | cpu (current default) | 46.0 | 35 ms | 48.1% |
| heavy | gpu | 54.8 | 30 ms | 19.9% |
| heavy | gpu + readback | **53.1** (+15.5%) | 33 ms | 20.8% |
| light | cpu | 60.2 | 18 ms | 14.7% |
| light | gpu | 60.4 | 18 ms | 12.9% |
| light | gpu + readback | 60.0 | 18 ms | 12.8% |

Spreads don't overlap on heavy (cpu 44.8–46.3, gpu+readback 52.8–53.7). Light is
display-capped at 60 Hz on every arm. Caveat: GPU arms scroll faster per frame (vel_p50
358–388 vs 209 on heavy), so the stimulus isn't perfectly matched, the same
instrument trap as the 716 sweep.

## Next step

1. Decide whether the J2 defaults to GPU paint + readback. Before flipping: check GPU
   memory on a tab-heavy session (GPU tiles live in GPU memory, not the CPU heap) and run
   the real-page black-tile check on 2–3 more sites (CNN, Reddit), not just Commons.
2. The flip belongs in the browser's paint-mode detection (`apps/browser/main.cpp`,
   `probeGpuCapability`): a Mali/non-Adreno device picks gpu + readback, the Adreno
   stays on CPU. Note the probe bug first: `QLibrary("EGL")` looks for `libEGL.so`, SFOS
   ships only `libEGL.so.1`, so `egl=unknown` and every device lands in "conservative".
3. Root cause, if it's worth more builds: *Open leads* above.

