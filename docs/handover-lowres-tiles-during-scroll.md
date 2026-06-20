# Handover — Low-resolution tiles during scroll

Author: prior session (2026-06-20). Status: **not started** — this is a design +
starting-point doc for the next person.

## Why

On the Adreno 610 / libhybris device, scrolling heavy pages is limited not by any
single saturated resource but by a **serialized, non-pipelined render path**
(WebProcess raster → cross-process EGLImage handoff → Qt/QSG composite → lipstick
present), each frame ~hundreds of ms with every stage half-idle. This is the
structural ceiling that remains after the recent fixes:

- `webkit-skia-record-rtree-env.patch` (RTree BBH on tile record — per-tile replay
  culls draw ops). Lossless, shipped, default on.
- `webkit-preserve-style-resolver-on-memory-pressure.patch` (stop the mem-pressure
  purge nuking the CSS style resolver). Fixed reddit. Shipped, default on.
- `webkit-raster-on-compositor-thread-env.patch` + directional-coverage +
  checkerboard-during-scroll (existing scroll levers).
- adblock `data/content-blocker/atlantic-extra.txt` (getjad/getjan) — fixed the
  jeuxvideo forum 2fps (that one was an ad timer, NOT rendering).

The remaining lever that directly cuts the per-frame **GPU + raster pixel cost** is
**low-resolution tiles during scroll**: while a fling is in progress, rasterize and
composite tiles at a reduced scale (e.g. 0.5–0.75×), then re-rasterize at full
resolution once motion settles. Pixel cost is quadratic in scale, so 0.7× ≈ 2×
cheaper raster+fill; the page is briefly softer mid-fling (the eye doesn't resolve
detail while flinging anyway — this is exactly what Chrome/Android "low-res tiles"
and the Cocoa tile controller do). Sharpen-at-rest keeps static reading crisp.

## Where the code is (WPE WebKit 2.52.4 reference tree, build via CI patches)

Reference source (read-only, for writing the patch):
`/opt/github-runner/cache/atlantic-build/sources/wpewebkit-2.52.4/Source/WebCore/platform/graphics/`

Key files / functions:

1. **`texmap/coordinated/CoordinatedBackingStoreProxy.cpp`** — the tile manager.
   - `updateIfNeeded(... float contentsScale ...)` — entry per layer flush. `contentsScale`
     comes from the layer (deviceScaleFactor × pageScale).
   - Already has the **env-gated tuning helpers** to copy as a template:
     `coverAreaMultiplierFromEnvironment()`, `directionalCoverageEnabled()`,
     `checkerboardScrollSpeedThreshold()`, `checkerboardSettleMs()`.
   - Already tracks scroll state: `m_lastScrollDirectionY`, `m_scrollAccumulatorY`,
     and computes fling speed (`std::abs(dy)/dtSec` vs `checkerboardScrollSpeedThreshold()`)
     plus a settle timer `m_checkerboardHoldUntil`. **Reuse this exact signal** to decide
     "actively flinging → low-res" and "settled for N ms → re-raster full-res".
   - `computeTileSize()` reads `WEBKIT_LAYERS_TILE_SIZE`. Tile geometry math
     (`mapFromContents`/`mapToContents`/`tileRectForPosition`) is all in `m_contentsScale`.

2. **`skia/SkiaPaintingEngine.cpp`** — actual rasterization.
   - `record(layer, recordRect, contentsOpaque, contentsScale)` builds the SkPicture;
     `paintIntoGraphicsContext()` does `context.scale(contentsScale)`.
   - `replay(layer, recording, dirtyRect)` rasterizes into a buffer of `dirtyRect.size()`
     on the compositor thread (gpu-explicit) / worker pool.
   - `createBuffer(renderingMode, size, contentsOpaque)` allocates the tile texture
     (`BitmapTexturePool::singleton().acquireTexture(size, ...)`).

3. **`texmap/coordinated/CoordinatedBackingStoreTile.cpp`** — `processPendingUpdates()`
   uploads the painted buffer into the tile texture. **Fast path** (whole-tile change,
   `update.sourceRect.size() == update.tileRect.size()`) just `swapTexture()` — zero copy.
   Partial updates `copyFromExternalTexture(sourceRect, bufferOffset)`.

4. **`texmap/coordinated/CoordinatedBackingStore.cpp`** — `paintToTextureMapper()` draws
   `tile.texture()` stretched to `tile.rect()` via `textureMapper.drawTexture(...)`.
   **This is the free upscale**: the texture's pixel size is independent of `tile.rect()`,
   so a smaller (low-res) texture is bilinear-upsampled to the on-screen tile rect with no
   extra code. (Damage-tracking `drawTextureFragment` path assumes 1:1 source rect — guard
   it when low-res is active.)

## Recommended approach (least invasive first)

Add a new engine patch `webkit-lowres-tiles-during-scroll-env.patch`, env-gated like the
others (`WEBKIT_LOWRES_TILE_SCALE=<0.4..1.0>` default 1.0 = off; the browser conservative
branch in `apps/browser/main.cpp` sets the device default once proven).

Two implementation options — evaluate (A) first:

**(A) Reduced raster buffer, geometry unchanged (preferred — smallest blast radius).**
While flinging, in `SkiaPaintingEngine::replay()`/`paint()`/`createBuffer()` allocate the
tile buffer at `ceil(dirtyRect.size() * lowresScale)` and scale the replay canvas
accordingly; keep all tile/cover/keep geometry in full `m_contentsScale`.
`paintToTextureMapper` upscales for free. The hard part is the **partial-update copy path**
in `CoordinatedBackingStoreTile`: `sourceRect`/`updateRect`/`bufferOffset` must be scaled
to the low-res buffer, with rounding care. The **whole-tile fast-path swap** needs the tile
texture to also be low-res — simplest if, during a fling, the cover logic creates *new*
tiles (edge band) that are whole-tile painted → fast-path swap → trivially low-res. Tiles
already painted full-res just scroll (no re-raster) — so you mostly pay low-res only on the
newly-exposed band, which is the GPU cost that matters during a fling.

**(B) Reduced `contentsScale` end-to-end.** Plumb a scaled contentsScale through
`updateIfNeeded` so tiles are created, sized, mapped AND painted at low-res, then the
TextureMapper draws them at the layer's true rect. Cleaner conceptually but touches all the
rect math and the `CoordinatedBackingStoreTile::m_scale`/`CoordinatedBackingStore::m_scale`
asserts (`ASSERT(tile.scale() == m_scale)`), and risks scale-change tile eviction storms
(see how `contentsScaleChanged` clears all tiles in `createOrDestroyTiles`). Higher risk.

**Sharpen-at-rest:** on the settle transition (reuse `m_checkerboardHoldUntil` style timer),
mark the visible tiles dirty so they re-record/replay at full `m_contentsScale`. Must be a
single coalesced re-raster, not per-frame, or you reintroduce cost.

### Watch out for
- The **fast-path swap** in `CoordinatedBackingStoreTile` requires `sourceRect.size ==
  tileRect.size`; if you shrink only the buffer, that equality breaks and you fall to the
  slow copy path. Decide low-res at the tile-buffer-size level so both stay consistent.
- Damage tracking (`ENABLE(DAMAGE_TRACKING)`, `drawTextureFragment`) assumes 1:1 texel
  mapping — bypass it (full `drawTexture`) when the tile is low-res.
- Don't fight the existing **checkerboard-during-scroll** patch (`WEBKIT_CHECKERBOARD_
  DURING_SCROLL=200` is the current device default — it *defers* new-tile painting during a
  fast fling). Low-res tiles and checkerboard are alternatives for the same band; likely you
  want low-res *instead of* checkerboard (paint cheap-now vs paint-later). A/B them.
- Mali/desktop path: gate so only the conservative (Adreno) branch enables it.

## How to build / ship / verify (device playbook)

- **Build via CI only**: add the patch to `scripts/patches.sh` (after the existing
  texmap/skia patches — same files), push `master` → "Build Atlantic packages" workflow.
  Don't do local WebKit builds / patch dry-runs for verification, but **DO** generate the
  patch body with `diff -u` against the reference tree (hand-written hunks repeatedly broke:
  bad `@@` counts / bare blank context lines → "malformed patch", CI fails at apply).
- **Device** (Xperia 10 II, ssh/scp port **varies — was 2222 and 2223 this session**, pw
  `root`). The local tunnel **flaps under sustained connections** — run anything long
  (gdb samplers, scroll measurements) **DETACHED on-device** (`setsid sh script </dev/null
  &`, write to a file, then poll+scp). Re-establishing held `-L`/long ssh fails a lot.
- **Update to a new build**: the Pages RPM repo is **not pre-added** (README's
  `atlantic-ci-v2` alias is stale). `zypper ar -Gf
  https://specsierra.github.io/atlantic-engine/aarch64/ atlantic-ci`; engine.dat-less render
  changes are in `wpewebkit2` (lib `/usr/lib64/libWPEWebKit-2.0.so.1.9.x`); confirm the env
  string compiled in via `python3 -c "print(open(lib,'rb').read().count(b'WEBKIT_LOWRES_TILE_SCALE'))"`
  (grep lies on the 162MB binary — use python byte count).
- **Profiling** (no perf/eu-stack on device; `zypper in gdb` works and the device lib is
  UNSTRIPPED so gdb symbolizes WebCore directly):
  - poor-man's sampler: `echo 0 > /proc/sys/kernel/yama/ptrace_scope` (as root) then loop
    `gdb -p <pid> -batch -ex "thread 1" -ex "bt N"` (main) or `thread apply all bt` +
    extract `LWP <compositor-tid>`. **NEVER set ptrace_scope to 3** — yama makes 3
    irreversible without a reboot (cost a reboot this session). Device boots at 1; leave it.
  - per-thread CPU: read `/proc/<pid>/task/<tid>/stat` fields 14+15 before/after a scroll
    window; **device shell is busybox sh — no bash arrays / `${var%%pat}`** (silently fails),
    write POSIX-clean with plain vars.
  - GPU: `/sys/class/kgsl/kgsl-3d0/gpubusy` ("busy total" over a FIXED ~1s driver window,
    not your sleep), `gpuclk`/`max_gpuclk`. Adreno610v1, big cluster cpu4-7 (WebProcess is
    taskset-pinned there); governor schedutil, ramps to ~2016MHz under load (clock fix is in).
  - `~/atldbg profile -s N` gives JS self-time (file:line) over the inspector; it hardcodes
    ssh PORT=2222 in `scripts/devtools/atldbg/device.py` (sed it if the tunnel is on 2223).
  - Screenshots are the oracle for visual quality (lipstick `saveScreenshot`, see top-level
    README) — check low-res softness mid-fling and that sharpen-at-rest actually fires.
- **Success metric**: during a forum/reddit fling, WebProc-COMPOSITOR jiffies + GPU busy %
  drop with `WEBKIT_LOWRES_TILE_SCALE=0.6` vs `=1.0`, frame cadence improves (atldbg render /
  screenshot a fling), and at rest the page is full-res sharp. Baseline numbers captured this
  session: jeuxvideo forum during scroll (build 365) main 41% / comp 49% / GPU 45%, nothing
  saturated — the serialized pipeline, not a hot CPU, is the target.

## Related
- Memories: `tile`/`gpu-explicit-compositor-thread-fix`, `atlantic-gpu-rendering-conservative`
  (gpu-sync history, directional coverage, why threaded GPU corrupts on this Adreno),
  `egl-native-fence-hybris-gap`, `atlantic-vs-official-browser-perf` (the structural gap),
  `jeuxvideo-forum-getjad-adloop`, `reddit-style-resolver-purge-thrash`, `atldbg-debugger`.
- Patches to mirror as a template: `webkit-directional-tile-coverage-env.patch`,
  `webkit-checkerboard-during-scroll-env.patch`, `webkit-skia-record-rtree-env.patch`.
