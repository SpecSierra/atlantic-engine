# Patch series

**Generated — do not edit.** `python3 scripts/gen-patch-series.py`

Apply order comes from `scripts/patches.sh` and is load-bearing: patches that touch the same file must stay in this order. Validate the stack **sequentially** on a version bump — isolated dry-runs give false failures.

| | Count |
|---|---|
| Patches | 117 |
| …portability / build fixes | 42 |
| …behaviour | 75 |
| Distinct source files touched | 1311 |
| Env flags introduced | 95 |

## Hot files

Files edited by more than one patch — every one is an ordering constraint.

| Source file | Patches |
|---|---|
| `Source/WebCore/platform/graphics/texmap/coordinated/CoordinatedBackingStoreProxy.cpp` | 9 |
| `Source/WebKit/WebProcess/WebPage/CoordinatedGraphics/ThreadedCompositor.cpp` | 8 |
| `Source/WebKit/WebProcess/WebPage/CoordinatedGraphics/LayerTreeHost.cpp` | 7 |
| `Source/WebCore/platform/graphics/skia/SkiaPaintingEngine.cpp` | 6 |
| `Source/WebCore/platform/graphics/texmap/coordinated/CoordinatedBackingStoreProxy.h` | 5 |
| `Source/WebCore/platform/graphics/texmap/coordinated/CoordinatedBackingStoreTile.cpp` | 5 |
| `Source/WebCore/platform/graphics/skia/SkiaPaintingEngine.h` | 4 |
| `Source/WebCore/platform/graphics/texmap/coordinated/CoordinatedPlatformLayer.cpp` | 4 |
| `Source/WebCore/platform/graphics/texmap/coordinated/GraphicsLayerCoordinated.cpp` | 4 |
| `Source/JavaScriptCore/b3/B3Const32Value.h` | 3 |
| `Source/JavaScriptCore/b3/B3Const64Value.h` | 3 |
| `Source/JavaScriptCore/b3/B3ConstDoubleValue.h` | 3 |
| `Source/JavaScriptCore/b3/B3ConstFloatValue.h` | 3 |
| `Source/JavaScriptCore/b3/B3Effects.h` | 3 |
| `Source/JavaScriptCore/b3/B3ExtractValue.h` | 3 |
| `Source/JavaScriptCore/b3/B3MemoryValue.h` | 3 |
| `Source/JavaScriptCore/b3/B3Opcode.h` | 3 |
| `Source/JavaScriptCore/b3/B3PatchpointValue.h` | 3 |
| `Source/JavaScriptCore/b3/B3Procedure.h` | 3 |
| `Source/JavaScriptCore/b3/B3SIMDValue.h` | 3 |
| `Source/JavaScriptCore/b3/B3StackmapSpecial.h` | 3 |
| `Source/JavaScriptCore/b3/B3SwitchValue.h` | 3 |
| `Source/JavaScriptCore/b3/B3Value.h` | 3 |
| `Source/JavaScriptCore/b3/B3WasmBoundsCheckValue.h` | 3 |
| `Source/JavaScriptCore/b3/air/AirArg.h` | 3 |
| `Source/JavaScriptCore/b3/air/AirCode.h` | 3 |
| `Source/JavaScriptCore/b3/air/AirFormTable.h` | 3 |
| `Source/WebCore/page/scrolling/ScrollingTree.cpp` | 3 |
| `Source/WebCore/page/scrolling/ScrollingTree.h` | 3 |
| `Source/WebCore/platform/ScrollAnimationKinetic.cpp` | 3 |
| `Source/WebCore/platform/graphics/texmap/coordinated/CoordinatedBackingStore.cpp` | 3 |
| `Source/WebCore/platform/graphics/texmap/coordinated/CoordinatedBackingStoreTile.h` | 3 |
| `Source/JavaScriptCore/b3/B3AbstractHeapRepository.cpp` | 2 |
| `Source/JavaScriptCore/b3/B3AbstractHeapRepository.h` | 2 |
| `Source/JavaScriptCore/b3/B3BasicBlock.cpp` | 2 |
| `Source/JavaScriptCore/b3/B3BasicBlock.h` | 2 |
| `Source/JavaScriptCore/b3/B3BottomTupleValue.h` | 2 |
| `Source/JavaScriptCore/b3/B3BreakCriticalEdges.h` | 2 |
| `Source/JavaScriptCore/b3/B3BulkMemoryValue.h` | 2 |
| `Source/JavaScriptCore/b3/B3CCallValue.h` | 2 |
| `Source/JavaScriptCore/b3/B3CheckValue.h` | 2 |
| `Source/JavaScriptCore/b3/B3ComputeDivisionMagic.h` | 2 |
| `Source/JavaScriptCore/b3/B3Const128Value.h` | 2 |
| `Source/JavaScriptCore/b3/B3Const32Value.cpp` | 2 |
| `Source/JavaScriptCore/b3/B3Const64Value.cpp` | 2 |
| `Source/JavaScriptCore/b3/B3ConstDoubleValue.cpp` | 2 |
| `Source/JavaScriptCore/b3/B3ConstFloatValue.cpp` | 2 |
| `Source/JavaScriptCore/b3/B3EliminateDeadCode.h` | 2 |
| `Source/JavaScriptCore/b3/B3FenceValue.h` | 2 |
| `Source/JavaScriptCore/b3/B3FixSSA.h` | 2 |
| `Source/JavaScriptCore/b3/B3FoldPathConstants.cpp` | 2 |
| `Source/JavaScriptCore/b3/B3FrequencyClass.h` | 2 |
| `Source/JavaScriptCore/b3/B3Generate.h` | 2 |
| `Source/JavaScriptCore/b3/B3HeapRange.h` | 2 |
| `Source/JavaScriptCore/b3/B3InferSwitches.cpp` | 2 |
| `Source/JavaScriptCore/b3/B3InsertionSet.cpp` | 2 |
| `Source/JavaScriptCore/b3/B3InsertionSet.h` | 2 |
| `Source/JavaScriptCore/b3/B3LowerMacros.cpp` | 2 |
| `Source/JavaScriptCore/b3/B3LowerToAir.cpp` | 2 |
| `Source/JavaScriptCore/b3/B3LowerToAir.h` | 2 |
| `Source/JavaScriptCore/b3/B3LowerToAir32_64.cpp` | 2 |
| `Source/JavaScriptCore/b3/B3MathExtras.h` | 2 |
| `Source/JavaScriptCore/b3/B3MemoryValue.cpp` | 2 |
| `Source/JavaScriptCore/b3/B3MemoryValueInlines.h` | 2 |
| `Source/JavaScriptCore/b3/B3MoveConstants.cpp` | 2 |
| `Source/JavaScriptCore/b3/B3MoveConstants.h` | 2 |
| `Source/JavaScriptCore/b3/B3NativeTraits.h` | 2 |
| `Source/JavaScriptCore/b3/B3Operations.cpp` | 2 |
| `Source/JavaScriptCore/b3/B3OptimizeAssociativeExpressionTrees.cpp` | 2 |
| `Source/JavaScriptCore/b3/B3Origin.h` | 2 |
| `Source/JavaScriptCore/b3/B3PatchpointSpecial.h` | 2 |
| `Source/JavaScriptCore/b3/B3Procedure.cpp` | 2 |
| `Source/JavaScriptCore/b3/B3ReduceStrength.cpp` | 2 |
| `Source/JavaScriptCore/b3/B3ReduceStrength.h` | 2 |
| `Source/JavaScriptCore/b3/B3SlotBaseValue.h` | 2 |
| `Source/JavaScriptCore/b3/B3StackmapGenerationParams.h` | 2 |
| `Source/JavaScriptCore/b3/B3StackmapSpecial.cpp` | 2 |
| `Source/JavaScriptCore/b3/B3StackmapValue.h` | 2 |
| `Source/JavaScriptCore/b3/B3SwitchCase.h` | 2 |
| `Source/JavaScriptCore/b3/B3UpsilonValue.h` | 2 |
| `Source/JavaScriptCore/b3/B3UseCounts.h` | 2 |
| `Source/JavaScriptCore/b3/B3Validate.cpp` | 2 |
| `Source/JavaScriptCore/b3/B3Validate.h` | 2 |
| `Source/JavaScriptCore/b3/B3Value.cpp` | 2 |
| `Source/JavaScriptCore/b3/B3ValueInlines.h` | 2 |
| `Source/JavaScriptCore/b3/B3ValueKey.cpp` | 2 |
| `Source/JavaScriptCore/b3/B3ValueKey.h` | 2 |
| `Source/JavaScriptCore/b3/B3ValueKeyInlines.h` | 2 |
| `Source/JavaScriptCore/b3/B3ValueRep.h` | 2 |
| `Source/JavaScriptCore/b3/B3VariableValue.h` | 2 |
| `Source/JavaScriptCore/b3/B3WasmAddressValue.h` | 2 |
| `Source/JavaScriptCore/b3/B3WasmBoundsCheckValue.cpp` | 2 |
| `Source/JavaScriptCore/b3/air/AirAllocateRegistersAndStackAndGenerateCode.cpp` | 2 |
| `Source/JavaScriptCore/b3/air/AirAllocateRegistersByGraphColoring.cpp` | 2 |
| `Source/JavaScriptCore/b3/air/AirAllocateRegistersByGreedy.cpp` | 2 |
| `Source/JavaScriptCore/b3/air/AirAllocateStackByGraphColoring.cpp` | 2 |
| `Source/JavaScriptCore/b3/air/AirBasicBlock.h` | 2 |
| `Source/JavaScriptCore/b3/air/AirCCallingConvention.cpp` | 2 |
| `Source/JavaScriptCore/b3/air/AirCCallingConvention.h` | 2 |
| `Source/JavaScriptCore/b3/air/AirCode.cpp` | 2 |
| `Source/JavaScriptCore/b3/air/AirDisassembler.cpp` | 2 |
| `Source/JavaScriptCore/b3/air/AirFixObviousSpills.cpp` | 2 |
| `Source/JavaScriptCore/b3/air/AirGenerate.h` | 2 |
| `Source/JavaScriptCore/b3/air/AirLowerStackArgs.cpp` | 2 |
| `Source/JavaScriptCore/b3/air/AirOptimizePairedLoadStore.cpp` | 2 |
| `Source/JavaScriptCore/b3/air/AirSpecial.h` | 2 |
| `Source/JavaScriptCore/b3/air/AirStackSlot.cpp` | 2 |
| `Source/JavaScriptCore/b3/air/AirStackSlot.h` | 2 |
| `Source/JavaScriptCore/b3/air/AirStackSlotKind.h` | 2 |
| `Source/JavaScriptCore/b3/air/AirTmpWidth.cpp` | 2 |
| `Source/JavaScriptCore/b3/air/AirUseCounts.h` | 2 |
| `Source/JavaScriptCore/b3/air/AirValidate.h` | 2 |
| `Source/JavaScriptCore/b3/air/testair.cpp` | 2 |
| `Source/JavaScriptCore/b3/testb3.h` | 2 |
| `Source/JavaScriptCore/b3/testb3_1.cpp` | 2 |
| `Source/JavaScriptCore/b3/testb3_2.cpp` | 2 |
| `Source/JavaScriptCore/b3/testb3_3.cpp` | 2 |
| `Source/JavaScriptCore/b3/testb3_4.cpp` | 2 |
| `Source/JavaScriptCore/b3/testb3_5.cpp` | 2 |
| `Source/JavaScriptCore/b3/testb3_6.cpp` | 2 |
| `Source/JavaScriptCore/b3/testb3_7.cpp` | 2 |
| `Source/JavaScriptCore/b3/testb3_8.cpp` | 2 |
| `Source/JavaScriptCore/runtime/Options.cpp` | 2 |
| `Source/WTF/wtf/glib/ActivityObserver.h` | 2 |
| `Source/WTF/wtf/glib/Application.h` | 2 |
| `Source/WTF/wtf/glib/GRefPtr.h` | 2 |
| `Source/WTF/wtf/glib/GResources.h` | 2 |
| `Source/WTF/wtf/glib/GUniquePtr.h` | 2 |
| `Source/WebCore/page/scrolling/ThreadedScrollingTree.cpp` | 2 |
| `Source/WebCore/platform/graphics/gstreamer/GStreamerCommon.cpp` | 2 |
| `Source/WebCore/platform/graphics/gstreamer/MediaPlayerPrivateGStreamer.cpp` | 2 |
| `Source/WebCore/platform/graphics/texmap/BitmapTexturePool.cpp` | 2 |
| `Source/WebCore/platform/graphics/texmap/BitmapTexturePool.h` | 2 |
| `Source/WebCore/platform/graphics/texmap/coordinated/CoordinatedTileBuffer.cpp` | 2 |
| `Source/WebCore/rendering/svg/legacy/LegacyRenderSVGResourceFilter.cpp` | 2 |
| `Source/WebCore/style/StyleScope.cpp` | 2 |
| `Source/WebCore/style/StyleScope.h` | 2 |
| `Source/WebKit/UIProcess/API/wpe/WPEWebViewLegacy.cpp` | 2 |
| `Source/WebKit/WebProcess/WebPage/EventDispatcher.cpp` | 2 |
| `Source/cmake/OptionsWPE.cmake` | 2 |

## Behaviour patches

| # | Patch | Files | Env flags | Note |
|---|---|---|---|---|
| 1 | `libepoxy-rtld-default-fallback.patch` | 1 | — | — |
| 2 | `webkit-quirks-no-video.patch` | 1 | — | — |
| 3 | `webkit-glfence-disable-env.patch` | 1 | — | — |
| 4 | `webkit-texpool-compositor-sync-env.patch` | 2 | `WEBKIT_BITMAP_TEXTURE_POOL_DISABLED`<br>`WEBKIT_COMPOSITOR_GL_FINISH` | — |
| 5 | `webkit-texpool-synchronous-cap.patch` | 3 | `WEBKIT_TEXPOOL_LOG`<br>`WEBKIT_TEXTURE_POOL_CAP_MB` | BitmapTexturePool's unused-texture release runs on a WebProcess main-thread timer that starves exactly when texture churn peaks (video playback, page load), so released frame/tile textures accumulate … |
| 6 | `webkit-raster-on-compositor-thread-env.patch` | 4 | `WEBKIT_RASTER_ON_COMPOSITOR_THREAD` | — |
| 7 | `webkit-skia-record-rtree-env.patch` | 1 | `WEBKIT_RASTER_ON_COMPOSITOR_THREAD`<br>`WEBKIT_SKIA_RECORD_RTREE` | record the per-layer tile SkPicture with an R-tree BBH so each per-tile replay() culls draw ops to its tile's clip, instead of every tile re-walking/re-submitting the whole layer's op list (an N-tile … |
| 8 | `webkit-directional-tile-coverage-env.patch` | 2 | `WEBKIT_COVER_AREA_MULTIPLIER`<br>`WEBKIT_DIRECTIONAL_TILE_COVERAGE` | — |
| 9 | `webkit-checkerboard-during-scroll-env.patch` | 3 | `WEBKIT_CHECKERBOARD_DURING_SCROLL`<br>`WEBKIT_CHECKERBOARD_SETTLE_MS` | WEBKIT_CHECKERBOARD_DURING_SCROLL — during a fast fling, skip rasterizing newly-exposed tiles (show page background, like Gecko APZ / Cocoa TileController) and defer the paint to the settle timer. Tar… |
| 10 | `webkit-lowres-tiles-during-scroll-env.patch` | 9 | `WEBKIT_CHECKERBOARD_DURING_SCROLL`<br>`WEBKIT_CHECKERBOARD_SETTLE_MS`<br>`WEBKIT_LOWRES_SCROLL_SPEED`<br>`WEBKIT_LOWRES_TILE_SCALE`<br>`WEBKIT_LOWRES_VIEWPORT_FULL` | WEBKIT_LOWRES_TILE_SCALE — during a fast fling, rasterize newly-exposed tiles into a buffer scaled down by this factor (e.g. 0.6) and bilinear-upscale them back to full size at composite time (Chrome/… |
| 11 | `webkit-memory-pressure-threshold-env.patch` | 1 | `WEBKIT_MEMORY_BASE_THRESHOLD_MB`<br>`WEBKIT_MEMORY_POLL_INTERVAL_MS` | make WebKit's memory-pressure purge threshold + poll interval tunable (WEBKIT_MEMORY_BASE_THRESHOLD_MB / WEBKIT_MEMORY_POLL_INTERVAL_MS, defaults exported by runtime-common.sh). Device root cause of t… |
| 12 | `webkit-preserve-style-resolver-on-memory-pressure.patch` | 1 | `WEBKIT_MEMORY_BASE_THRESHOLD_MB`<br>`WEBKIT_PURGE_STYLE_ON_MEMORY_PRESSURE` | skip the Document::styleScope().releaseMemory() call in releaseCriticalMemory() by default, so the aggressive low-threshold memory-pressure purge (needed to bound decoded-image / GPU memory and avoid … |
| 13 | `webkit-skia-image-subsampling.patch` | 6 | `WEBKIT_IMAGE_SUBSAMPLE_MIN_AREA` | enable image subsampling on the Skia/WPE port (upstream gates it to Apple/CG only). Images displayed smaller than their natural size now decode at 1/2, 1/4 or 1/8 resolution (JPEG via libjpeg IDCT sca… |
| 14 | `webkit-webp-subsampling.patch` | 2 | — | the WebP half of the follow-up noted above. libwebp rescales during decode (WebPDecoderConfig::options.use_scaling), so a downscaled draw decodes straight to the reduced size exactly like the JPEG/IDC… |
| 15 | `webkit-png-subsampling.patch` | 2 | — | the last format in the subsampling trio, and the one with no library support — libpng has no equivalent to libjpeg's IDCT scaling or libwebp's use_scaling. But rows arrive one at a time through libpng… |
| 16 | `webkit-cached-subimage.patch` | 4 | `WEBKIT_CACHED_SUBIMAGE`<br>`WEBKIT_CACHED_SUBIMAGE_MAX_SCALE`<br>`WEBKIT_CACHED_SUBIMAGE_MIN_AREA` | make WebCore's CachedSubimage reachable off CG. Upstream ships the class but the only two hooks that drive it (Image::shouldDrawFromCachedSubimage / mustDrawFromCachedSubimage) return false with no no… |
| 17 | `webkit-gpu-process-egl-default-display-fallback.patch` | 4 | — | webkit-gpu-process-by-default-wpe.patch: DISABLED. It hard-enables ENABLE_GPU_PROCESS_DOM_RENDERING_BY_DEFAULT, moving DOM rendering into the GPU process. On this libhybris/Adreno device there is no G… |
| 18 | `webkit-kinetic-decel-friction-env.patch` | 1 | `WEBKIT_KINETIC_DECEL_FRICTION` | make the kinetic-fling deceleration friction tunable (WEBKIT_KINETIC_DECEL_FRICTION, default 4 = upstream). The device-measured fix for "touch momentum feels dead": friction=4 is desktop tuning; a low… |
| 19 | `webkit-adwaita-scrollbar-scale-env.patch` | 1 | `WEBKIT_SCROLLBAR_SCALE` | scale the Adwaita overlay-scrollbar metrics (WEBKIT_SCROLLBAR_SCALE, integer 1..8, default 1 = upstream). Atlantic's 3x UI scale is page zoom, which the native scrollbar widget ignores, so the overlay… |
| 20 | `webkit-scrollbar-sprite-and-smoothing.patch` | 2 | `WEBKIT_SCROLLBAR_SMOOTHING`<br>`WEBKIT_SCROLLBAR_SPRITE` | fix overlay-scrollbar blinking/ teleporting. WEBKIT_SCROLLBAR_SPRITE=1 paints the thumb once (CPU raster) and moves it via setContentsRect instead of Ganesh-repainting a pooled GL texture per scroll t… |
| 21 | `webkit-scrollbar-no-hover-expand.patch` | 2 | `WEBKIT_SCROLLBAR_NO_HOVER` | WEBKIT_SCROLLBAR_NO_HOVER=1 keeps the overlay scrollbar in its idle thin form — no hover/press expansion into the fat desktop bar + trough when touched (also keeps the sprite fast-path, which requires… |
| 22 | `webkit-kinetic-jank-resilient-end.patch` | 1 | — | keep the kinetic fling alive across main-thread jank stalls (the "lag spikes kill scroll inertia" on reddit). A catch-up tick after a stall has near-zero dt, so the per-tick "moved <1px" stop-test fir… |
| 23 | `webkit-touch-gesture-began-phase.patch` | 2 | — | Touch fling harmonization (device-verified on franceinfo.fr / YouTube, build 589). Three complementary patches fixing "scrolling acceleration not harmonized" — dead flings on heavy pages, runaway flin… |
| 24 | `webkit-wheel-coalesce-phase-split.patch` | 1 | `WEBKIT_WHEEL_COALESCE_PHASE_SPLIT` | complementary. canCoalesce()'s phase guard is Cocoa-only upstream, so on a busy page the coalescer could merge a whole flick's motion events and its zero-delta Ended event into one Phase::Ended event … |
| 25 | `webkit-kinetic-fling-velocity-fixes.patch` | 1 | `WEBKIT_KINETIC_END_EVENT_FIX`<br>`WEBKIT_KINETIC_MAX_VELOCITY`<br>`WEBKIT_KINETIC_VELOCITY_ACCUM_MAX`<br>`WEBKIT_KINETIC_VELOCITY_BIAS_FIX` | velocity-estimate corrections in the same file — measure across motion samples only (WEBKIT_KINETIC_END_EVENT_FIX), remove the 1.09-1.12x N/(N-1) inflation (WEBKIT_KINETIC_VELOCITY_BIAS_FIX), and boun… |
| 26 | `webkit-gst-buffer-tuning.patch` | 1 | `WEBKIT_GST_QUEUE_HIGH_WATERMARK`<br>`WEBKIT_GST_RING_BUFFER_MAX_SIZE`<br>`WEBKIT_GST_URIDECODEBIN_BUFFER_SIZE` | makes GstQueue2 high-watermark, urisourcebin ring-buffer-max-size and uridecodebin buffer-size configurable via WEBKIT_GST_QUEUE_HIGH_WATERMARK / WEBKIT_GST_RING_BUFFER_MAX_SIZE / WEBKIT_GST_URIDECODE… |
| 27 | `webkit-gst-media-role-env.patch` | 1 | `WEBKIT_GST_ENABLE_AUDIO_MIXER`<br>`WEBKIT_GST_MEDIA_ROLE` | let WEBKIT_GST_MEDIA_ROLE override the media.role WebKit stamps on its GStreamer audio sinks (hardcoded "video"/ "music"). SFOS's system media volume (module-meego-mainvolume / the hardware volume key… |
| 28 | `webkit-gst-soup-referer.patch` | 2 | `WEBKIT_GST_NO_SOUP_REFERER`<br>`WEBKIT_IS_WEB_SRC`<br>`WEBKIT_WEB_SRC_CAST` | forward the player's Referer to the souphttpsrc elements the adaptive demuxer spawns for HLS variant/segment fetches — CDNs that validate Referer (phncdn: 412 without) killed native HLS right after th… |
| 29 | `webkit-volume-locked-env.patch` | 1 | `WEBKIT_GST_MEDIA_ROLE`<br>`WEBKIT_VOLUME_LOCKED` | WEBKIT_VOLUME_LOCKED=1 — lock the HTML media element volume to the system volume (upstream m_volumeLocked, the iPhone model). Completes the media-role fix above: each new <video> creates a new pulse s… |
| 30 | `webkit-gst-audio-system-clock.patch` | 1 | `WEBKIT_GST_AUDIO_SYSTEM_CLOCK` | WEBKIT_GST_AUDIO_SYSTEM_CLOCK — force provide-clock=FALSE on the PulseAudio sink so the pipeline runs off the monotonic system clock. Fixes "YouTube sound stops after ~0.25 s": the libhybris pulsesink… |
| 31 | `webkit-wpe-dark-mode-runtime.patch` | 2 | — | runtime prefers-color-scheme switch. The legacy libwpe build hardwires SystemSettings darkMode to false, so websites always saw prefers-color-scheme: light. Exports wpe_sfos_set_dark_mode(int) for the… |
| 32 | `webkit-bubblewrap-sfos-sandbox.patch` | 1 | — | — |
| 33 | `webkit-seccomp-filter-no-namespace.patch` | 1 | `ATLANTIC_ENABLE_SECCOMP`<br>`WEBKIT_ENABLE_SECCOMP_FILTER` | install the bwrap seccomp syscall filter (BubblewrapLauncher::setupSeccomp's flatpak block list) directly in every auxiliary process via seccomp_load(), WITHOUT any namespace. The bwrap mount namespac… |
| 34 | `webkit-sticky-scroll-composite-sync-env.patch` | 5 | `WEBKIT_COMPOSITE_SCROLL_SYNC` | WEBKIT_COMPOSITE_SCROLL_SYNC (default on) — before flushing layer state for a composite, re-apply the scrolling tree's layer positions and hold the tree lock across the whole flush, so a composite can… |
| 35 | `webkit-composite-scroll-sync-stall-fix.patch` | 2 | `WEBKIT_COMPOSITE_SCROLL_SYNC` | fixes the "renders once then freezes" regression of the composite-scroll-sync patch — the compositor- thread position re-apply must not set LayerTreeHost::m_compositionRequired (stale signal = scrolli… |
| 36 | `webkit-composite-scroll-sync-lock-only.patch` | 2 | `WEBKIT_COMPOSITE_SCROLL_SYNC` | v3 — drop the compositor- thread applyLayerPositions walk (stalled the rendering-update cycle, builds 420/421) and restore upstream notifyCompositionRequired (the 421 suppression ate the legitimate co… |
| 37 | `webkit-wpe-spellcheck-enchant.patch` | 8 | — | WPE has no TextChecker backend upstream (spellcheck is GTK-only); port the GTK enchant-backed implementation so ENABLE_SPELLCHECK builds/works. |
| 38 | `webkit-loading-timer-alignment-env.patch` | 1 | `WEBKIT_LOADING_TIMER_ALIGNMENT_MS` | Load-time responsiveness pair: during a heavy page load the WebProcess main thread is saturated and queued touch events starve (page cannot scroll until the load event fires). These two shrink the mai… |
| 39 | `webkit-parser-time-limit-env.patch` | 1 | `WEBKIT_PARSER_TIME_LIMIT_MS` | — |
| 40 | `webkit-touch-ack-timeout-env.patch` | 3 | `WEBKIT_TOUCH_ACK_TIMEOUT_MS` | - touch-ack-timeout: UIProcess-side gesture recognition when the WebProcess doesn't ack touch events in time + stop dropping late-reply gesture events; makes scrolling work DURING page load (WEBKIT_TO… |
| 41 | `webkit-url-cache-disk-capacity-env.patch` | 1 | `ATLANTIC_CACHE_MODEL`<br>`WEBKIT_URL_CACHE_DISK_CAPACITY_MB` | WEBKIT_URL_CACHE_DISK_CAPACITY_MB overrides the cache-model-derived HTTP disk cache capacity (NetworkProcess). Lets the ship config keep ATLANTIC_CACHE_MODEL=viewer (smallest RAM caches, no bfcache — … |
| 42 | `webkit-sw-fallback-http-cache.patch` | 1 | `WEBKIT_SW_FALLBACK_HTTP_CACHE` | when a service worker's fetch handler does not respondWith() (pass-through, e.g. theverge's ad-block SW), the stock fallback restarts as a raw network load that neither reads nor stores the HTTP disk … |
| 43 | `webkit-no-full-repaint-on-layer-grow.patch` | 3 | `WEBKIT_REPAINT_ON_LAYER_RESIZE` | don't repaint a whole layer just because it changed size — the coordinated tiled backing store keeps existing tile content valid across resizes and only newly exposed tiles need painting. During a hea… |
| 44 | `webkit-no-full-repaint-on-composited-move.patch` | 1 | `WEBKIT_PAINT_LOG`<br>`WEBKIT_REPAINT_ON_COMPOSITED_MOVE` | the SCROLL-time analog of the grow patch. A self-painting composited layer that merely MOVED (or jittered <=1px in size) during a layout does not need its whole backing re-rastered — the compositor re… |
| 45 | `webkit-paint-log-diagnostic.patch` | 2 | `WEBKIT_PAINT_LOG`<br>`WEBKIT_REPAINT_ON_LAYER_RESIZE` | NOTE: the load-rendering-throttle patches are GONE (dropped after builds 465-471). Coalescing main-thread rendering updates during load to cut the paint storm (~340 Mpx/franceinfo load) fundamentally … |
| 46 | `webkit-style-smart-reconstruct.patch` | 3 | `WEBKIT_STYLE_LOG`<br>`WEBKIT_STYLE_SMART_RECONSTRUCT` | PoC (WEBKIT_STYLE_SMART_RECONSTRUCT=1, off by default). Downgrades ContentsOrInterpretation stylesheet updates that were NOT caused by a real contents mutation or genuine environment change: the updat… |
| 47 | `webkit-style-reconstruct-source-attr.patch` | 2 | `WEBKIT_STYLE_LOG` | DIAGNOSTIC-ONLY (no behaviour change), extends the WEBKIT_STYLE_LOG=1 [stylelog] line with src=<sheet-contents|environment| media-query|weak-rdar|?> contentsMutation=<0|1>, attributing every ContentsO… |
| 48 | `webkit-scrolltier-log-diagnostic.patch` | 1 | `WEBKIT_LOWRES_TILE_SCALE`<br>`WEBKIT_SCROLLTIER_LOG` | TEMPORARY env-gated scroll-speed-ladder tracing (WEBKIT_SCROLLTIER_LOG=1, WebProcess stderr) — the low-res-tiles-during- scroll feature stopped engaging on device (build 480); logs dy-path eligibility… |
| 49 | `webkit-lowres-tiles-cpu-path.patch` | 2 | `WEBKIT_SCROLLTIER_LOG`<br>`WEBKIT_SKIA_ENABLE_CPU_RENDERING` | enable low-res tiles on the CPU rendering path (WEBKIT_SKIA_ENABLE_CPU_RENDERING=1 had silently disabled the whole feature — the force-1.0 guards in paint/replay). CPU upload of a whole-tile low-res b… |
| 50 | `webkit-tile-raster-cost-instrumentation.patch` | 2 | `WEBKIT_LOWRES_TILE_SCALE`<br>`WEBKIT_SKIA_ENABLE_CPU_RENDERING`<br>`WEBKIT_TILECOST_LOG` | measure what the scroll ladder is blind to — raster cost per painted pixel (EWMA, sampled on the real raster threads), exposed via SkiaPaintingEngine::tileRasterNsPerPixel() for a cost-aware trigger. … |
| 51 | `webkit-lowres-cost-trigger.patch` | 2 | `WEBKIT_LOWRES_COST_BUDGET_MS`<br>`WEBKIT_LOWRES_COST_CHECKERBOARD_X`<br>`WEBKIT_LOWRES_COST_DISENGAGE_PASSES`<br>`WEBKIT_LOWRES_COST_ENGAGE_X`<br>`WEBKIT_LOWRES_COST_MOTION_MS`<br>`WEBKIT_LOWRES_COST_SCALE_FLOOR`<br>`WEBKIT_LOWRES_COST_TRIGGER`<br>`WEBKIT_LOWRES_TILE_SCALE`<br>`WEBKIT_SCROLLTIER_LOG` | decide scroll degradation from PREDICTED RASTER COST vs the frame budget instead of scroll speed, with the low-res scale derived as 1/sqrt(overshoot) rather than a fixed cliff, plus asymmetric hystere… |
| 52 | `webkit-lowres-tile-edge-seam.patch` | 2 | — | fix the dark grid at tile boundaries while low-res tiles are active. lowResBufferSize() ceil()'d the buffer while content painted at the requested scale, leaving a transparent fractional texel column … |
| 53 | `webkit-lowres-sharpen-viewport-scope.patch` | 1 | `WEBKIT_LOWRES_COST_ENGAGE_X`<br>`WEBKIT_LOWRES_SHARPEN_MARGIN_PX`<br>`WEBKIT_LOWRES_SHARPEN_VIEWPORT_ONLY`<br>`WEBKIT_SCROLLTIER_LOG` | the sharpen-at-rest pass repaints EVERY low-res tile full-res when degradation ends, including the prepaint cushion (cover 2 => ~half the tiles were never looked at), landing just as the user stops sc… |
| 54 | `webkit-fling-throttle-env.patch` | 4 | `WEBKIT_FLING_THROTTLE_MS`<br>`WEBKIT_FLING_THROTTLE_SETTLE_MS`<br>`WEBKIT_FLING_THROTTLE_SPEED` | fling degradation for main-thread-bound pages (franceinfo/radiofrance scroll <1fps, 44% style resolution). While the scrolling thread reports a fast fling (velocity sampled in ScrollingTree::scrolling… |
| 55 | `webkit-force-async-scroll-env.patch` | 2 | `WEBKIT_FORCE_ASYNC_SCROLL` | WEBKIT_FORCE_ASYNC_SCROLL — device- root-caused (franceinfo, build 491): the page's non-composited fixed/sticky elements set SynchronousScrollingReason::HasNonLayerViewportConstrainedObjects, which fo… |
| 56 | `webkit-independent-scroll-env.patch` | 1 | `WEBKIT_FORCE_ASYNC_SCROLL`<br>`WEBKIT_INDEPENDENT_SCROLL` | WEBKIT_INDEPENDENT_SCROLL — fully separate scrolling from the main-thread rendering update (Gecko/APZ, i.e. what the EmbedLite port does). Upstream is a *conditional* desync: on every display refresh … |
| 57 | `webkit-scrolling-thread-display-link-env.patch` | 2 | `WEBKIT_INDEPENDENT_SCROLL` | the other half of WEBKIT_INDEPENDENT_SCROLL, and the one that makes it actually do anything. The scheduling half above lets the scrolling thread commit layer positions without waiting for the main thr… |
| 58 | `webkit-scrolling-thread-tick-env.patch` | 2 | `WEBKIT_FORCE_VBLANK_TIMER`<br>`WEBKIT_INDEPENDENT_SCROLL`<br>`WEBKIT_INDEPENDENT_SCROLL_TICK_MS` | the scrolling thread gets a tick of its OWN. Everything that normally delivers displayDidRefresh -- the scrolling thread's entire heartbeat -- is owned by someone else: the UIProcess decides (from whe… |
| 59 | `webkit-tile-upload-budget-env.patch` | 8 | `WEBKIT_TILE_UPLOAD_BUDGET_MB` | WEBKIT_TILE_UPLOAD_BUDGET_MB — cap the tile work one composite may do. Device-root-caused (build 495): after each ~1s main-thread pass commits screenfuls of CPU-painted tiles, the next composite (a) B… |
| 60 | `webkit-tile-upload-scroll-gate.patch` | 5 | `WEBKIT_TILE_UPLOAD_BUDGET_SCROLL_ONLY`<br>`WEBKIT_TILE_UPLOAD_SCROLL_SETTLE_MS` | make the upload budget behave like other browsers visually. (1) WEBKIT_TILE_UPLOAD_BUDGET_SCROLL_ONLY (default 1): the budget only meters composites while the scrolling tree reports motion (atomic sta… |
| 61 | `webkit-tile-upload-nonblocking-settle.patch` | 1 | `WEBKIT_TILE_UPLOAD_REST_BUDGET_MB` | the scroll gate's settled composite fell back to the STOCK drain — unbounded glTexSubImage batch plus blocking in waitUntilPaintingComplete for buffers Skia workers are still painting. Every settle fl… |
| 62 | `webkit-no-fake-mouse-move-env.patch` | 1 | `WEBKIT_NO_FAKE_MOUSE_MOVE` | Touch devices: kill the fake mouse-move WebKit dispatches after every scroll at the stale synthetic-tap position, which :hover-highlights whatever link scrolls under the invisible cursor (WEBKIT_NO_FA… |
| 63 | `webkit-video-proxy-target-unbind-guard.patch` | 3 | — | Video contents-buffer proxy: when the <video> element's backing layer is rebuilt (fullscreen enter/exit, navigation), the OLD GraphicsLayer's teardown unbound the shared buffer proxy AFTER the new lay… |
| 64 | `webkit-damage-limited-composite-env.patch` | 1 | `WEBKIT_DAMAGE_COMPOSITING`<br>`WEBKIT_DAMAGE_UNIFY`<br>`WEBKIT_DAMAGE_USE_FOR_COMPOSITING` | Damage-limited compositing: enable WebKit's compiled-in-but-WPE-disabled damage subsystem so a composite is scissored to the region that actually changed instead of redrawing the whole scene (WEBKIT_D… |
| 65 | `webkit-tile-buffer-skip-zero-env.patch` | 1 | `WEBKIT_TILE_BUFFER_SKIP_ZERO` | Skip the redundant main-thread memset of CPU tile buffers: the Skia worker clears+paints every tile before it is composited, so tryZeroedMalloc on the main thread is wasted work - device-measured as t… |
| 66 | `webkit-frame-trace-env.patch` | 5 | `ATLANTIC_FRAME_TRACE`<br>`ATLANTIC_REPAINT_BT`<br>`WEBKIT_COVER_AREA_MULTIPLIER` | Frame-trace diagnostic (ATLANTIC_FRAME_TRACE=1, default OFF): CLOCK_MONOTONIC marker at each WebProcess composite, paired with the qt5-plugin ui recv/paint/ ack markers to localize the franceinfo free… |
| 67 | `webkit-video-composite-tile-gate-env.patch` | 1 | `ATLANTIC_FRAME_TRACE`<br>`WEBKIT_INDEPENDENT_SCROLL`<br>`WEBKIT_VIDEO_COMPOSITE_UNGATED` | WEBKIT_VIDEO_COMPOSITE_UNGATED=1 (default OFF) — ThreadedCompositor::scheduleUpdateLocked()'s State::Idle branch tests the raw isWaitingForTiles, so an idle compositor parks EVERY composition request … |
| 68 | `webkit-root-customprop-repaint-skip-env.patch` | 1 | `ATLANTIC_FRAME_TRACE`<br>`ATLANTIC_REPAINT_BT`<br>`WEBKIT_SKIP_ROOT_CUSTOMPROP_REPAINT` | THE franceinfo scroll-freeze fix: WEBKIT_SKIP_ROOT_CUSTOMPROP_REPAINT=1 (default ON) stops RenderBox::styleWillChange from repainting the whole page when a :root/<body> custom-property changes (the si… |
| 69 | `webkit-drop-tiles-when-hidden-env.patch` | 4 | `WEBKIT_DROP_TILES_WHEN_HIDDEN` | WEBKIT_DROP_TILES_WHEN_HIDDEN=1 (default OFF, A/B) makes a backgrounded tab drop its tiled-backing tiles. Device-measured: a hidden tab pins ~1 GB of GPU tile textures forever (the cover rect in Coord… |
| 70 | `webkit-composite-skip-locked-layers-env.patch` | 1 | `WEBKIT_COMPOSITE_SKIP_LOCKED_LAYERS` | WEBKIT_COMPOSITE_SKIP_LOCKED_- LAYERS=1 (default OFF) — the video fast path. CoordinatedPlatformLayer:: flushCompositingState() (compositor thread) blocks on the per-layer m_lock that the MAIN thread … |
| 71 | `webkit-svg-raster-cache.patch` | 3 | `WEBKIT_SVG_RASTER_CACHE`<br>`WEBKIT_SVG_RASTER_CACHE_MAX_AREA_PX` | WebKit has NO raster cache for SVG-as-image (SVGImageCache caches only size wrappers): SVGImage::draw re-lays-out and re-paints the whole embedded SVG document on EVERY draw, so each tile record re-ve… |
| 72 | `webkit-svg-filter-results-reuse.patch` | 5 | `WEBKIT_SVG_FILTER_RESULTS_REUSE` | animated/transformed elements with SVG filters re-ran the ENTIRE filter graph every frame: any client invalidation (a per-frame transform translate is the common case) destroys the legacy FilterData, … |
| 73 | `webkit-svg-filter-scale-cap.patch` | 1 | `WEBKIT_SVG_FILTER_SCALE_CAP` | cap the SVG filter rasterization scale (default 2.0, WEBKIT_SVG_FILTER_SCALE_CAP env-tunable, 0 = off). Atlantic's 3x UI scale is page zoom, so software filter buffers (feTurbulence/ lighting/blur — p… |
| 74 | `webkit-clipboard-qt-hook.patch` | 1 | `ATLANTIC_DISABLE_CLIPBOARD_BRIDGE` | make web clipboard writes reach the SFOS system clipboard. The libwpe pasteboard singleton is an in-process std::map stub in this fdo build (no _wpe_pasteboard_interface exported), so navigator.clipbo… |
| 75 | `webkit-viewport-unit-font-size-zoom.patch` | 1 | `WEBKIT_FONT_SIZE_UNIT_UNZOOM` | fix font-size resolved from viewport (vw/vh/...) or container (cqw/cqi/...) percentage units coming out deviceScaleFactor times too large — db.no and vg.no headlines overflowing the viewport while eve… |

## Portability / build fixes

| # | Patch | Files | Env flags | Note |
|---|---|---|---|---|
| 1 | `webkit-icu-imported-targets.patch` | 2 | — | — |
| 2 | `webkit-ramsize-cstddef.patch` | 1 | — | — |
| 3 | `webkit-wtf-header-includes.patch` | 2 | — | — |
| 4 | `webkit-wtf-platform-stdint.patch` | 4 | — | — |
| 5 | `webkit-wtf-glib-platform.patch` | 16 | — | — |
| 6 | `webkit-wtf-glib-header-includes.patch` | 10 | — | — |
| 7 | `webkit-wtf-linux-header-includes.patch` | 4 | — | — |
| 8 | `webkit-wtf-posix-unix-platform.patch` | 6 | — | — |
| 9 | `webkit-memoryfootprint-cstddef.patch` | 1 | — | — |
| 10 | `webkit-unistdextras-includes.patch` | 1 | — | — |
| 11 | `webkit-pal-system-header-includes.patch` | 6 | — | — |
| 12 | `webkit-pal-text-header-includes.patch` | 11 | — | — |
| 13 | `webkit-pal-header-owners.patch` | 5 | — | — |
| 14 | `webkit-jsc-glib-export-macros.patch` | 3 | — | — |
| 15 | `webkit-jsc-assembler-platform.patch` | 3 | — | — |
| 16 | `webkit-jsc-cpu-b3-includes.patch` | 3 | — | — |
| 17 | `webkit-jsc-b3-export-macros.patch` | 51 | — | — |
| 18 | `webkit-jsc-b3-platform.patch` | 294 | — | — |
| 19 | `webkit-jsc-b3-cstdint.patch` | 85 | — | — |
| 20 | `webkit-jsc-bytecode-platform.patch` | 69 | — | — |
| 21 | `webkit-jsc-dfg-platform.patch` | 306 | — | — |
| 22 | `webkit-jsc-ftl-platform.patch` | 61 | — | — |
| 23 | `webkit-jsc-heap-cstddef.patch` | 76 | — | — |
| 24 | `webkit-jsc-inspector-remote-glib.patch` | 5 | — | — |
| 25 | `webkit-jsc-jit-platform.patch` | 99 | — | — |
| 26 | `webkit-jsc-lol-platform.patch` | 5 | — | — |
| 27 | `webkit-jsc-wasm-platform.patch` | 193 | — | — |
| 28 | `webkit-jsc-llint-build-defines.patch` | 1 | — | — |
| 29 | `webkit-jsc-shell-object-link.patch` | 1 | `WEBKIT_EXECUTABLE_DECLARE` | — |
| 30 | `webkit-webcore-user-message-handlers-platform.patch` | 1 | — | — |
| 31 | `webkit-webcore-colorconversion-export-macros.patch` | 1 | — | — |
| 32 | `webkit-webcore-webkitnamespace-platform.patch` | 1 | — | — |
| 33 | `webkit-webcore-avif-platform.patch` | 1 | — | — |
| 34 | `webkit-webcore-avif-reader-platform.patch` | 1 | — | — |
| 35 | `webkit-webcore-context-export-macros.patch` | 1 | — | — |
| 36 | `webkit-webcore-bitmaptexturepool-owners.patch` | 1 | — | — |
| 37 | `webkit-webcore-texmap-owner-headers.patch` | 5 | — | — |
| 38 | `webkit-renderbox-isnan.patch` | 1 | — | — |
| 39 | `webkit-shapeoutside-isnan.patch` | 1 | — | — |
| 40 | `webkit-jsc-linux-arm64-thread-tuning.patch` | 1 | — | — |
| 41 | `webkit-jsc-linux-arm64-jit-thresholds.patch` | 1 | — | — |
| 42 | `webkit-webcore-scroll-anim-narrowing.patch` | 1 | — | — |
