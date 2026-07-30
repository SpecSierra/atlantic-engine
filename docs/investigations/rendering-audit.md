> **Status: STALE (2026-05-28)** — An incomplete audit from before most of the rendering work landed, kept only for the early device facts (Adreno 610, conservative GPU mode). Do not treat its open questions as current.

# Rendering audit

## Status

- **Date:** 2026-05-28
- **State:** partially completed, blocked on device SSH reconnect
- **Reason for block:** `ssh -p 2222 defaultuser@localhost` is currently refusing connections, so the fresh cold-start debug capture could not be taken from this session.

## Previously confirmed on-device findings

- Browser GL probe reported **`Adreno (TM) 610`** as the renderer.
- Browser-side conservative GPU mode was observed **off** on the live device.
- Live CPU samples previously showed both:
  - `atlantic-browser.bin` spending time on `QSGRenderThread`
  - `WPEWebProcess` consuming significant CPU on heavy pages

These findings support a real GPU path being present, but they are **not enough** to close the Phase 1 rendering audit.

## Required cold-start audit still pending

Cold-start the browser with:

```bash
WEBKIT_DEBUG=Compositing,Layers,Performance,Skia
```

Then confirm all of the following from logs/runtime state:

1. **Skia GPU backend is active**
   - confirm it is not silently falling back to CPU raster
2. **`WPEGPUProcess` launches after first paint**
   - verify with `ps`
3. **DMA-BUF import path succeeds**
   - confirm libqtwpe is not falling back to SHM/shared-memory upload
4. **Damage tracking is granular**
   - log output should mention damage regions, not just full-frame repaint behavior

## Follow-up tasks if audit finds fallback behavior

Create separate tasks immediately if any of these are observed:

- **CPU raster fallback**
- **No `WPEGPUProcess` launch**
- **DMA-BUF import failure / SHM fallback**
- **Full-frame repaint only / no granular damage**

## Related Phase 1 changes already prepared

- Browser now requests:
  - `WEBKIT_HARDWARE_ACCELERATION_POLICY_ALWAYS`
  - `WEBKIT_CACHE_MODEL_WEB_BROWSER`
  - Qt swap interval `1`
- Runtime wrapper now exports:
  - `QSG_RENDER_LOOP=threaded`
- Packaging/build path now stages a generated `content-blocker.json` from committed EasyList + EasyPrivacy snapshots

## Memory-pressure note

The browser/UI repo exposes the cache-model knob directly, but the **1.0 GB / 1.5 GB WebProcess memory-pressure caps** do not appear to be configurable from the Atlantic UI layer. The upstream Unix `MemoryPressureHandler` implementation is generic and does not provide those per-device limits as a simple runtime setting, so that part likely requires an engine-side WebKit patch rather than a browser-side toggle.
