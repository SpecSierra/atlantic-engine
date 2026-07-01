#!/bin/sh

ATLANTIC_RUNTIME_PREFIX="${ATLANTIC_RUNTIME_PREFIX:-/opt/wpe-sfos}"
ATLANTIC_RUNTIME_LIBDIR="${ATLANTIC_RUNTIME_LIBDIR:-/usr/lib64}"
ATLANTIC_COMPAT_DIR="${ATLANTIC_COMPAT_DIR:-${ATLANTIC_RUNTIME_LIBDIR}/wpe-compat}"
ATLANTIC_WPE_HELPER_DIR="${ATLANTIC_WPE_HELPER_DIR:-/usr/libexec/wpe-webkit-2.0}"
ATLANTIC_QT_QPA_PLATFORM="${ATLANTIC_QT_QPA_PLATFORM:-wayland}"
ATLANTIC_XDG_RUNTIME_DIR="${ATLANTIC_XDG_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/run/user/100000}}"
ATLANTIC_WAYLAND_DISPLAY="${ATLANTIC_WAYLAND_DISPLAY:-../../display/wayland-0}"
ATLANTIC_GSTREAMER_PLUGIN_DIR="${ATLANTIC_GSTREAMER_PLUGIN_DIR:-${ATLANTIC_RUNTIME_LIBDIR}/gstreamer-1.0}"
# Hardware video decode (Qualcomm Venus via droidmedia / gst-droid's droidvdec).
# ENABLED BY DEFAULT on SFOS 5.1. Validated on 5.1.0.7 (Xperia 10 II): H.264/H.265
# are hardware-decoded with 0 dropped frames and ~half the WebProcess CPU of the
# software avdec path (~27% -> ~15% of a big core on 1080p), with mediaswcodec
# idle (confirming true HW, not the Android software codec). The SFOS 5.0
# hybris-EGL -> GStreamer crash that originally motivated droidvdec:0 does NOT
# recur on 5.1's working hybris stack.
#
# CAUTION: droidvdec does NOT only advertise avc/hevc/mp4v. Despite
# /etc/gst-droid/gstdroidcodec.conf listing only video/hevc + video/avc,
# droidvdec enumerates codecs from droidmedia/the Android media_codecs list at
# runtime and on the Xperia 10 II (SFOS 5.1.0.8) it ALSO claims VP8/VP9. With
# droidvdec ranked above the software vpx decoders it therefore grabs YouTube's
# VP9 stream and crashes the WebProcess (thread droidvdec0:src; "libI420color-
# convert.so not found" — its colour-convert path is broken), showing a
# scrambled texture instead of video. So we must keep HW decode for H.264/H.265
# (where it's a real win, see above) while forcing VP8/VP9 to software: rank
# vp9dec/vp8dec ABOVE droidvdec so decodebin prefers them for vp8/vp9 caps,
# leaving droidvdec to win only for avc/hevc caps it actually handles. Verified
# on device: YouTube (VP9) decodes via software vp9dec, plays smoothly, no crash.
# droidvenc (encode) stays disabled: unused by the browser and historically less
# stable.
#
# Set ATLANTIC_DISABLE_HW_DECODER=1 to force the all-software decode path.
if [ "${ATLANTIC_DISABLE_HW_DECODER:-0}" = "1" ]; then
    ATLANTIC_GST_PLUGIN_FEATURE_RANK="${ATLANTIC_GST_PLUGIN_FEATURE_RANK:-droidvdec:0,droidvenc:0}"
else
    ATLANTIC_GST_PLUGIN_FEATURE_RANK="${ATLANTIC_GST_PLUGIN_FEATURE_RANK:-droidvdec:300,droidvenc:0,vp9dec:310,vp8dec:310}"
fi
ATLANTIC_WEBKIT_HLS_SUPPORT="${ATLANTIC_WEBKIT_HLS_SUPPORT:-1}"
ATLANTIC_BROWSER_RUNTIME_DELAY_MS="${ATLANTIC_BROWSER_RUNTIME_DELAY_MS:-2000}"

atlantic_default_pulse_server() {
    for pulse_socket in \
        "${ATLANTIC_XDG_RUNTIME_DIR}/pulse/native" \
        "/run/pulse/native"
    do
        if [ -S "${pulse_socket}" ]; then
            printf 'unix:%s' "${pulse_socket}"
            return
        fi
    done
}

atlantic_build_ld_preload() {
    preload=""
    sep=""

    if [ "${USE_GLIBC_COMPAT:-0}" = "1" ]; then
        preload="${preload}${sep}${ATLANTIC_COMPAT_DIR}/libglibc-compat.so"
        sep=":"
    fi
    if [ "${USE_SIGILL_SKIP:-0}" = "1" ]; then
        preload="${preload}${sep}${ATLANTIC_COMPAT_DIR}/libsigill_skip.so"
        sep=":"
    fi
    if [ "${USE_GLIB_COMPAT:-0}" = "1" ]; then
        preload="${preload}${sep}${ATLANTIC_COMPAT_DIR}/libglib-compat.so"
        sep=":"
    fi
    if [ "${USE_EGL_STUBS:-0}" = "1" ]; then
        preload="${preload}${sep}${ATLANTIC_COMPAT_DIR}/libegl-stubs.so"
    fi

    printf '%s' "${preload}"
}

atlantic_default_library_path() {
    printf '%s:%s' "${ATLANTIC_COMPAT_DIR}" "${ATLANTIC_RUNTIME_LIBDIR}"
}

atlantic_default_helper_library_path() {
    printf '%s:%s' "$(atlantic_default_library_path)" "${ATLANTIC_RUNTIME_PREFIX}/lib"
}

atlantic_export_helper_env() {
    # Apply the ATLANTIC_PROFILE preset (if any) FIRST, so its values feed the
    # ${VAR:-default} exports below and reach BOTH the browser and the WebProcess
    # — the WebProcess helper wrappers also call this function, and GStreamer (the
    # media buffers) lives in the WebProcess.
    atlantic_apply_profile

    if [ -n "${ATLANTIC_LD_PRELOAD:-}" ]; then
        export LD_PRELOAD="${ATLANTIC_LD_PRELOAD}"
    else
        unset LD_PRELOAD 2>/dev/null || true
    fi

    export LD_LIBRARY_PATH="${ATLANTIC_LD_LIBRARY_PATH:-$(atlantic_default_helper_library_path)}"
    export XDG_RUNTIME_DIR="${ATLANTIC_XDG_RUNTIME_DIR}"
    export WAYLAND_DISPLAY="${ATLANTIC_WAYLAND_DISPLAY}"
    if [ -z "${PULSE_SERVER:-}" ]; then
        pulse_server="$(atlantic_default_pulse_server)"
        if [ -n "${pulse_server}" ]; then
            export PULSE_SERVER="${pulse_server}"
        fi
    fi
    export GST_PLUGIN_SYSTEM_PATH_1_0="${ATLANTIC_GSTREAMER_PLUGIN_DIR}"
    export GST_PLUGIN_PATH="${ATLANTIC_GSTREAMER_PLUGIN_DIR}"
    export GST_PLUGIN_FEATURE_RANK="${ATLANTIC_GST_PLUGIN_FEATURE_RANK}"
    # GStreamer pipeline tuning. The three WEBKIT_GST_* knobs below are consumed
    # by patches/webkit/webkit-gst-buffer-tuning.patch (MediaPlayerPrivate-
    # GStreamer::configureElement) — they are NOT upstream env vars, so they do
    # nothing unless that patch is in scripts/patches.sh.
    #   queue2 high-watermark 0.05 (upstream hardcodes 0.10): start playback at
    #     a 5% fill instead of 10% — faster stream start, fewer "buffering"
    #     pauses on fast links.
    #   ring-buffer 16 MB / uridecodebin multiqueue 8 MB (upstream 2 MB each):
    #     deeper read-ahead for progressive/blob playback.
    export WEBKIT_GST_QUEUE_HIGH_WATERMARK="${WEBKIT_GST_QUEUE_HIGH_WATERMARK:-0.05}"
    export WEBKIT_GST_RING_BUFFER_MAX_SIZE="${WEBKIT_GST_RING_BUFFER_MAX_SIZE:-16777216}"
    export WEBKIT_GST_URIDECODEBIN_BUFFER_SIZE="${WEBKIT_GST_URIDECODEBIN_BUFFER_SIZE:-8388608}"
    # Upstream env var (GstDownloadBuffer max-size-bytes, default 100 KB).
    export WPE_SHELL_MEDIA_DISK_CACHE_SIZE_BYTES="${WPE_SHELL_MEDIA_DISK_CACHE_SIZE_BYTES:-67108864}"
    # Decode-resolution ceiling (format WIDTHxHEIGHT@FRAMERATE, consumed by
    # WebCore GStreamerRegistryScanner). The browser advertises support only up
    # to this, so adaptive sites (YouTube etc.) pick a stream within it. Capped
    # at 1080p60 to keep Venus HW decode (H.264/H.265) in range while preventing
    # the device from ever attempting 4K *software* VP9, which would exhaust the
    # 3.5 GB RAM and OOM-kill the WebProcess. Override with a larger value on the
    # future Mali device, or unset to remove the ceiling.
    export WEBKIT_GST_VIDEO_DECODING_LIMIT="${WEBKIT_GST_VIDEO_DECODING_LIMIT:-1920x1080@60}"
    # Make the SFOS system media volume (the hardware volume keys / MainVolume2 /
    # module-meego-mainvolume) control browser audio natively. That policy only
    # steps PulseAudio streams whose media.role is "x-maemo"; WebKit hardcodes
    # "video"/"music", which it ignores. WEBKIT_GST_MEDIA_ROLE (engine patch
    # webkit-gst-media-role-env.patch) overrides the role WebKit stamps on every
    # audio sink so all browser audio joins the media-volume group.
    #
    # Note: PULSE_PROP[_OVERRIDE] CANNOT do this — it only sets the client/context
    # proplist, and WebKit's explicit per-stream media.role wins (device-verified).
    # The old PULSE_PROP_OVERRIDE=media.role=x-maemo here was a no-op; removed.
    export WEBKIT_GST_MEDIA_ROLE="${WEBKIT_GST_MEDIA_ROLE:-x-maemo}"
    # Fix "YouTube sound stops after ~0.25 s". The libhybris PulseAudio sink's
    # provided clock (GstPulseSinkClock) intermittently freezes when its stream is
    # (re)corked across a mute/unmute or an MSE audio re-init; because the audio
    # sink is the pipeline clock provider, the slaved pipeline deadlocks (audio
    # plays only the buffered ~250 ms then cuts out, picture freezes, element still
    # reports playing+unmuted). WEBKIT_GST_AUDIO_SYSTEM_CLOCK (engine patch
    # webkit-gst-audio-system-clock.patch) forces provide-clock=FALSE on the
    # pulsesink so the pipeline uses the monotonic system clock instead; pulsesink
    # resamples (slave-method=skew) to track the audio HW clock. Unset = upstream.
    export WEBKIT_GST_AUDIO_SYSTEM_CLOCK="${WEBKIT_GST_AUDIO_SYSTEM_CLOCK:-1}"
}

# ── Tuning profiles ──────────────────────────────────────────────────────────
# ATLANTIC_PROFILE bundles the memory/footprint knobs into a single switch for
# on-device A/B. Unset (default) = ship baseline, nothing changed. A profile only
# sets a knob when it is not already set, so an explicit per-variable override
# (e.g. ATLANTIC_CACHE_MODEL=document) still wins over the profile. The cache
# model is the WebProcess steady-state footprint lever: on this 3.5 GB device the
# live object cache barely shrinks between models (~96-128 MB), so the real win is
# what `viewer` drops — the back/forward page cache (2 full prior pages resident)
# plus the 64 MB dead-resource cache and the 60 s decoded-image hold.
#
#   lean      ATLANTIC_CACHE_MODEL=viewer   (no bfcache, drop dead/decoded caches)
#   moderate  ATLANTIC_CACHE_MODEL=document (keep bfcache, trim dead cache)
#   min       lean + purge earlier (base 900 MB, 2 s poll) — the never-OOM arm
#   media     trim GStreamer read-ahead buffers (less discretionary video memory)
#   baseline  ATLANTIC_CACHE_MODEL=web      (explicit ship default, for clean A/B)
#
# Profiles isolate one lever at a time; to combine, set ATLANTIC_PROFILE plus the
# individual vars (explicit values always win). Cache-model profiles need the
# browser build that reads ATLANTIC_CACHE_MODEL (WPEWebContainer); the
# WEBKIT_MEMORY_* / WEBKIT_GST_* knobs already apply on older builds.
atlantic_apply_profile() {
    profile="${ATLANTIC_PROFILE:-}"
    [ -z "${profile}" ] && return 0

    case "${profile}" in
        lean)
            : "${ATLANTIC_CACHE_MODEL:=viewer}"
            ;;
        moderate)
            : "${ATLANTIC_CACHE_MODEL:=document}"
            ;;
        min)
            : "${ATLANTIC_CACHE_MODEL:=viewer}"
            : "${WEBKIT_MEMORY_BASE_THRESHOLD_MB:=900}"
            : "${WEBKIT_MEMORY_POLL_INTERVAL_MS:=2000}"
            ;;
        media)
            # Trim discretionary GStreamer read-ahead. The deep defaults (16/8 MB
            # vs upstream 2 MB) were tuned for fewer rebuffer pauses; on a 3.5 GB
            # device they are resident memory that competes with the feed.
            # NOTE: this bounds the GStreamer / progressive + native-HLS path only.
            # JS-driven MSE buffering (hls.js prebuffering a paused feed video, the
            # 53 s case) is a separate browser-side fix, not reachable from env.
            : "${WEBKIT_GST_RING_BUFFER_MAX_SIZE:=4194304}"        # 16 MB -> 4 MB
            : "${WEBKIT_GST_URIDECODEBIN_BUFFER_SIZE:=2097152}"    # 8 MB  -> 2 MB
            : "${WPE_SHELL_MEDIA_DISK_CACHE_SIZE_BYTES:=16777216}" # 64 MB -> 16 MB
            ;;
        baseline|web|default)
            : "${ATLANTIC_CACHE_MODEL:=web}"
            ;;
        *)
            echo "atlantic: unknown ATLANTIC_PROFILE='${profile}' (use lean|moderate|min|media|baseline)" >&2
            return 0
            ;;
    esac

    # Export whatever the profile set so it survives into the browser AND the
    # WebProcess helper wrappers (both run atlantic_export_helper_env). Anything
    # left unset stays unset and falls through to the ${VAR:-default} exports.
    for v in ATLANTIC_CACHE_MODEL \
             WEBKIT_MEMORY_BASE_THRESHOLD_MB WEBKIT_MEMORY_POLL_INTERVAL_MS \
             WEBKIT_GST_RING_BUFFER_MAX_SIZE WEBKIT_GST_URIDECODEBIN_BUFFER_SIZE \
             WPE_SHELL_MEDIA_DISK_CACHE_SIZE_BYTES; do
        eval "[ -n \"\${${v}:-}\" ]" && export "${v}"
    done
    echo "atlantic: profile=${profile}" \
         "cache=${ATLANTIC_CACHE_MODEL:-default}" \
         "mem_base=${WEBKIT_MEMORY_BASE_THRESHOLD_MB:-default}" \
         "gst_ring=${WEBKIT_GST_RING_BUFFER_MAX_SIZE:-default}" >&2
}

atlantic_export_browser_env() {
    atlantic_export_helper_env   # also applies ATLANTIC_PROFILE (see above)

    # ── WPE bubblewrap process sandbox ──────────────────────────────────────
    # The bwrap sandbox is FUNDAMENTALLY INCOMPATIBLE with the libhybris
    # Adreno GPU stack on Sailfish OS: the user namespace strips supplementary
    # groups (graphics, video, audio) required by the Android GPU HAL, and the
    # mount namespace hides submounts (/odm, /vendor/firmware_mnt) on kernel
    # 4.14.  Application-layer confinement is provided by Sailjail/firejail
    # instead: the shipped .desktop/.service launch the browser ELF via
    # `sailjail -p atlantic-browser.desktop`, which confines the whole browser
    # (UI + WPEWebProcess + WPENetworkProcess). See the per-app profile generated
    # by build-rpms-native.sh (/etc/sailjail/permissions/atlantic-browser.profile).
    #
    # The bwrap sandbox remains compiled in (ENABLE_BUBBLEWRAP_SANDBOX=ON) so
    # that the browser can call webkit_web_context_add_path_to_sandbox()
    # without linker errors, but the sandbox is always disabled at runtime via
    # WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1.
    #
    # ATLANTIC_ENABLE_SANDBOX=1 can still be set to re-enable bwrap for
    # debugging, but it WILL produce blank pages on hybris devices.
    if [ "${ATLANTIC_ENABLE_SANDBOX:-0}" = "1" ]; then
        export WEBKIT_FORCE_SANDBOX=1
        unset WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS 2>/dev/null || true
        chmod 755 /dev/__properties__/ 2>/dev/null || true
    else
        unset WEBKIT_FORCE_SANDBOX 2>/dev/null || true
        export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
    fi

    export QT_QPA_PLATFORM="${ATLANTIC_QT_QPA_PLATFORM}"
    export QSG_RENDER_LOOP="${QSG_RENDER_LOOP:-threaded}"
    export ATLANTIC_BROWSER_RUNTIME_DELAY_MS="${ATLANTIC_BROWSER_RUNTIME_DELAY_MS}"
    export WEBKIT_GST_ENABLE_HLS_SUPPORT="${ATLANTIC_WEBKIT_HLS_SUPPORT}"

    # GStreamer buffer tuning is exported once in atlantic_export_helper_env
    # (called above) — GStreamer runs in WPEWebProcess, which gets the helper
    # env; the browser process only needs it for pages WebKit runs in-process.

    # ── GStreamer debug (uncomment to diagnose buffering issues) ──────────────
    # export GST_DEBUG="${GST_DEBUG:-webkit*:4,GstQueue2:3}"

    # ── DFG JIT re-enabled (2026-06-06) ───────────────────────────────────────
    # The DFG miscompile (webpack __webpack_require__ returning the wrong value,
    # jolla.com stuck behind its loading overlay) was previously worked around
    # with JSC_useDFGJIT=0.  Bisection step 1: dropped -Wl,--icf=safe from
    # sfos-toolchain-clang.cmake (ICF was folding distinct JSC intrinsic/host
    # functions to one address, corrupting pointer-identity dispatch).  Default
    # flipped back to 1 so this build runs the full DFG+FTL pipeline; verify
    # jolla.com loads before treating the bug as fixed.  If it regresses, set
    # JSC_useDFGJIT=0 in the environment (the workaround still honours an
    # explicit override) and escalate to -import-instr-limit / LTO_MODE=none.
    export JSC_useDFGJIT="${JSC_useDFGJIT:-1}"

    # ── JSC JIT thread tuning (Snapdragon 665: 8-core big.LITTLE) ────────────
    # Default JSC spawns 7 FTL threads + 8 GC markers on an 8-core device,
    # flooding the CPU during page load.  Cap to sane mobile limits.
    # Each is env-tunable (set the var before launch to A/B on device); the
    # values below are the mobile defaults applied when nothing is preset.
    export JSC_numberOfFTLCompilerThreads="${JSC_numberOfFTLCompilerThreads:-2}"
    export JSC_numberOfDFGCompilerThreads="${JSC_numberOfDFGCompilerThreads:-2}"
    export JSC_numberOfBaselineCompilerThreads="${JSC_numberOfBaselineCompilerThreads:-2}"
    export JSC_numberOfGCMarkers="${JSC_numberOfGCMarkers:-2}"
    export JSC_maxNumberOfWorklistThreads="${JSC_maxNumberOfWorklistThreads:-4}"
    export JSC_worklistLoadFactor="${JSC_worklistLoadFactor:-20}"
    export JSC_worklistFTLLoadWeight="${JSC_worklistFTLLoadWeight:-20}"
    export JSC_worklistDFGLoadWeight="${JSC_worklistDFGLoadWeight:-5}"
    export JSC_worklistBaselineLoadWeight="${JSC_worklistBaselineLoadWeight:-2}"

    # ── JSC JIT tier-up thresholds / GC heap tuning ──────────────────────────
    # Deliberately NOT overridden — and actively cleared below, because stale
    # values can still arrive via the systemd user session env (the old
    # /var/lib/environment/nemo/70-browser.conf injected them).
    #
    # Tier-up: the previous thresholdForJITAfterWarmUp=50 /
    # thresholdForOptimizeAfterWarmUp=200 (vs upstream 500/1000) made tier-up
    # 10x/5x more eager, flooding the 2-thread compiler worklist with
    # baseline/DFG compiles of barely-warm functions during page load —
    # exactly the heavy-page phase that was slow — and increasing DFG
    # recompiles from early type instability. Late-tier latency is already
    # addressed by webkit-jsc-linux-arm64-jit-thresholds.patch (FTL threshold
    # 64000 → 15000).
    #
    # GC: the previous JSC_smallHeapRAMFraction=0.50 did the OPPOSITE of its
    # stated "cap the heap to avoid zram swap" intent: raising the fraction
    # (default 0.25) keeps heaps in the "small" class up to ~1.75 GB on this
    # device, where JSC applies smallHeapGrowthFactor=2.0 (vs 1.5/1.24 for
    # medium/large) — i.e. the heap was allowed to DOUBLE before collecting,
    # growing memory pressure and swap. Upstream defaults collect earlier.
    # (useTypeProfiler/useControlFlowProfiler are already false by default.)
    unset JSC_thresholdForJITAfterWarmUp JSC_thresholdForOptimizeAfterWarmUp \
          JSC_smallHeapRAMFraction JSC_largeHeapRAMFraction JSC_largeHeapSize \
          JSC_useTypeProfiler JSC_useControlFlowProfiler 2>/dev/null || true

    # ── WebKit memory-pressure budget ─────────────────────────────────────────
    # Honoured by webkit-memory-pressure-threshold-env.patch. WebKit's
    # MemoryPressureHandler purges decoded-image / page / TILE caches when RSS
    # crosses base*0.33 (conservative) / base*0.5 (strict); defaults
    # (base = min(3 GB, RAM), 30 s poll) never fire usefully on this device.
    #
    # TUNING HISTORY (device-measured, build 336, reddit r/oddlysatisfying):
    #   base=1200 (conservative ~400 / strict ~600 MB) was TOO AGGRESSIVE — single-
    #   feed scroll RSS sits at ~560-600 MB, so strict purge fired DURING normal
    #   scrolling and evicted the prepainted tiles; the re-paint on the gpu-sync
    #   Adreno is the "lag spike like a new tile" the user feels. rAF frame meter:
    #   base=1200 → 17.5% of frames >200 ms, p50 41 ms; base=2200 → 3.6% spikes,
    #   p50 17 ms (~58 fps), with RSS still safe (~563 MB, avail 657 MB).
    #   NOTE the earlier "lag = kernel memory thrash (~1700 major faults)" theory
    #   did NOT reproduce on 334-336 (faults ~0, RSS bounded) — the purge ITSELF
    #   was the dominant spike source, not thrashing.
    #
    # 700 MB → conservative purge ~230 / strict ~350 MB: AGGRESSIVE on purpose.
    # Device-measured (build 341): just sitting on a reddit feed grows ~1.5 GB of
    # mostly-OFF-RSS memory (decoded images → GPU textures + disk/URL cache) in 30 s
    # and HARD-OOMs the phone (lowmemorykiller reaps system procs). A high threshold
    # (2200) never purged before the system died, because WebKit's purge watches
    # RSS, not the graphics memory. Purging early releases the decoded images (and
    # their GPU textures) and bounds total memory — verified: avail held ~2.15 GB,
    # RSS ~220 MB, 0 LMK kills. The usual cost of aggressive purge (tile eviction →
    # scroll spikes) is hidden by the checkerboard below (we don't paint mid-fling),
    # so it is now affordable. Poll 3 s. Override per-launch via the env.
    export WEBKIT_MEMORY_BASE_THRESHOLD_MB="${WEBKIT_MEMORY_BASE_THRESHOLD_MB:-700}"
    export WEBKIT_MEMORY_POLL_INTERVAL_MS="${WEBKIT_MEMORY_POLL_INTERVAL_MS:-3000}"

    # ── Steady-state cache footprint ──────────────────────────────────────────
    # document_viewer: no back/forward page cache, no disk/URL cache, minimal
    # decoded-image retention. Part of the OOM fix above — the disk/URL cache and
    # bfcache are the bulk of the ~1.5 GB off-RSS growth that hard-OOMs the phone
    # on a reddit feed under the desktop-style web_browser model. Read by the
    # browser (WPEWebContainer); env-tunable (web / document / viewer).
    export ATLANTIC_CACHE_MODEL="${ATLANTIC_CACHE_MODEL:-viewer}"

    # ── Scroll tile policy: low-resolution tiles during scroll ────────────────
    # Honoured by webkit-lowres-tiles-during-scroll-env.patch +
    # webkit-directional-tile-coverage-env.patch (read by the WebProcess).
    # Policy: during a fast fling, rasterize newly-exposed tiles at reduced
    # resolution (WEBKIT_LOWRES_TILE_SCALE) and bilinear-upscale them, then repaint
    # full-res once motion settles — keeps content visible (soft) instead of blank,
    # while cutting the per-tile gpu-sync paint cost on the scroll hot path. Two-tier
    # ladder: full-res below WEBKIT_LOWRES_SCROLL_SPEED, 0.3 above it. The
    # checkerboard (top) rung is DISABLED here (=0); set it to e.g. 2500 to
    # re-enable a "very fast = blank band" tier above the low-res one. Prepaint
    # cover stays at 2 (normal) so low-res only bites when a fling outruns it.
    export WEBKIT_LOWRES_TILE_SCALE="${WEBKIT_LOWRES_TILE_SCALE:-0.3}"
    export WEBKIT_LOWRES_SCROLL_SPEED="${WEBKIT_LOWRES_SCROLL_SPEED:-400}"
    export WEBKIT_CHECKERBOARD_DURING_SCROLL="${WEBKIT_CHECKERBOARD_DURING_SCROLL:-0}"
    export WEBKIT_CHECKERBOARD_SETTLE_MS="${WEBKIT_CHECKERBOARD_SETTLE_MS:-100}"
    export WEBKIT_COVER_AREA_MULTIPLIER="${WEBKIT_COVER_AREA_MULTIPLIER:-2}"

    # ── Skia painting backend ────────────────────────────────────────────────
    # WEBKIT_SKIA_ENABLE_CPU_RENDERING and WEBKIT_SKIA_GPU_PAINTING_THREADS are
    # intentionally NOT set here. The browser auto-selects the painting backend
    # from a GPU capability probe in main.cpp (configureGpuModeFromCapabilities):
    # CPU painting on conservative stacks — e.g. the libhybris Adreno 610, where
    # GPU tile painting corrupts tiles at ANY thread count because the driver
    # does not honour cross-context EGL fence server-waits (black/stale/
    # misplaced tiles on image-heavy pages) — and multi-threaded GPU painting on
    # surfaceless-capable stacks (Mali, desktop). Export either variable before
    # launch to override the auto-selection (the probe honours explicit values).
    # The CPU painting thread count below applies whenever CPU painting is in
    # effect (2 raster workers; tiles upload from the compositor context).
    export WEBKIT_SKIA_CPU_PAINTING_THREADS="${WEBKIT_SKIA_CPU_PAINTING_THREADS:-2}"

    # ── Tile size alignment ───────────────────────────────────────────────────
    # 256 px tiles for Adreno 610 — smaller texture uploads reduce GPU pipeline
    # stalls vs 512 px, avoiding dropped frames during scroll on limited-bandwidth GPUs.
    # Env-tunable (e.g. 512 on the future Mali device) — default applied if unset.
    export WEBKIT_LAYERS_TILE_SIZE="${WEBKIT_LAYERS_TILE_SIZE:-256}"
}

atlantic_cleanup_runtime_artifacts() {
    rm -rf "${ATLANTIC_XDG_RUNTIME_DIR}/.flatpak"/webkit-* \
           "${ATLANTIC_XDG_RUNTIME_DIR}/wpe"/bus-proxy-* 2>/dev/null || true
}
