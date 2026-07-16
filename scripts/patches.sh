#!/bin/bash

readonly ENGINE_SOURCE_PATCHES=(
    "patches/engine/libepoxy-rtld-default-fallback.patch"
)

readonly WEBKIT_SOURCE_PATCHES=(
    "patches/webkit/webkit-quirks-no-video.patch"
    "patches/webkit/webkit-icu-imported-targets.patch"
    "patches/webkit/webkit-ramsize-cstddef.patch"
    "patches/webkit/webkit-wtf-header-includes.patch"
    "patches/webkit/webkit-wtf-platform-stdint.patch"
    "patches/webkit/webkit-wtf-glib-platform.patch"
    "patches/webkit/webkit-wtf-glib-header-includes.patch"
    "patches/webkit/webkit-wtf-linux-header-includes.patch"
    "patches/webkit/webkit-wtf-posix-unix-platform.patch"
    "patches/webkit/webkit-memoryfootprint-cstddef.patch"
    "patches/webkit/webkit-unistdextras-includes.patch"
    "patches/webkit/webkit-pal-system-header-includes.patch"
    "patches/webkit/webkit-pal-text-header-includes.patch"
    "patches/webkit/webkit-pal-header-owners.patch"
    "patches/webkit/webkit-jsc-glib-export-macros.patch"
    "patches/webkit/webkit-jsc-assembler-platform.patch"
    "patches/webkit/webkit-jsc-cpu-b3-includes.patch"
    "patches/webkit/webkit-jsc-b3-export-macros.patch"
    "patches/webkit/webkit-jsc-b3-platform.patch"
    "patches/webkit/webkit-jsc-b3-cstdint.patch"
    "patches/webkit/webkit-jsc-bytecode-platform.patch"
    "patches/webkit/webkit-jsc-dfg-platform.patch"
    "patches/webkit/webkit-jsc-ftl-platform.patch"
    "patches/webkit/webkit-jsc-heap-cstddef.patch"
    "patches/webkit/webkit-jsc-inspector-remote-glib.patch"
    "patches/webkit/webkit-jsc-jit-platform.patch"
    "patches/webkit/webkit-jsc-lol-platform.patch"
    "patches/webkit/webkit-jsc-wasm-platform.patch"
    "patches/webkit/webkit-jsc-llint-build-defines.patch"
    "patches/webkit/webkit-jsc-shell-object-link.patch"
    "patches/webkit/webkit-webcore-user-message-handlers-platform.patch"
    "patches/webkit/webkit-webcore-colorconversion-export-macros.patch"
    "patches/webkit/webkit-webcore-webkitnamespace-platform.patch"
    "patches/webkit/webkit-webcore-avif-platform.patch"
    "patches/webkit/webkit-webcore-avif-reader-platform.patch"
    "patches/webkit/webkit-webcore-context-export-macros.patch"
    "patches/webkit/webkit-webcore-bitmaptexturepool-owners.patch"
    "patches/webkit/webkit-webcore-texmap-owner-headers.patch"
    "patches/webkit/webkit-glfence-disable-env.patch"
    "patches/webkit/webkit-texpool-compositor-sync-env.patch"
    # webkit-texpool-synchronous-cap.patch: BitmapTexturePool's unused-texture
    # release runs on a WebProcess main-thread timer that starves exactly when
    # texture churn peaks (video playback, page load), so released frame/tile
    # textures accumulate without bound (device-measured 1.27 GB of dead 1080p
    # video-frame textures in one WebProcess -> phone swap-thrash + OOM).
    # Enforce the pool cap synchronously in acquireTexture() on the compositor
    # thread (GL context guaranteed current), scoped to free (refCount==1)
    # entries. WEBKIT_TEXTURE_POOL_CAP_MB overrides (0 = stock for A/B);
    # WEBKIT_TEXPOOL_LOG=1 logs pool stats.
    "patches/webkit/webkit-texpool-synchronous-cap.patch"
    "patches/webkit/webkit-raster-on-compositor-thread-env.patch"
    # webkit-skia-record-rtree-env.patch: record the per-layer tile SkPicture with
    # an R-tree BBH so each per-tile replay() culls draw ops to its tile's clip,
    # instead of every tile re-walking/re-submitting the whole layer's op list
    # (an N-tile dirty band cost ~N x the full list). Lossless; the win scales with
    # tiles painted per flush -- targets late-painting tiles on a fast scroll, where
    # replay is serialized on the compositor thread. WEBKIT_SKIA_RECORD_RTREE=0
    # disables (A/B). Must come AFTER raster-on-compositor (same file).
    "patches/webkit/webkit-skia-record-rtree-env.patch"
    "patches/webkit/webkit-directional-tile-coverage-env.patch"
    # webkit-checkerboard-during-scroll-env.patch: WEBKIT_CHECKERBOARD_DURING_SCROLL
    # — during a fast fling, skip rasterizing newly-exposed tiles (show page
    # background, like Gecko APZ / Cocoa TileController) and defer the paint to the
    # settle timer. Targets the per-tile gpu-sync paint cost on the scroll hot path.
    # Off by default (env-gated); must come AFTER the directional-coverage patch
    # since both edit CoordinatedBackingStoreProxy.
    "patches/webkit/webkit-checkerboard-during-scroll-env.patch"
    # webkit-lowres-tiles-during-scroll-env.patch: WEBKIT_LOWRES_TILE_SCALE — during
    # a fast fling, rasterize newly-exposed tiles into a buffer scaled down by this
    # factor (e.g. 0.6) and bilinear-upscale them back to full size at composite time
    # (Chrome/Android "low-res tiles"), then repaint full-res once scrolling settles.
    # Raster/fill cost is quadratic in scale, so this directly cuts the per-frame
    # GPU/raster pixel cost on the serialized compositor-thread paint path — the
    # remaining lever after rtree/style-resolver/raster-on-compositor. An alternative
    # to checkerboard for the same exposed band (paint-cheap-now vs paint-later); A/B
    # them. DEFAULT ON at scale 0.3 (set WEBKIT_LOWRES_TILE_SCALE>=1.0 to disable).
    # Speed ladder: WEBKIT_LOWRES_SCROLL_SPEED (T1, quick=low-res) <
    # WEBKIT_CHECKERBOARD_DURING_SCROLL (T2, ultra-fast=checkerboard). Must come AFTER the checkerboard
    # patch — it edits the same CoordinatedBackingStoreProxy / SkiaPaintingEngine /
    # CoordinatedBackingStore(Tile) / CoordinatedPlatformLayer files and reuses the
    # checkerboard fling-detect/settle signal.
    "patches/webkit/webkit-lowres-tiles-during-scroll-env.patch"
    # webkit-memory-pressure-threshold-env.patch: make WebKit's memory-pressure
    # purge threshold + poll interval tunable (WEBKIT_MEMORY_BASE_THRESHOLD_MB /
    # WEBKIT_MEMORY_POLL_INTERVAL_MS, defaults exported by runtime-common.sh).
    # Device root cause of the reddit "big lag spikes": the WebProcess footprint
    # that pushes the SYSTEM into the kernel lowmemorykiller (multi-second
    # major-fault thrashing on scroll) is only ~700 MB, but WebKit's default
    # baseThreshold = min(3 GB, RAM) means it only purges its decoded-image / tile
    # caches at ~1 GB and re-checks every 30 s, so it never feels pressure before
    # the kernel thrashes. The device default (1200 MB base, 3 s poll) makes the
    # handler purge at ~400-600 MB. Kill threshold is unaffected (ramSize-based).
    "patches/webkit/webkit-memory-pressure-threshold-env.patch"
    # webkit-preserve-style-resolver-on-memory-pressure.patch: skip the
    # Document::styleScope().releaseMemory() call in releaseCriticalMemory() by
    # default, so the aggressive low-threshold memory-pressure purge (needed to
    # bound decoded-image / GPU memory and avoid OOM at MEMORY_BASE_THRESHOLD_MB=
    # 700) stops nuking + rebuilding the CSS style resolver every poll. On reddit
    # (many stylesheets + shadow DOM) that rebuild (appendAuthorStyleSheets /
    # RuleSetBuilder) ran on every style update during scroll and pinned the main
    # thread ~88% (gdb-profiled), starving tile recording so new tiles paint late.
    # All footprint-bounding purges (decoded images, bfcache, caches, GC) are kept.
    # WEBKIT_PURGE_STYLE_ON_MEMORY_PRESSURE=1 restores upstream behaviour.
    "patches/webkit/webkit-preserve-style-resolver-on-memory-pressure.patch"
    # webkit-skia-image-subsampling.patch: enable image subsampling on the
    # Skia/WPE port (upstream gates it to Apple/CG only). Images displayed
    # smaller than their natural size now decode at 1/2, 1/4 or 1/8 resolution
    # (JPEG via libjpeg IDCT scaling), cutting BOTH decode CPU and decoded-bitmap
    # RAM — the RAM-safe way to speed up image-heavy pages on this ~3.5 GB device
    # (raising the decoded-image cache / memory threshold is not an option: it
    # OOMs). Un-gates BitmapImageDescriptor::subsamplingLevelForScaleFactor for
    # USE(SKIA), threads the level through ScalableImageDecoder into a scaled
    # JPEG decode, and lowers the "min area worth subsampling" from Apple's 5 MP
    # to ~1 MP (tunable via WEBKIT_IMAGE_SUBSAMPLE_MIN_AREA) so 1-3 MP feed photos
    # — the actual decode-cost offenders — are covered. Non-JPEG decoders opt out
    # via supportsSubsampling() and stay full-resolution (WebP/PNG = follow-up).
    "patches/webkit/webkit-skia-image-subsampling.patch"
    "patches/webkit/webkit-renderbox-isnan.patch"
    "patches/webkit/webkit-shapeoutside-isnan.patch"
    # webkit-gpu-process-by-default-wpe.patch: DISABLED. It hard-enables
    # ENABLE_GPU_PROCESS_DOM_RENDERING_BY_DEFAULT, moving DOM rendering into the
    # GPU process. On this libhybris/Adreno device there is no GBM / DRM render
    # node, so the GPU process cannot export composited frames — pages render
    # blank (chrome draws, content area white). Verified on-device (Xperia 10 II).
    # Keep DOM rendering in the WebProcess (the path that exports via WPEBackend-fdo).
    # The patch file is kept in patches/webkit/ for reference / future hybris
    # GPU-export work. See also webkit-gpu-process-egl-default-display-fallback.
    # "patches/webkit/webkit-gpu-process-by-default-wpe.patch"
    "patches/webkit/webkit-gpu-process-egl-default-display-fallback.patch"
    "patches/webkit/webkit-jsc-linux-arm64-thread-tuning.patch"
    "patches/webkit/webkit-jsc-linux-arm64-jit-thresholds.patch"
    "patches/webkit/webkit-webcore-scroll-anim-narrowing.patch"
    # webkit-kinetic-decel-friction-env.patch: make the kinetic-fling deceleration
    # friction tunable (WEBKIT_KINETIC_DECEL_FRICTION, default 4 = upstream). The
    # device-measured fix for "touch momentum feels dead": friction=4 is desktop
    # tuning; a lower value gives the longer, smoother glide phone flicking expects.
    # Browser sets the device default in apps/browser/main.cpp.
    "patches/webkit/webkit-kinetic-decel-friction-env.patch"
    # webkit-adwaita-scrollbar-scale-env.patch: scale the Adwaita overlay-scrollbar
    # metrics (WEBKIT_SCROLLBAR_SCALE, integer 1..8, default 1 = upstream). Atlantic's
    # 3x UI scale is page zoom, which the native scrollbar widget ignores, so the
    # overlay thumb painted 3 physical px wide on the 1080px screen. runtime-common.sh
    # sets 3 to match the browser zoom factor.
    "patches/webkit/webkit-adwaita-scrollbar-scale-env.patch"
    # webkit-scrollbar-sprite-and-smoothing.patch: fix overlay-scrollbar blinking/
    # teleporting. WEBKIT_SCROLLBAR_SPRITE=1 paints the thumb once (CPU raster)
    # and moves it via setContentsRect instead of Ganesh-repainting a pooled GL
    # texture per scroll tick (unordered on this driver = stale/blank frames);
    # WEBKIT_SCROLLBAR_SMOOTHING low-pass filters the displayed position.
    "patches/webkit/webkit-scrollbar-sprite-and-smoothing.patch"
    # webkit-kinetic-jank-resilient-end.patch: keep the kinetic fling alive across
    # main-thread jank stalls (the "lag spikes kill scroll inertia" on reddit). A
    # catch-up tick after a stall has near-zero dt, so the per-tick "moved <1px"
    # stop-test fired at high velocity and killed the fling; only trust that test
    # over a real frame interval. Applies on top of the friction patch above.
    "patches/webkit/webkit-kinetic-jank-resilient-end.patch"
    # webkit-gst-buffer-tuning.patch: makes GstQueue2 high-watermark,
    # urisourcebin ring-buffer-max-size and uridecodebin buffer-size
    # configurable via WEBKIT_GST_QUEUE_HIGH_WATERMARK /
    # WEBKIT_GST_RING_BUFFER_MAX_SIZE / WEBKIT_GST_URIDECODEBIN_BUFFER_SIZE
    # (defaults exported by deploy/runtime-common.sh). Authored in 20106a4 but
    # never added to this list — the runtime env vars were dead until now.
    "patches/webkit/webkit-gst-buffer-tuning.patch"
    # webkit-gst-media-role-env.patch: let WEBKIT_GST_MEDIA_ROLE override the
    # media.role WebKit stamps on its GStreamer audio sinks (hardcoded "video"/
    # "music"). SFOS's system media volume (module-meego-mainvolume / the hardware
    # volume keys) only steps streams whose media.role is in its route table —
    # "x-maemo" on Sailfish — so with the upstream roles the volume keys can't
    # attenuate browser audio at all. Setting WEBKIT_GST_MEDIA_ROLE=x-maemo
    # (deploy/runtime-common.sh) puts every browser audio stream in the system
    # media-volume group = native, browser-level volume control. Device-proven:
    # an x-maemo pacat stream tracks the volume step; "music"/"video" do not.
    # PULSE_PROP_OVERRIDE can't do this — it only sets the context proplist, and
    # WebKit's explicit per-stream media.role wins. Unset = upstream behaviour.
    "patches/webkit/webkit-gst-media-role-env.patch"
    # webkit-volume-locked-env.patch: WEBKIT_VOLUME_LOCKED=1 — lock the HTML
    # media element volume to the system volume (upstream m_volumeLocked, the
    # iPhone model). Completes the media-role fix above: each new <video>
    # creates a new pulse stream and WebKit stamped el.volume (1.0; YouTube
    # sets it per video) onto it as an explicit stream volume, so every next
    # video reset loudness to 100% instead of inheriting the mainvolume step
    # (device-proven with pacat: explicit-volume stream connects at 100% while
    # the step sits at 44%). Locked: page JS can't change the stream volume
    # (mute still works), el.volume mirrors the system volume, and new streams
    # inherit the current step. Unset = upstream behaviour.
    "patches/webkit/webkit-volume-locked-env.patch"
    # webkit-gst-audio-system-clock.patch: WEBKIT_GST_AUDIO_SYSTEM_CLOCK — force
    # provide-clock=FALSE on the PulseAudio sink so the pipeline runs off the
    # monotonic system clock. Fixes "YouTube sound stops after ~0.25 s": the
    # libhybris pulsesink clock intermittently freezes when its stream is (re)corked
    # across a mute/unmute or MSE re-init, deadlocking the slaved pipeline (audio
    # cuts out, picture freezes). Must come AFTER the media-role patch — it extends
    # the same autoaudiosink "child-added" hook.
    "patches/webkit/webkit-gst-audio-system-clock.patch"
    # webkit-wpe-dark-mode-runtime.patch: runtime prefers-color-scheme switch.
    # The legacy libwpe build hardwires SystemSettings darkMode to false, so
    # websites always saw prefers-color-scheme: light. Exports
    # wpe_sfos_set_dark_mode(int) for the embedder (browser wires it to the
    # color_scheme dconf setting / Sailfish ambience) and gives ViewLegacy the
    # ViewPlatform SystemSettings observer so live pages re-evaluate their
    # color scheme without a reload.
    "patches/webkit/webkit-wpe-dark-mode-runtime.patch"
    "patches/webkit/webkit-bubblewrap-sfos-sandbox.patch"
    # webkit-sticky-scroll-composite-sync-env.patch: WEBKIT_COMPOSITE_SCROLL_SYNC
    # (default on) — before flushing layer state for a composite, re-apply the
    # scrolling tree's layer positions and hold the tree lock across the whole
    # flush, so a composite can't interleave with the scrolling thread's
    # scroll-then-compensate walk (or pick up stale main-thread commits) and
    # render a fresh scroll offset against stale position:fixed/sticky layer
    # positions. Fixes sticky navbars lagging/jittering during fast flicks.
    # Applies on top of the fully patched tree; keep it last in this list.
    "patches/webkit/webkit-sticky-scroll-composite-sync-env.patch"
    # webkit-composite-scroll-sync-stall-fix.patch: fixes the "renders once then
    # freezes" regression of the composite-scroll-sync patch — the compositor-
    # thread position re-apply must not set LayerTreeHost::m_compositionRequired
    # (stale signal = scrolling tree waits forever for a platform rendering
    # update), and the locked path only runs for RenderingUpdate/AsyncScrolling
    # composites. Must come AFTER the sticky-scroll-composite-sync patch.
    "patches/webkit/webkit-composite-scroll-sync-stall-fix.patch"
    # webkit-composite-scroll-sync-lock-only.patch: v3 — drop the compositor-
    # thread applyLayerPositions walk (stalled the rendering-update cycle,
    # builds 420/421) and restore upstream notifyCompositionRequired (the 421
    # suppression ate the legitimate compositor-thread "tiles changed" signal).
    # Keeps only the treeLock hold across the flush, which is the part that
    # makes scroll+sticky positions atomic per composed frame. Must come AFTER
    # the two patches above.
    "patches/webkit/webkit-composite-scroll-sync-lock-only.patch"

    # WPE has no TextChecker backend upstream (spellcheck is GTK-only); port
    # the GTK enchant-backed implementation so ENABLE_SPELLCHECK builds/works.
    "patches/webkit/webkit-wpe-spellcheck-enchant.patch"
    # Load-time responsiveness pair: during a heavy page load the WebProcess
    # main thread is saturated and queued touch events starve (page cannot
    # scroll until the load event fires). These two shrink the main-thread
    # task granularity during load so input gets service windows:
    #  - loading-timer-alignment: align maximally-nested DOM timers to a 50ms
    #    grid while the top document is loading (WEBKIT_LOADING_TIMER_ALIGNMENT_MS)
    #  - parser-time-limit: yield the HTML parser every 100ms instead of 500ms
    #    (WEBKIT_PARSER_TIME_LIMIT_MS)
    "patches/webkit/webkit-loading-timer-alignment-env.patch"
    "patches/webkit/webkit-parser-time-limit-env.patch"
    #  - touch-ack-timeout: UIProcess-side gesture recognition when the
    #    WebProcess doesn't ack touch events in time + stop dropping late-reply
    #    gesture events; makes scrolling work DURING page load
    #    (WEBKIT_TOUCH_ACK_TIMEOUT_MS)
    "patches/webkit/webkit-touch-ack-timeout-env.patch"
    # webkit-url-cache-disk-capacity-env.patch: WEBKIT_URL_CACHE_DISK_CAPACITY_MB
    # overrides the cache-model-derived HTTP disk cache capacity (NetworkProcess).
    # Lets the ship config keep ATLANTIC_CACHE_MODEL=viewer (smallest RAM caches,
    # no bfcache — the OOM lever) while restoring a BOUNDED on-flash HTTP cache:
    # DocumentViewer hardwires disk capacity to 0, so every repeat visit
    # re-downloaded every subresource over the radio (device-verified: 8 KB
    # ~/.cache after weeks of use). runtime-common.sh ships 100 MB; unset/0 =
    # stock capacity for the model. Needs the ~/.cache/wpe whitelist in the
    # generated sailjail profile (build-rpms-native.sh) or the cache writes
    # vanish inside the jail.
    "patches/webkit/webkit-url-cache-disk-capacity-env.patch"
    # webkit-sw-fallback-http-cache.patch: when a service worker's fetch handler
    # does not respondWith() (pass-through, e.g. theverge's ad-block SW), the
    # stock fallback restarts as a raw network load that neither reads nor
    # stores the HTTP disk cache — every subresource of every SW-controlled
    # page re-downloads on every visit. Route the pass-through case through the
    # normal cache-aware startRequest() path instead (device-proven: 0 → 30/38
    # disk-cache hits on theverge /_next/static). Complements the capacity
    # patch above — without this, SW-controlled sites never benefit from the
    # cache it enables. WEBKIT_SW_FALLBACK_HTTP_CACHE=0 = stock behaviour.
    "patches/webkit/webkit-sw-fallback-http-cache.patch"
    # webkit-no-full-repaint-on-layer-grow.patch: don't repaint a whole layer
    # just because it changed size — the coordinated tiled backing store keeps
    # existing tile content valid across resizes and only newly exposed tiles
    # need painting. During a heavy load the page content layer grows every
    # time an image/ad lands, and each growth full-repainted the page
    # (device-proven on franceinfo.fr: 572 whole-layer invalidations, ~595 Mpx
    # = 219 screenfuls CPU-rastered in ONE load). Covers both the generic
    # GraphicsLayer::setSize() path (shouldRepaintOnSizeChange override) and
    # the explicit scrolled-contents resize invalidation in
    # RenderLayerBacking::updateGeometry() (grow-only skip; shrink and
    # padding-box offset changes still repaint).
    # WEBKIT_REPAINT_ON_LAYER_RESIZE=1 = stock behaviour.
    "patches/webkit/webkit-no-full-repaint-on-layer-grow.patch"
    # webkit-no-full-repaint-on-composited-move.patch: the SCROLL-time analog of
    # the grow patch. A self-painting composited layer that merely MOVED (or
    # jittered <=1px in size) during a layout does not need its whole backing
    # re-rastered — the compositor repositions it and the tiled backing paints
    # newly exposed tiles on demand. franceinfo.fr runs a full doc layout on
    # ~every scroll frame; recursiveUpdateLayerPositions -> repaintAfterLayoutIfNeeded
    # then full-repaints each of ~14 composited section layers whose location
    # shifted (device-proven build 524: 11x onche.org's full-layer paint = the
    # felt ~10x scroll slowdown). Only skips move/jitter of layers that own their
    # backing store; forced/style repaints and ancestor-painting layers unaffected.
    # WEBKIT_REPAINT_ON_COMPOSITED_MOVE=1 = stock behaviour.
    "patches/webkit/webkit-no-full-repaint-on-composited-move.patch"
    # NOTE: the load-rendering-throttle patches are GONE (dropped after builds
    # 465-471). Coalescing main-thread rendering updates during load to cut the
    # paint storm (~340 Mpx/franceinfo load) fundamentally deadlocks the
    # compositor's composition<-tiles<-flush handshake: moving during a load
    # reveals content whose tiles are painted by updateRendering(), and deferring
    # that paint sticks m_isWaitingForRenderer true -> permanent freeze
    # (device-repro'd every attempt, incl. the observer+timer and the
    # compositor-gated variants). It also never moved DCL (raster is on Skia
    # worker threads). Not worth it. If load-time paint work is revisited, target
    # style-recalc/layout coalescing (off the compositor path) instead. See memory
    # franceinfo-load-slowness-analysis.md.
    # webkit-paint-log-diagnostic.patch: TEMPORARY env-gated paint/invalidation
    # logging (WEBKIT_PAINT_LOG=1, WebProcess stderr) for the load-time
    # paint-storm hunt — per-layer damage (GLC FULL/RECT), per-proxy dirty
    # rects (INVAL), tile-paint passes (PAINT) and full tile drops (DROP-ALL
    # with reason). Zero overhead when unset. Must apply AFTER the
    # no-full-repaint patch (contexts overlap). Remove once the storm is fixed.
    "patches/webkit/webkit-paint-log-diagnostic.patch"
    # webkit-style-smart-reconstruct.patch: PoC (WEBKIT_STYLE_SMART_RECONSTRUCT=1,
    # off by default). Downgrades ContentsOrInterpretation stylesheet updates that
    # were NOT caused by a real contents mutation or genuine environment change:
    # the updateStyleForLayout rdar-36670246 resolver-null hack goes through a new
    # weak variant that keeps the resolver/MatchResultCache alive, and weak-only
    # pending updates are re-analyzed like ActiveSet (unchanged sheet list -> no-op,
    # appended sheets -> Additive + scoped invalidation) instead of full resolver
    # Reconstruct + invalidateAllStyle whole-document restyle. Targets the ~179
    # main-doc full restyles per franceinfo load (44% of load main-thread time is
    # style resolution — see memory franceinfo-style-resolution-dominant.md).
    # Also carries the WEBKIT_STYLE_LOG=1 [stylelog] diagnostic for device A/B.
    "patches/webkit/webkit-style-smart-reconstruct.patch"
    # webkit-scrolltier-log-diagnostic.patch: TEMPORARY env-gated scroll-speed-ladder
    # tracing (WEBKIT_SCROLLTIER_LOG=1, WebProcess stderr) — the low-res-tiles-during-
    # scroll feature stopped engaging on device (build 480); logs dy-path eligibility,
    # arming decisions and the 0<dt<0.2 gate to find where the signal is lost. Must
    # apply AFTER webkit-lowres-tiles-during-scroll-env.patch. Remove once fixed.
    "patches/webkit/webkit-scrolltier-log-diagnostic.patch"
    # webkit-lowres-tiles-cpu-path.patch: enable low-res tiles on the CPU rendering
    # path (WEBKIT_SKIA_ENABLE_CPU_RENDERING=1 had silently disabled the whole
    # feature — the force-1.0 guards in paint/replay). CPU upload of a whole-tile
    # low-res buffer now goes 1:1 into the buffer-sized texture; composite upscales.
    # Must apply AFTER webkit-lowres-tiles-during-scroll-env.patch (and after the
    # scrolltier-log diagnostic, contexts overlap in SkiaPaintingEngine.cpp).
    "patches/webkit/webkit-lowres-tiles-cpu-path.patch"
    # webkit-force-async-scroll-env.patch: WEBKIT_FORCE_ASYNC_SCROLL — device-
    # root-caused (franceinfo, build 491): the page's non-composited fixed/sticky
    # elements set SynchronousScrollingReason::HasNonLayerViewportConstrainedObjects,
    # which forbids the scrolling thread from applying layer positions
    # (canUpdateLayersOnScrollingThread false) — ZERO async-scroll composites, every
    # visible scroll frame waits for a full ~1s main-thread rendering update = the
    # 1fps notch-by-notch scroll. gdb-proven: composites:updates 24:23 stock; 23:6
    # after neutralizing the 28 fixed/sticky elements via JS. The flag drops the
    # slow-repaint reasons (HasSlowRepaintObjects, HasNonLayerViewportConstrained-
    # Objects) at the single AsyncScrollingCoordinator::setSynchronousScrollingReasons
    # choke point; lossy: affected fixed/sticky elements lag at main-thread cadence
    # during scroll. Unset/0 = stock. Pairs with the fling throttle above.
    "patches/webkit/webkit-force-async-scroll-env.patch"
    # webkit-independent-scroll-env.patch: WEBKIT_INDEPENDENT_SCROLL — fully
    # separate scrolling from the main-thread rendering update (Gecko/APZ, i.e.
    # what the EmbedLite port does). Upstream is a *conditional* desync: on every
    # display refresh the scrolling thread blocks on m_stateCondition for up to
    # half a frame waiting for the main thread's rendering update, and only when
    # that times out may it write scroll offsets into the compositor scene itself
    # (SynchronizationState::Desynchronized). So every scroll frame pays a
    # main-thread latency tax and a merely-slow main thread drags the scroll with
    # it. The off-main-thread path already exists and is exercised (that timeout
    # fallback); this flag makes it the default: (1) the scrolling thread applies
    # layer positions + requests an AsyncScrolling composite on EVERY refresh, not
    # only when m_state != Idle; (2) willStartRenderingUpdate stops round-tripping
    # through the scrolling thread (no main-thread BinarySemaphore, no half-frame
    # m_stateCondition wait); (3) sync-scrolling reasons stop vetoing
    # canUpdateLayersOnScrollingThread — force-async-scroll above already accepts
    # that trade-off at the dispatch choke point. Nothing in the compositor needs
    # the main thread to recomposite a committed scene: requestComposition(
    # AsyncScrolling) reaches renderLayerTree with no main-thread hop, and
    # m_isWaitingForRenderer only gates RenderingUpdate-reason composites. Lossy,
    # same bargain as APZ: scroll-linked JS/`scroll` events fire at main-thread
    # cadence, and newly-exposed content is painted only once the main thread runs
    # (more low-res/checkerboard on slow pages instead of a freeze) — pairs with
    # the directional-coverage / lowres-tiles patches. Unset/0 = stock.
    "patches/webkit/webkit-independent-scroll-env.patch"
    # webkit-scrolling-thread-display-link-env.patch: the other half of
    # WEBKIT_INDEPENDENT_SCROLL, and the one that makes it actually do anything.
    # The scheduling half above lets the scrolling thread commit layer positions
    # without waiting for the main thread, but the scrolling thread's only
    # HEARTBEAT (displayDidRefresh -> displayDidRefreshOnScrollingThread ->
    # applyLayerPositions -> requestComposition(AsyncScrolling)) is still owned by
    # the main thread, so independence was impossible by construction: the only
    # display-link observer ever registered on WPE is the main thread's
    # WebDisplayRefreshMonitor (EventDispatcher::startDisplayDidRefreshCallbacks
    # exists but is called only by MomentumEventDispatcher, which is not ENABLE()d
    # for WPE), DisplayRefreshMonitor drops ticks while !isPreviousFrameDone() and
    # stops the mechanism after ONE unscheduled fire (m_maxUnscheduledFireCount=0),
    # and DisplayLink::notifyObserversDisplayDidRefresh skips any client whose
    # observer list is empty. So a stalled main thread (franceinfo,
    # m_isWaitingForRenderer stuck — device-measured 59/59 sched calls) kills the
    # display link and with it the scrolling thread's tick: scroll composites
    # (ftrace reqcomp r=8) at 7.3/s and scrollapply ~11/s instead of 60, 1.3s
    # gaps, compositor thread ~84% idle. The vblank source is fine (the timer
    # fallback alone is 60fps) — it is the observer bookkeeping that dies. This
    # patch gives EventDispatcher its own observer, held while the scrolling tree
    # reports hasRecentActivity() and released as soon as scrolling settles (an
    # idle page costs nothing). Touches EventDispatcher.{h,cpp}; relies on
    # <cstring>/<cstdlib> added by the force-async-scroll patch above, so it must
    # apply after it. Unset/0 = stock.
    "patches/webkit/webkit-scrolling-thread-display-link-env.patch"
    # webkit-scrolling-thread-tick-env.patch: the scrolling thread gets a tick of
    # its OWN. Everything that normally delivers displayDidRefresh -- the scrolling
    # thread's entire heartbeat -- is owned by someone else: the UIProcess decides
    # (from wheel hysteresis in WebPageProxy) whether the tick is even routed to
    # EventDispatcher, the display link's only observer is normally the main
    # thread's WebDisplayRefreshMonitor which stops it after one unscheduled fire,
    # and ScrollingTree::displayDidRefresh then drops it unless hasRecentActivity().
    # Device-measured on franceinfo with the two patches above in place and a
    # verified-clean single-instance foreground rig: the scrolling thread still
    # ticked only ~5/s (scrollapply thr=S 183 in 35.8s) and requested AsyncScrolling
    # composites ~3/s instead of 60, and a 10s freeze contained exactly ONE
    # scrollapply -- during a fling, when no input is needed at all. Forcing a
    # free-running 60Hz vblank (WEBKIT_FORCE_VBLANK_TIMER=1) made it worse (5.2/s,
    # and applies moved back to the main thread), which rules out the clock source.
    # So: while a scroll is live, run a plain repeating timer (default 16ms,
    # WEBKIT_INDEPENDENT_SCROLL_TICK_MS) on the scrolling thread's own run loop and
    # drive displayDidRefreshOnScrollingThread() from it -- no display link, no IPC
    # routing, no main thread. Armed from scrollingTreeNodeDidScroll when on the
    # scrolling thread, disarms itself once hasRecentActivity() goes false, so an
    # idle page costs nothing and a fling is self-sustaining (tick -> service
    # animation -> scroll -> re-arm). Sets the pace of scroll OFFSETS; the
    # compositor still throttles on frameComplete. Must apply after
    # webkit-independent-scroll-env.patch (same file). Unset/0 = stock.
    "patches/webkit/webkit-scrolling-thread-tick-env.patch"
    # webkit-tile-upload-budget-env.patch: WEBKIT_TILE_UPLOAD_BUDGET_MB — cap the
    # tile work one composite may do. Device-root-caused (build 495): after each
    # ~1s main-thread pass commits screenfuls of CPU-painted tiles, the next
    # composite (a) BLOCKS in waitUntilPaintingComplete for buffers Skia workers
    # are still painting and (b) uploads tens of MB via glTexSubImage in one go
    # (franceinfo layers up to 23460x1269) — compositor-thread samples showed the
    # stalls inside driver-blob code / idle-waiting, FPS 0.2-3 during scroll.
    # With a budget, still-painting buffers and out-of-budget updates stay queued
    # (never dropped) and renderLayerTree schedules follow-up composites to drain
    # them. Lossy: stale/blank tile content for a few frames. Unset/0 = stock.
    # Must apply AFTER the composite-scroll-sync patches (ThreadedCompositor.cpp
    # contexts overlap).
    "patches/webkit/webkit-tile-upload-budget-env.patch"
    # webkit-tile-upload-scroll-gate.patch: make the upload budget behave like
    # other browsers visually. (1) WEBKIT_TILE_UPLOAD_BUDGET_SCROLL_ONLY
    # (default 1): the budget only meters composites while the scrolling tree
    # reports motion (atomic stamp from scrollingTreeNodeDidScroll + settle
    # window WEBKIT_TILE_UPLOAD_SCROLL_SETTLE_MS, default 250); once settled,
    # the next composite drains the whole queue at once (stock path), so newly
    # exposed content completes atomically instead of popping in square by
    # square. (2) While metering, CoordinatedBackingStore drains tiles ordered
    # along the scroll direction (leading edge first) and stops at budget
    # exhaustion, so fill-in reads as a progressive wave, not random squares.
    # No-op when the budget is 0. Must apply AFTER tile-upload-budget-env and
    # (contexts overlap in CoordinatedBackingStoreTile.* and
    # ScrollingTree.*).
    "patches/webkit/webkit-tile-upload-scroll-gate.patch"
    # webkit-tile-upload-nonblocking-settle.patch: the scroll gate's settled
    # composite fell back to the STOCK drain — unbounded glTexSubImage batch
    # plus blocking in waitUntilPaintingComplete for buffers Skia workers are
    # still painting. Every settle flip (gap between gestures > SETTLE_MS)
    # stalled composition for the whole queued batch — the residual franceinfo
    # scroll freeze. Device A/B (fresh-load continuous scroll, build 509):
    # non-blocking alone did NOT help (mean FPS 2.0 — the byte volume, not the
    # blocking wait, dominates); metering every frame gave mean 7.4. Fix:
    # settled composites are metered too, at a larger rest budget
    # (WEBKIT_TILE_UPLOAD_REST_BUDGET_MB, ships 16, 0 = unlimited) so
    # post-scroll fill-in completes in 1-2 big directional waves (anti-popping
    # kept) and never blocks on still-painting buffers (they defer to the
    # TileDrain follow-up composite). Must apply AFTER tile-upload-scroll-gate
    # (same function).
    "patches/webkit/webkit-tile-upload-nonblocking-settle.patch"

    # Touch devices: kill the fake mouse-move WebKit dispatches after every
    # scroll at the stale synthetic-tap position, which :hover-highlights
    # whatever link scrolls under the invisible cursor
    # (WEBKIT_NO_FAKE_MOUSE_MOVE, default 1 in runtime-common.sh).
    "patches/webkit/webkit-no-fake-mouse-move-env.patch"

    # Damage-limited compositing: enable WebKit's compiled-in-but-WPE-disabled
    # damage subsystem so a composite is scissored to the region that actually
    # changed instead of redrawing the whole scene (WEBKIT_DAMAGE_COMPOSITING,
    # default OFF in runtime-common.sh). Only touches LayerTreeHost.cpp; must
    # apply AFTER every other patch that touches that file (raster-on-compositor,
    # the composite-scroll-sync trio) so its context matches the
    # fully-patched tree.
    "patches/webkit/webkit-damage-limited-composite-env.patch"

    # Skip the redundant main-thread memset of CPU tile buffers: the Skia worker
    # clears+paints every tile before it is composited, so tryZeroedMalloc on the
    # main thread is wasted work - device-measured as the #1 main-thread hot spot
    # during franceinfo scroll (~30% of samples). WEBKIT_TILE_BUFFER_SKIP_ZERO=1,
    # default OFF. Touches CoordinatedTileBuffer.cpp; apply AFTER tile-upload-budget
    # (the other patch touching that file).
    "patches/webkit/webkit-tile-buffer-skip-zero-env.patch"

    # Frame-trace diagnostic (ATLANTIC_FRAME_TRACE=1, default OFF): CLOCK_MONOTONIC
    # marker at each WebProcess composite, paired with the qt5-plugin ui recv/paint/
    # ack markers to localize the franceinfo freeze-then-jump (production vs handoff
    # vs present). Touches ThreadedCompositor.cpp; apply after the other patches
    # touching it.
    "patches/webkit/webkit-frame-trace-env.patch"

    # THE franceinfo scroll-freeze fix: WEBKIT_SKIP_ROOT_CUSTOMPROP_REPAINT=1 (default ON)
    # stops RenderBox::styleWillChange from repainting the whole page when a :root/<body>
    # custom-property changes (the site updates --offset-sticky-* on <html> every scroll
    # frame -> full-page repaint -> ~2280-tile batch -> compositor stall -> freeze). Device-
    # verified 34s->3.3s worst freeze. Root-caused via the frame-trace tooling above.
    # (A broader "repaint only if background changed" variant was tried and reverted: it did
    # NOT fix the separate settle "blinking" - that's progressive image loads + flex reflow,
    # not the root repaint - and it risked increasing per-settle tile cost.)
    "patches/webkit/webkit-root-customprop-repaint-skip-env.patch"

    # webkit-drop-tiles-when-hidden-env.patch: WEBKIT_DROP_TILES_WHEN_HIDDEN=1
    # (default OFF, A/B) makes a backgrounded tab drop its tiled-backing tiles.
    # Device-measured: a hidden tab pins ~1 GB of GPU tile textures forever (the
    # cover rect in CoordinatedBackingStoreProxy is computed from the visible
    # rect only and never considers page visibility; on hide WebKit merely
    # suspendPainting()s). With one WebKitWebView per WebProcess we track a
    # process-global "page hidden" flag: when set, every backing store computes
    # an EMPTY cover rect so all tiles drop and none are created; on show they
    # rebuild (resumePainting already issues setNeedsDisplay). DrawingArea forces
    # one updateRenderingWithForcedRepaint() on hide (empty cover -> paints
    # nothing, just drops tiles + frees GPU) before pausing. Default off until
    # device-validated (freeing GPU requires that forced composite to land while
    # hidden -- the deadlock-prone compositor-timing area, so A/B first).
    "patches/webkit/webkit-drop-tiles-when-hidden-env.patch"
)

readonly QT5_PLUGIN_PATCHES=(
    # Empty on purpose: all historical qt5-plugin patches are baked into the
    # self-contained qt5-plugin/ source directory (the patch files have been
    # removed — see git history for the individual changes).
)

apply_single_repo_patch() {
    local strip_level="$1"
    local target_dir="$2"
    local patch_file="$3"
    local patch_path="${BUILD_TOOLS}/${patch_file}"

    if [ ! -f "${patch_path}" ]; then
        echo "ERROR: missing patch ${patch_path}" >&2
        return 1
    fi

    echo "  Applying ${patch_file}"

    if (
        cd "${target_dir}" &&
        patch "-p${strip_level}" --batch --forward --dry-run < "${patch_path}" >/dev/null 2>&1
    ); then
        (
            cd "${target_dir}" &&
            patch "-p${strip_level}" --batch --forward < "${patch_path}"
        )
        return $?
    fi

    if (
        cd "${target_dir}" &&
        patch "-p${strip_level}" --batch --reverse --dry-run < "${patch_path}" >/dev/null 2>&1
    ); then
        echo "    ${patch_file} already present; skipping"
        return 0
    fi

    echo "ERROR: failed to apply ${patch_file} in ${target_dir}" >&2
    return 1
}

apply_repo_patches() {
    local strip_level="$1"
    local target_dir="$2"
    shift 2

    local patch_file
    for patch_file in "$@"; do
        apply_single_repo_patch "${strip_level}" "${target_dir}" "${patch_file}" || return 1
    done
}
