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
