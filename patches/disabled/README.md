# Disabled patches

Kept for reference, **never applied** — they are not in `scripts/patches.sh`.

| Patch | Why it is off |
|---|---|
| `webkit-gpu-process-by-default-wpe.patch` | Hard-enables `ENABLE_GPU_PROCESS_DOM_RENDERING_BY_DEFAULT`, moving DOM rendering into the GPU process. On this libhybris/Adreno device there is no GBM / DRM render node, so the GPU process cannot export composited frames: pages render blank (chrome draws, content area white). Verified on-device (Xperia 10 II). DOM rendering stays in the WebProcess, which exports via WPEBackend-fdo. Kept for future hybris GPU-export work; see also `webkit-gpu-process-egl-default-display-fallback.patch`. |

Anything that is simply dead belongs in git history, not here. A patch earns a
place in this directory only if it is a real, working alternative blocked by a
platform gap that may close.
