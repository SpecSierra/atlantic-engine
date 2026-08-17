# Patch series

**Generated — do not edit.** `python3 scripts/gen-patch-series.py`

Why each patch exists: the header comment inside the patch file. [RATIONALE.md](RATIONALE.md) covers the stack as a whole.

Apply order comes from `scripts/patches.sh` and is load-bearing: patches that touch the same file must stay in this order. Validate the stack **sequentially** on a version bump — isolated dry-runs give false failures.

Each patch carries its own rationale as a header comment at the top of the patch file; the Note column below is its first paragraph.

| | Count |
|---|---|
| Patches | 40 |
| …portability / build fixes | 4 |
| …behaviour | 36 |
| Distinct source files touched | 1309 |
| Env flags introduced | 93 |

## Hot files

Files edited by more than one patch — every one is an ordering constraint.

| Source file | Patches |
|---|---|
| `Source/WebKit/WebProcess/WebPage/CoordinatedGraphics/LayerTreeHost.cpp` | 5 |
| `Source/WebKit/WebProcess/WebPage/CoordinatedGraphics/ThreadedCompositor.cpp` | 5 |
| `Source/WebCore/platform/graphics/texmap/coordinated/CoordinatedBackingStoreProxy.cpp` | 4 |
| `Source/WebCore/platform/graphics/texmap/coordinated/CoordinatedPlatformLayer.cpp` | 4 |
| `Source/WebCore/page/scrolling/ScrollingTree.cpp` | 3 |
| `Source/WebCore/page/scrolling/ScrollingTree.h` | 3 |
| `Source/WebCore/platform/graphics/skia/SkiaPaintingEngine.cpp` | 3 |
| `Source/WebCore/platform/graphics/texmap/coordinated/GraphicsLayerCoordinated.cpp` | 3 |
| `Source/WebCore/platform/graphics/skia/SkiaPaintingEngine.h` | 2 |
| `Source/WebCore/platform/graphics/texmap/BitmapTexturePool.h` | 2 |
| `Source/WebCore/platform/graphics/texmap/coordinated/CoordinatedBackingStore.cpp` | 2 |
| `Source/WebCore/platform/graphics/texmap/coordinated/CoordinatedBackingStoreProxy.h` | 2 |
| `Source/WebCore/platform/graphics/texmap/coordinated/CoordinatedBackingStoreTile.cpp` | 2 |
| `Source/WebCore/platform/graphics/texmap/coordinated/CoordinatedBackingStoreTile.h` | 2 |
| `Source/WebCore/platform/graphics/texmap/coordinated/CoordinatedTileBuffer.cpp` | 2 |
| `Source/WebKit/UIProcess/API/wpe/WPEWebViewLegacy.cpp` | 2 |
| `Source/cmake/OptionsWPE.cmake` | 2 |

## Behaviour patches

| # | Patch | Files | Env flags | Note |
|---|---|---|---|---|
| 1 | `libepoxy-rtld-default-fallback.patch` | 1 | — | — |
| 2 | `webkit-glfence-disable-env.patch` | 1 | — | WPE_GL_FENCE_DISABLED=1 makes GL fences unavailable so every call site falls back to its synchronous path (GrSyncCpu::kYes / glFinish), guaranteeing the producing context's work is complete before any… |
| 3 | `webkit-texture-pool.patch` | 4 | `WEBKIT_BITMAP_TEXTURE_POOL_DISABLED`<br>`WEBKIT_COMPOSITOR_GL_FINISH`<br>`WEBKIT_TEXPOOL_LOG`<br>`WEBKIT_TEXTURE_POOL_CAP_MB` | BitmapTexturePool: bound GPU texture memory, plus the A/B knobs for it. Merged from: webkit-texpool-compositor-sync-env, webkit-texpool-synchronous-cap. |
| 4 | `webkit-raster-on-compositor-thread-env.patch` | 4 | `WEBKIT_RASTER_ON_COMPOSITOR_THREAD` | WEBKIT_RASTER_ON_COMPOSITOR_THREAD=1 routes threaded-mode tile GPU rasterization onto the compositor thread, which owns the GL context, instead of the Skia worker pool. On this driver the worker-threa… |
| 5 | `webkit-skia-record-rtree-env.patch` | 1 | `WEBKIT_RASTER_ON_COMPOSITOR_THREAD`<br>`WEBKIT_SKIA_RECORD_RTREE` | record the per-layer tile SkPicture with an R-tree BBH so each per-tile replay() culls draw ops to its tile's clip, instead of every tile re-walking/re-submitting the whole layer's op list (an N-tile … |
| 6 | `webkit-scroll-degradation.patch` | 10 | `WEBKIT_CHECKERBOARD_DURING_SCROLL`<br>`WEBKIT_CHECKERBOARD_SETTLE_MS`<br>`WEBKIT_COVER_AREA_MULTIPLIER`<br>`WEBKIT_DIRECTIONAL_TILE_COVERAGE`<br>`WEBKIT_LOWRES_COST_BUDGET_MS`<br>`WEBKIT_LOWRES_COST_CHECKERBOARD_X`<br>`WEBKIT_LOWRES_COST_DISENGAGE_PASSES`<br>`WEBKIT_LOWRES_COST_ENGAGE_X`<br>`WEBKIT_LOWRES_COST_MOTION_MS`<br>`WEBKIT_LOWRES_COST_SCALE_FLOOR`<br>`WEBKIT_LOWRES_COST_TRIGGER`<br>`WEBKIT_LOWRES_SCROLL_SPEED`<br>`WEBKIT_LOWRES_SHARPEN_MARGIN_PX`<br>`WEBKIT_LOWRES_SHARPEN_VIEWPORT_ONLY`<br>`WEBKIT_LOWRES_TILE_SCALE`<br>`WEBKIT_LOWRES_VIEWPORT_FULL`<br>`WEBKIT_SCROLLTIER_LOG`<br>`WEBKIT_SKIA_ENABLE_CPU_RENDERING`<br>`WEBKIT_TILECOST_LOG` | Scroll degradation: the low-res / checkerboard tile ladder and its cost-based trigger, end to end. Merged from 9 patches: webkit-directional-tile-coverage-env, webkit-checkerboard-during-scroll-env, w… |
| 7 | `webkit-memory-pressure.patch` | 2 | `WEBKIT_MEMORY_BASE_THRESHOLD_MB`<br>`WEBKIT_MEMORY_POLL_INTERVAL_MS`<br>`WEBKIT_PURGE_STYLE_ON_MEMORY_PRESSURE` | Memory-pressure handler: purge earlier, but stop nuking the style resolver. Merged from: webkit-memory-pressure-threshold-env, webkit-preserve-style-resolver-on-memory-pressure. |
| 8 | `webkit-image-subsampling.patch` | 14 | `WEBKIT_CACHED_SUBIMAGE`<br>`WEBKIT_CACHED_SUBIMAGE_MAX_SCALE`<br>`WEBKIT_CACHED_SUBIMAGE_MIN_AREA`<br>`WEBKIT_IMAGE_SUBSAMPLE_MIN_AREA` | Decoded-image memory and resample cost: subsampling for JPEG/WebP/PNG plus a cached subimage for repeated downscaled draws. Merged from: webkit-skia-image-subsampling, webkit-webp-subsampling, webkit-… |
| 9 | `webkit-gpu-process-egl-default-display-fallback.patch` | 4 | — | webkit-gpu-process-by-default-wpe.patch: DISABLED. It hard-enables ENABLE_GPU_PROCESS_DOM_RENDERING_BY_DEFAULT, moving DOM rendering into the GPU process. On this libhybris/Adreno device there is no G… |
| 10 | `webkit-jsc-arm64-tuning.patch` | 1 | — | JavaScriptCore tuning for this 64-bit ARM phone. Merged from: webkit-jsc-linux-arm64-thread-tuning, webkit-jsc-linux-arm64-jit-thresholds. |
| 11 | `webkit-kinetic-fling.patch` | 4 | `WEBKIT_KINETIC_DECEL_FRICTION`<br>`WEBKIT_KINETIC_END_EVENT_FIX`<br>`WEBKIT_KINETIC_MAX_VELOCITY`<br>`WEBKIT_KINETIC_VELOCITY_ACCUM_MAX`<br>`WEBKIT_KINETIC_VELOCITY_BIAS_FIX`<br>`WEBKIT_WHEEL_COALESCE_PHASE_SPLIT` | Touch fling: make kinetic scrolling behave like a phone. Merged from 5 patches: webkit-kinetic-decel-friction-env, webkit-kinetic-jank-resilient-end, webkit-touch-gesture-began-phase, webkit-wheel-coa… |
| 12 | `webkit-scrollbar.patch` | 5 | `WEBKIT_SCROLLBAR_NO_HOVER`<br>`WEBKIT_SCROLLBAR_SCALE`<br>`WEBKIT_SCROLLBAR_SMOOTHING`<br>`WEBKIT_SCROLLBAR_SPRITE` | Overlay scrollbar: size it for a 3x-zoomed phone and stop it blinking. Merged from: webkit-adwaita-scrollbar-scale-env, webkit-scrollbar-sprite-and-smoothing, webkit-scrollbar-no-hover-expand. |
| 13 | `webkit-gst-media.patch` | 4 | `WEBKIT_GST_AUDIO_SYSTEM_CLOCK`<br>`WEBKIT_GST_MEDIA_ROLE`<br>`WEBKIT_GST_NO_SOUP_REFERER`<br>`WEBKIT_GST_QUEUE_HIGH_WATERMARK`<br>`WEBKIT_GST_RING_BUFFER_MAX_SIZE`<br>`WEBKIT_GST_URIDECODEBIN_BUFFER_SIZE`<br>`WEBKIT_IS_WEB_SRC`<br>`WEBKIT_VOLUME_LOCKED`<br>`WEBKIT_WEB_SRC_CAST` | GStreamer / audio integration with Sailfish. Merged from 5 patches: webkit-gst-buffer-tuning, webkit-gst-media-role-env, webkit-gst-soup-referer, webkit-volume-locked-env, webkit-gst-audio-system-cloc… |
| 14 | `webkit-wpe-dark-mode-runtime.patch` | 2 | — | runtime prefers-color-scheme switch. The legacy libwpe build hardwires SystemSettings darkMode to false, so websites always saw prefers-color-scheme: light. Exports wpe_sfos_set_dark_mode(int) for the… |
| 15 | `webkit-wpe-page-scale-api.patch` | 1 | `WEBKIT_IS_WEB_VIEW` | expose visual-viewport (page-scale) zoom. WPE's public API only has webkit_web_view_set_zoom_level(), which is page zoom: it relayouts, reflows text and changes what fits on a line. Pinch on a phone i… |
| 16 | `webkit-bubblewrap-sfos-sandbox.patch` | 1 | `ATLANTIC_ENABLE_SANDBOX` | Re-enable the WPE bubblewrap process sandbox on SFOS / Android-4.14: --dev-bind / / (no pivot_root and no --dev masking of the GPU nodes), a shared network namespace for the Web and GPU processes (hyb… |
| 17 | `webkit-seccomp-filter-no-namespace.patch` | 1 | `ATLANTIC_ENABLE_SECCOMP`<br>`WEBKIT_ENABLE_SECCOMP_FILTER` | install the bwrap seccomp syscall filter (BubblewrapLauncher::setupSeccomp's flatpak block list) directly in every auxiliary process via seccomp_load(), WITHOUT any namespace. The bwrap mount namespac… |
| 18 | `webkit-composite-scroll-sync.patch` | 5 | `WEBKIT_COMPOSITE_SCROLL_SYNC` | Atomic scroll offset + fixed/sticky layer positions per composed frame. Merged from: webkit-sticky-scroll-composite-sync-env, webkit-composite-scroll-sync-stall-fix, webkit-composite-scroll-sync-lock-… |
| 19 | `webkit-wpe-spellcheck-enchant.patch` | 8 | — | WPE has no TextChecker backend upstream (spellcheck is GTK-only); port the GTK enchant-backed implementation so ENABLE_SPELLCHECK builds/works. |
| 20 | `webkit-load-responsiveness.patch` | 5 | `WEBKIT_LOADING_TIMER_ALIGNMENT_MS`<br>`WEBKIT_PARSER_TIME_LIMIT_MS`<br>`WEBKIT_TOUCH_ACK_TIMEOUT_MS` | Input and scrolling during a heavy page load. Merged from: webkit-loading-timer-alignment-env, webkit-parser-time-limit-env, webkit-touch-ack-timeout-env. |
| 21 | `webkit-http-cache.patch` | 2 | `ATLANTIC_CACHE_MODEL`<br>`WEBKIT_SW_FALLBACK_HTTP_CACHE`<br>`WEBKIT_URL_CACHE_DISK_CAPACITY_MB` | A bounded on-flash HTTP cache that service-worker sites can also use. Merged from: webkit-url-cache-disk-capacity-env, webkit-sw-fallback-http-cache. |
| 22 | `webkit-repaint-scope.patch` | 5 | `WEBKIT_PAINT_LOG`<br>`WEBKIT_REPAINT_ON_COMPOSITED_MOVE`<br>`WEBKIT_REPAINT_ON_LAYER_RESIZE` | Stop full-layer repaints that nothing asked for, plus the paint log that found them. Merged from: webkit-no-full-repaint-on-layer-grow, webkit-no-full-repaint-on-composited-move, webkit-paint-log-diag… |
| 23 | `webkit-fling-throttle-env.patch` | 4 | `WEBKIT_FLING_THROTTLE_MS`<br>`WEBKIT_FLING_THROTTLE_SETTLE_MS`<br>`WEBKIT_FLING_THROTTLE_SPEED` | fling degradation for main-thread-bound pages (franceinfo/radiofrance scroll <1fps, 44% style resolution). While the scrolling thread reports a fast fling (velocity sampled in ScrollingTree::scrolling… |
| 24 | `webkit-independent-scroll.patch` | 5 | `WEBKIT_FORCE_ASYNC_SCROLL`<br>`WEBKIT_FORCE_VBLANK_TIMER`<br>`WEBKIT_INDEPENDENT_SCROLL`<br>`WEBKIT_INDEPENDENT_SCROLL_TICK_MS` | Scrolling off the main thread (the APZ bargain), in four dependent parts. Merged from: webkit-force-async-scroll-env, webkit-independent-scroll-env, webkit-scrolling-thread-display-link-env, webkit-sc… |
| 25 | `webkit-tile-upload.patch` | 10 | `WEBKIT_TILE_UPLOAD_BUDGET_MB`<br>`WEBKIT_TILE_UPLOAD_BUDGET_SCROLL_ONLY`<br>`WEBKIT_TILE_UPLOAD_REST_BUDGET_MB`<br>`WEBKIT_TILE_UPLOAD_SCROLL_SETTLE_MS` | Bound the tile work one composite may do, and make the fill-in look right. Merged from: webkit-tile-upload-budget-env, webkit-tile-upload-scroll-gate, webkit-tile-upload-nonblocking-settle. |
| 26 | `webkit-no-fake-mouse-move-env.patch` | 1 | `WEBKIT_NO_FAKE_MOUSE_MOVE` | Touch devices: kill the fake mouse-move WebKit dispatches after every scroll at the stale synthetic-tap position, which :hover-highlights whatever link scrolls under the invisible cursor (WEBKIT_NO_FA… |
| 27 | `webkit-video-proxy-target-unbind-guard.patch` | 3 | — | Video contents-buffer proxy: when the <video> element's backing layer is rebuilt (fullscreen enter/exit, navigation), the OLD GraphicsLayer's teardown unbound the shared buffer proxy AFTER the new lay… |
| 28 | `webkit-damage-limited-composite-env.patch` | 1 | `WEBKIT_DAMAGE_COMPOSITING`<br>`WEBKIT_DAMAGE_UNIFY`<br>`WEBKIT_DAMAGE_USE_FOR_COMPOSITING` | Damage-limited compositing: enable WebKit's compiled-in-but-WPE-disabled damage subsystem so a composite is scissored to the region that actually changed instead of redrawing the whole scene (WEBKIT_D… |
| 29 | `webkit-tile-buffer-skip-zero-env.patch` | 1 | `WEBKIT_TILE_BUFFER_SKIP_ZERO` | Skip the redundant main-thread memset of CPU tile buffers: the Skia worker clears+paints every tile before it is composited, so tryZeroedMalloc on the main thread is wasted work - device-measured as t… |
| 30 | `webkit-frame-trace-env.patch` | 5 | `ATLANTIC_FRAME_TRACE`<br>`ATLANTIC_REPAINT_BT`<br>`WEBKIT_COVER_AREA_MULTIPLIER` | Frame-trace diagnostic (ATLANTIC_FRAME_TRACE=1, default OFF): CLOCK_MONOTONIC marker at each WebProcess composite, paired with the qt5-plugin ui recv/paint/ ack markers to localize the franceinfo free… |
| 31 | `webkit-root-customprop-repaint-skip-env.patch` | 1 | `ATLANTIC_FRAME_TRACE`<br>`ATLANTIC_REPAINT_BT`<br>`WEBKIT_SKIP_ROOT_CUSTOMPROP_REPAINT` | THE franceinfo scroll-freeze fix: WEBKIT_SKIP_ROOT_CUSTOMPROP_REPAINT=1 (default ON) stops RenderBox::styleWillChange from repainting the whole page when a :root/<body> custom-property changes (the si… |
| 32 | `webkit-drop-tiles-when-hidden-env.patch` | 4 | `WEBKIT_DROP_TILES_WHEN_HIDDEN` | WEBKIT_DROP_TILES_WHEN_HIDDEN=1 (default OFF, A/B) makes a backgrounded tab drop its tiled-backing tiles. Device-measured: a hidden tab pins ~1 GB of GPU tile textures forever (the cover rect in Coord… |
| 33 | `webkit-composite-skip-locked-layers-env.patch` | 1 | `ATLANTIC_FRAME_TRACE`<br>`WEBKIT_COMPOSITE_SKIP_LOCKED_LAYERS` | WEBKIT_COMPOSITE_SKIP_LOCKED_- LAYERS=1 (default OFF) — the video fast path. CoordinatedPlatformLayer:: flushCompositingState() (compositor thread) blocks on the per-layer m_lock that the MAIN thread … |
| 34 | `webkit-svg.patch` | 8 | `WEBKIT_SVG_FILTER_RESULTS_REUSE`<br>`WEBKIT_SVG_FILTER_SCALE_CAP`<br>`WEBKIT_SVG_RASTER_CACHE`<br>`WEBKIT_SVG_RASTER_CACHE_MAX_AREA_PX` | SVG: cache what can be cached, cap what cannot. Merged from: webkit-svg-raster-cache, webkit-svg-filter-results-reuse, webkit-svg-filter-scale-cap. Shipped 551-553, device-verified (2x AnTuTu). |
| 35 | `webkit-clipboard-qt-hook.patch` | 1 | `ATLANTIC_DISABLE_CLIPBOARD_BRIDGE` | make web clipboard writes reach the SFOS system clipboard. The libwpe pasteboard singleton is an in-process std::map stub in this fdo build (no _wpe_pasteboard_interface exported), so navigator.clipbo… |
| 36 | `webkit-viewport-unit-font-size-zoom.patch` | 1 | `WEBKIT_FONT_SIZE_UNIT_UNZOOM` | fix font-size resolved from viewport (vw/vh/...) or container (cqw/cqi/...) percentage units coming out deviceScaleFactor times too large — db.no and vg.no headlines overflowing the viewport while eve… |

## Portability / build fixes

| # | Patch | Files | Env flags | Note |
|---|---|---|---|---|
| 1 | `webkit-build-cmake-fixes.patch` | 4 | `WEBKIT_EXECUTABLE_DECLARE` | Build-system fixes for building 2.52.x on the Ubuntu 24.04 runner. Merged from: webkit-icu-imported-targets, webkit-jsc-llint-build-defines, webkit-jsc-shell-object-link. |
| 2 | `webkit-portability-wtf-pal.patch` | 62 | — | Header self-sufficiency / missing-include fixes for WTF and PAL. Merged from 12 patches: webkit-ramsize-cstddef, webkit-wtf-header-includes, webkit-wtf-platform-stdint, webkit-wtf-glib-platform, webki… |
| 3 | `webkit-portability-jsc.patch` | 1127 | — | Header self-sufficiency / missing-include fixes for JavaScriptCore. Merged from 14 patches: webkit-jsc-glib-export-macros, webkit-jsc-assembler-platform, webkit-jsc-cpu-b3-includes, webkit-jsc-b3-expo… |
| 4 | `webkit-portability-webcore.patch` | 16 | — | Header self-sufficiency / compile fixes for WebCore. Merged from 11 patches: webkit-quirks-no-video, webkit-webcore-user-message-handlers-platform, webkit-webcore-colorconversion-export-macros, webkit… |
