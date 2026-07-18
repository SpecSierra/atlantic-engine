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
# droidadec (HW audio decode) is disabled entirely: it errors out mid-preroll
# ("stream stopped, reason not-linked", gstdroidadec.c data_available) on AAC
# audio tracks of ordinary mp4/YouTube streams, killing the whole pipeline —
# video keeps rendering but audio dies after the prebuffered fraction of a
# second. Audio-only (radio) streams were unaffected because they don't hit
# droidadec. Software audio decode (avdec_aac via libgstlibav) is cheap and
# device-verified working.
#
# Set ATLANTIC_DISABLE_HW_DECODER=1 to force the all-software decode path.
if [ "${ATLANTIC_DISABLE_HW_DECODER:-0}" = "1" ]; then
    ATLANTIC_GST_PLUGIN_FEATURE_RANK="${ATLANTIC_GST_PLUGIN_FEATURE_RANK:-droidvdec:0,droidvenc:0,droidadec:0}"
else
    ATLANTIC_GST_PLUGIN_FEATURE_RANK="${ATLANTIC_GST_PLUGIN_FEATURE_RANK:-droidvdec:300,droidvenc:0,vp9dec:310,vp8dec:310,droidadec:0}"
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
        sep=":"
    fi
    if [ "${USE_SYNC_FENCE_SKIP:-0}" = "1" ]; then
        # Always preloaded when built in, but inert until the user (or a
        # profile) sets ATLANTIC_SKIP_SWAP_FENCE=1 — see shims/compat/libsyncskip.c.
        preload="${preload}${sep}${ATLANTIC_COMPAT_DIR}/libsyncskip.so"
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
    # Force the plain-socket PulseAudio data path (enable-shm=no). The SHM/memfd
    # transport jams on this device right after a stream starts, so audio dies
    # after the ~0.5 s prebuffer while video keeps playing, and the unmute/uncork
    # commands sent later on the jammed connection are silently lost. See
    # deploy/pulse-client.conf for the full analysis. Device-verified fix.
    # (No file-existence guard: the Sailjail profile env block is generated from
    # this function on the build host, where the installed path doesn't exist.
    # The conf ships in the same rpm as this script, so it's always present at
    # runtime.)
    if [ -z "${PULSE_CLIENTCONFIG:-}" ]; then
        export PULSE_CLIENTCONFIG="${ATLANTIC_RUNTIME_PREFIX}/libexec/atlantic/pulse-client.conf"
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
    # GStreamer GL video sink (USE_GSTREAMER_GL, video-playback plan Phase 3):
    # compiled in but DISABLED by default. At small video sizes it works and
    # moves the upload+YUV conversion off the compositor thread, but at
    # 1920x1080 the shared-EGL-context uploads STALL THE DECODE PIPELINE on
    # hybris (device-measured Jul 17 2026: element playing/HAVE_ENOUGH_DATA
    # with 5 decoded frames total, ~1fps visible; same stream with the sink
    # disabled decodes 26.8fps with 0 drops). Suspected GstGL-thread vs
    # compositor-thread contention on the wrapped context. Set 0 to
    # re-enable for experiments; do not ship 0 until the 1080p stall is
    # solved (next step: droidmedia gralloc EGLImage zero-copy instead).
    export WEBKIT_GST_DISABLE_GL_SINK="${WEBKIT_GST_DISABLE_GL_SINK:-1}"
    # libsyncskip.so (wpe-compat preload): skip the libhybris eglSwapBuffers
    # sync_wait GPU-fence CPU wait on the WebKit ThreadedCompositor and Qt
    # QSGRenderThread. That wait serialized CPU and GPU per frame (~30-40ms of
    # every composite cycle during video). Device-verified with the GL sink +
    # pipelined ack: YouTube 1080p composites 74ms -> 37ms, visually clean.
    # Decoder/codec threads always keep their fences. Set 0 to restore the
    # blocking waits (kill switch; suspect first on any new GPU corruption or
    # GPU-related crash).
    export ATLANTIC_SKIP_SWAP_FENCE="${ATLANTIC_SKIP_SWAP_FENCE:-1}"
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
    # Lock the HTML media element volume to the system volume (engine patch
    # webkit-volume-locked-env.patch, upstream m_volumeLocked — the iPhone
    # model). Without it every new <video> (= new pulse stream) got the page's
    # el.volume (1.0, YouTube sets it per video) stamped on as an explicit
    # stream volume, resetting loudness to 100% on each video instead of
    # inheriting the mainvolume step the hardware keys had set. Locked: page JS
    # cannot change the stream volume (mute still works) and el.volume mirrors
    # the system volume. Set to 0 to restore upstream behaviour.
    export WEBKIT_VOLUME_LOCKED="${WEBKIT_VOLUME_LOCKED:-1}"
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

    # ── Texture pool cap (synchronous) ───────────────────────────────────────
    # Honoured by webkit-texpool-synchronous-cap.patch. The BitmapTexturePool
    # releases unused GL textures from a WebProcess MAIN-THREAD timer, which
    # starves exactly when texture churn peaks (video playback uploads one
    # ~9 MB BGRA frame texture per composited frame; page loads churn tile
    # textures), so dead textures pile up without bound — device-measured
    # 1.27 GB of released 1080p video-frame textures in a single WebProcess
    # (YouTube, ~2 min) driving the phone into zram swap and system OOM. The
    # patch enforces this cap synchronously in acquireTexture() on the
    # compositor thread, counting only free (refCount==1) entries so a large
    # in-use tile working set doesn't defeat reuse. 0 = stock behaviour (A/B).
    # WEBKIT_TEXPOOL_LOG=1 logs pool stats on each enforcement.
    export WEBKIT_TEXTURE_POOL_CAP_MB="${WEBKIT_TEXTURE_POOL_CAP_MB:-64}"

    # ── Steady-state cache footprint ──────────────────────────────────────────
    # document_viewer: no back/forward page cache, no disk/URL cache, minimal
    # decoded-image retention. Part of the OOM fix above — the disk/URL cache and
    # bfcache are the bulk of the ~1.5 GB off-RSS growth that hard-OOMs the phone
    # on a reddit feed under the desktop-style web_browser model. Read by the
    # browser (WPEWebContainer); env-tunable (web / document / viewer).
    export ATLANTIC_CACHE_MODEL="${ATLANTIC_CACHE_MODEL:-viewer}"

    # ── HTTP disk cache (bounded) ─────────────────────────────────────────────
    # Honoured by webkit-url-cache-disk-capacity-env.patch (read by the
    # NetworkProcess). The viewer cache model above zeroes WebKit's HTTP DISK
    # cache along with the RAM caches, so every repeat visit re-downloaded every
    # subresource over the radio (device-verified: ~/.cache/org.atlantic held
    # 8 KB after weeks of use) — a large share of perceived load slowness on
    # revisits. This restores a bounded on-flash cache (NetworkCache evicts to
    # stay under the cap) WITHOUT re-inflating any RAM cache; the OOM levers
    # (viewer model, memory-pressure budget below) are unchanged. 0/unset =
    # stock capacity for the cache model (viewer → no disk cache) for A/B.
    export WEBKIT_URL_CACHE_DISK_CAPACITY_MB="${WEBKIT_URL_CACHE_DISK_CAPACITY_MB:-100}"

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
    export WEBKIT_LOWRES_SCROLL_SPEED="${WEBKIT_LOWRES_SCROLL_SPEED:-120}"
    export WEBKIT_CHECKERBOARD_DURING_SCROLL="${WEBKIT_CHECKERBOARD_DURING_SCROLL:-800}"
    export WEBKIT_CHECKERBOARD_SETTLE_MS="${WEBKIT_CHECKERBOARD_SETTLE_MS:-200}"
    export WEBKIT_COVER_AREA_MULTIPLIER="${WEBKIT_COVER_AREA_MULTIPLIER:-2}"

    # Drop a backgrounded tab's tiled-backing tiles so a hidden tab holds ~0 GPU
    # tile memory instead of pinning its full cover (~1 GB measured). Rebuilt on
    # show. Honoured by webkit-drop-tiles-when-hidden-env.patch. DEFAULT OFF
    # (=0): freeing GPU while hidden needs a forced composite to land during the
    # hide transition (compositor-timing-sensitive), so validate via A/B on
    # device before flipping this on. Set to 1 to enable.
    export WEBKIT_DROP_TILES_WHEN_HIDDEN="${WEBKIT_DROP_TILES_WHEN_HIDDEN:-0}"

    # ── Fling throttle: starve page work during fast scroll ──────────────────
    # Honoured by webkit-fling-throttle-env.patch. On main-thread-bound pages
    # (franceinfo/radiofrance: scroll <1fps, style resolution dominates) scroll-
    # triggered JS/style/layout serialize behind every scroll frame. With this set,
    # a fast fling (> WEBKIT_FLING_THROTTLE_SPEED CSS px/s, held for
    # WEBKIT_FLING_THROTTLE_SETTLE_MS after the last fast motion) caps main-thread
    # rendering updates — scroll DOM events, rAF, IntersectionObserver, style,
    # layout, paint — to one per WEBKIT_FLING_THROTTLE_MS; the compositor keeps
    # scrolling already-painted tiles at full rate and the page catches up on
    # settle. Deliberately lossy: lazy-load/sticky-header JS lags during the fling.
    # 0/unset = fully disabled (stock scheduling) — the A/B switch. 200 = 5Hz.
    #
    # SHIPPED OFF since WEBKIT_INDEPENDENT_SCROLL: this whole mechanism exists only
    # because main-thread work used to sit ON the scroll path. It no longer does —
    # the scrolling thread has its own tick and commits scroll offsets and
    # AsyncScrolling composites without the main thread — so throttling the main
    # thread buys nothing and only costs page freshness during a fling. Device A/B
    # on franceinfo (build 540, single-instance foreground rig, identical automated
    # flicks): 400 -> composite 8.9/s, gap p95 156.9ms, worst 2913ms, scrollapply
    # thr=S 525; 0 -> composite 9.7/s, gap p95 129.5ms, worst 3501ms, thr=S 551.
    # Neutral-to-better without it.
    #
    # The patch itself is kept (not deleted) purely for patch-stack reasons:
    # webkit-tile-upload-scroll-gate.patch carries fling-throttle's added lines
    # (flingThrottleEnabled()/noteScrollForFlingThrottle, m_flingThrottleSampleTime,
    # m_flingThrottleActiveUntilSeconds) as unchanged CONTEXT, so dropping
    # fling-throttle from scripts/patches.sh makes scroll-gate fail to apply (CI
    # run 29512769122). Deleting it for real needs scroll-gate regenerated against
    # a fling-free tree. Setting it to 0 here is bit-for-bit the same at runtime.
    export WEBKIT_FLING_THROTTLE_MS="${WEBKIT_FLING_THROTTLE_MS:-0}"
    export WEBKIT_FLING_THROTTLE_SPEED="${WEBKIT_FLING_THROTTLE_SPEED:-400}"
    export WEBKIT_FLING_THROTTLE_SETTLE_MS="${WEBKIT_FLING_THROTTLE_SETTLE_MS:-300}"

    # Honoured by webkit-no-fake-mouse-move-env.patch. Pure-touch device: each
    # tap's synthetic click leaves a stale "last known mouse position", and
    # after every scroll WebKit dispatches a fake mouse-move there — so links
    # scrolling under the invisible cursor get :hover-highlighted. 1 = never
    # dispatch fake mouse-moves (real mouse events unaffected). 0 = stock.
    export WEBKIT_NO_FAKE_MOUSE_MOVE="${WEBKIT_NO_FAKE_MOUSE_MOVE:-1}"

    # Honoured by webkit-force-async-scroll-env.patch. Never fall back to
    # main-thread scrolling because of slow-repaint content (non-composited
    # fixed/sticky elements, background-attachment:fixed). Without it, such pages
    # scroll at the main-thread rendering-update rate — franceinfo/radiofrance
    # measured ~1fps notch-by-notch because their fixed/sticky elements are not
    # composited. Lossy: those elements lag/jitter during scroll instead of
    # pinning perfectly. 0/unset = stock (the A/B switch).
    export WEBKIT_FORCE_ASYNC_SCROLL="${WEBKIT_FORCE_ASYNC_SCROLL:-1}"

    # Honoured by webkit-independent-scroll-env.patch. Fully separate scrolling
    # from the main-thread rendering update (Gecko/APZ, like the EmbedLite port).
    # force-async-scroll above stops the main thread from *vetoing* async scroll;
    # this stops it from *pacing* it: upstream makes the scrolling thread wait up
    # to half a frame for the main thread's rendering update on every refresh and
    # only self-commits layer positions when that times out. With this on, the
    # scrolling thread commits offsets and requests an AsyncScrolling composite on
    # every refresh unconditionally, and the willStartRenderingUpdate handshake
    # (main-thread BinarySemaphore + scrolling-thread condition wait) is skipped —
    # so a slow main thread can no longer drag or freeze the scroll. Lossy, same
    # bargain as APZ: scroll-linked JS/`scroll` events fire at main-thread cadence,
    # and newly-exposed content is painted only when the main thread runs (more
    # low-res tiles on slow pages instead of a freeze).
    #
    # SHIPPED ON, device-verified user-validated (build 540, franceinfo). Three
    # patches act on this one flag:
    #   webkit-independent-scroll-env.patch          — scheduling: the scrolling
    #     thread stops waiting on the main thread's rendering update.
    #   webkit-scrolling-thread-display-link-env.patch — EventDispatcher keeps a
    #     display-link observer of its own for the duration of a scroll.
    #   webkit-scrolling-thread-tick-env.patch       — the one that mattered: a
    #     16ms timer on the SCROLLING THREAD's own run loop drives its tick, so it
    #     no longer has to be handed a clock by the main thread / UIProcess at all
    #     (WEBKIT_INDEPENDENT_SCROLL_TICK_MS overrides the interval).
    # Measured on franceinfo (single-instance foreground rig, automated flicks),
    # off -> on: scroll offsets applied on the scrolling thread 5.1/s -> 28.7/s
    # (thr=M 20 -> 9), AsyncScrolling composites requested 3/s -> 26/s, composites
    # 5.5/s -> 8.0/s, and composite gap p95 1438ms -> 111ms — a 13x improvement in
    # frame consistency, i.e. the page still repaints slowly but the scroll keeps
    # moving over the tiles that already exist instead of freezing.
    # 0 = stock (the A/B switch).
    export WEBKIT_INDEPENDENT_SCROLL="${WEBKIT_INDEPENDENT_SCROLL:-1}"

    # Honoured by webkit-root-customprop-repaint-skip-env.patch. SHIPPED ON: skip the
    # full-page view().repaintRootContents() in RenderBox::styleWillChange when a
    # <html>/<body> style change is a CSS custom property. franceinfo updates :root
    # --offset-sticky-* every scroll frame; without this the whole ~93000px page repaints
    # each frame -> ~2280-tile batch -> compositor lock-step -> multi-second scroll freeze.
    # Device-verified (ATLANTIC_FRAME_TRACE/ftrace.py): worst scroll freeze ~34s -> ~3.3s,
    # no regression. NOTE: the separate "icons blinking several times before settling" is
    # NOT this - it's progressive image loads (RenderImage::imageChanged per network chunk)
    # + flex-carousel reflow as image sizes resolve (largely page-authoring / layout-shift,
    # not an engine over-invalidation). 0 = stock full-page repaint (the A/B switch).
    export WEBKIT_SKIP_ROOT_CUSTOMPROP_REPAINT="${WEBKIT_SKIP_ROOT_CUSTOMPROP_REPAINT:-1}"

    # webkit-no-full-repaint-on-composited-move.patch is default-ON (baked into the
    # patch, no export needed): a self-painting composited layer that merely moved (or
    # jittered <=1px) during layout is NOT whole-backing repainted -- the compositor
    # repositions it and the tiled backing paints exposed tiles. Fixes franceinfo.fr's
    # per-scroll-frame full-layer repaint of ~14 section layers (11x onche.org's paint
    # volume = the felt ~10x scroll slowdown). A/B kill-switch: run the browser with
    # WEBKIT_REPAINT_ON_COMPOSITED_MOVE=1 to restore stock behaviour.

    # Honoured by webkit-damage-limited-composite-env.patch. Enables WebKit's
    # compiled-in but WPE-disabled damage subsystem so a composite is scissored
    # to the region that actually changed (glScissor to the buffer-age-correct
    # renderTargetDamage bounds + opaque-tile fragment draws) instead of
    # redrawing the whole scene every frame. INTENTIONALLY NOT EXPORTED = OFF by
    # default: an off-by-default engine flag here is not assumed safe (cf.
    # ATLANTIC_DIRECT_COMPOSITE), so this must be device-verified for correctness
    # (no stale pixels outside the scissor) before it is ever shipped on.
    #   WEBKIT_DAMAGE_COMPOSITING=1          turn the whole stack on
    #   WEBKIT_DAMAGE_UNIFY=0|1              bbox (1, default) vs per-rect frame damage
    #   WEBKIT_DAMAGE_USE_FOR_COMPOSITING=1  scissor the composite (default 1; set 0
    #                                        to propagate damage to the UI process only)
    # Note: during an active fling the scrolling layer's transform change
    # self-damages the whole layer, so the bbox scissor mainly helps non-scroll
    # and settled-frame repaints; tightening the scroll case is a follow-up.

    # Honoured by webkit-tile-buffer-skip-zero-env.patch. CPU tile buffers are
    # zero-allocated (tryZeroedMalloc = a full per-tile memset) on the MAIN thread
    # in the tile-record path, but every tile is cleared+painted by the Skia
    # worker before it is composited, so the zero is redundant. Device profiling
    # of franceinfo scroll found this memset is the #1 main-thread hot spot (~30%
    # of samples) and the freeze is main-thread-bound (main 92% CPU, compositor
    # 12%), so this directly attacks the freeze. =1 uses non-zeroed tryMalloc.
    # NOT EXPORTED = OFF by default: the OOM path (failed Skia surface) would show
    # one uninitialised tile, so device-verify for garbage flashes before shipping
    # on. (Damage-limited compositing does NOT help this freeze - it only touches
    # the idle compositor thread; this and the icon-heal scroll-gate do.)

    # Honoured by the qt5 plugin (WPEQtViewBackend). Acknowledge each exported
    # web frame immediately instead of after Qt's next scene-graph render, so
    # the WebProcess compositor is not lock-stepped to the QML render loop
    # (which collapses to ~1fps under main-thread load and freezes scrolling).
    # Qt samples the newest frame whenever it renders; intermediate frames are
    # dropped. 0/unset = stock handshake (the A/B switch).
    export ATLANTIC_EAGER_FRAME_COMPLETE="${ATLANTIC_EAGER_FRAME_COMPLETE:-0}"

    # Honoured by the qt5 plugin (WPEQtViewBackend). Bounded frame pipelining:
    # the stock handshake serializes composite -> export -> Qt render -> ack ->
    # next composite (every web frame costs two display frames = the ~28fps
    # ceiling on the 60Hz panel); EAGER above removes the serialization but
    # unbounded (frame flood crashed lipstick, builds 495-500). PIPELINED acks
    # with a single credit replenished per Qt-rendered frame: the WebProcess
    # composites frame N+1 while Qt renders frame N, but can never run more
    # than one frame ahead. 0 = stock lock-step (the A/B switch).
    # DEFAULT 0 (stock lock-step). The credit-starvation bug that made this
    # mode a no-op was fixed (WPEQtViewBackend didRenderFrame re-grants the
    # credit), and with it actually working the compositor free-runs
    # back-to-back with no idle — and STARVES THE VIDEO DECODE PIPELINE:
    # device A/B (build 547, progressive 1080p H.264, fresh codec service):
    # pipelined=1 -> 0 decoded frames reach the sink (OMX decodes, frames die
    # at the WebKit sink; media clock stalls); pipelined=0 -> normal playback.
    # The compositor monopolizes the layer lock / thread when never ack-
    # throttled. Do not re-enable until composites are vsync-paced instead of
    # free-running. The stock handshake also acts as the de-facto pacer.
    export ATLANTIC_PIPELINED_FRAME_ACK="${ATLANTIC_PIPELINED_FRAME_ACK:-0}"

    # Honoured by the qt5 plugin (WPEQtViewBackend::texture). Ack the web
    # frame when Qt SAMPLES it (EGLImage bind on the render thread, ack hopped
    # to the GUI thread) instead of after Qt's full render+swap — removes the
    # ~10-15ms Qt tail from the serialized composite->ack loop while keeping
    # strictly one ack per Qt render pass, so unlike the pipelined free-run it
    # cannot starve the video decode pipeline. DEFAULT 0: in the Jul 17
    # device session with it default-on, pages stopped loading fully
    # (unattributed but correlated); reverted to opt-in pending a clean A/B.
    export ATLANTIC_ACK_ON_SAMPLE="${ATLANTIC_ACK_ON_SAMPLE:-0}"

    # Honoured by webkit-tile-upload-budget-env.patch. Cap the tile work a single
    # composite may do: don't block on buffers the Skia workers are still
    # painting, and upload at most this many MB of CPU tile pixels per frame —
    # the rest stays queued and drains over follow-up composites (stale/blank
    # tiles show meanwhile). Kills the multi-hundred-ms composite stalls when a
    # heavy main-thread pass commits screenfuls of tiles at once.
    # 0 = stock unbounded. Ships 6 — device A/B swept 2/4/6/8/16 on franceinfo
    # (build 499, Jul 2026): 6 was the user-preferred balance between scroll
    # smoothness (smaller per-composite hitch) and content fill-in latency.
    export WEBKIT_TILE_UPLOAD_BUDGET_MB="${WEBKIT_TILE_UPLOAD_BUDGET_MB:-6}"

    # Honoured by webkit-tile-upload-scroll-gate.patch. Only meter tile uploads
    # while a scroll is actually in progress (plus the settle window, ms); at
    # rest the queued tiles drain in one composite, so freshly exposed content
    # completes atomically like other browsers instead of trickling in
    # square-by-square. While metering, tiles drain ordered along the scroll
    # direction (leading edge first). SCROLL_ONLY=0 = always-on budget (the
    # pre-build-506 behavior). Settle 800 user-tuned on device (build 507,
    # Jul 2026): 250 drained too eagerly between scroll gestures.
    export WEBKIT_TILE_UPLOAD_BUDGET_SCROLL_ONLY="${WEBKIT_TILE_UPLOAD_BUDGET_SCROLL_ONLY:-1}"
    export WEBKIT_TILE_UPLOAD_SCROLL_SETTLE_MS="${WEBKIT_TILE_UPLOAD_SCROLL_SETTLE_MS:-800}"

    # Honoured by webkit-tile-upload-nonblocking-settle.patch. Byte budget for
    # SETTLED (non-scrolling) composites. Unlimited settled drains were the
    # residual franceinfo scroll freeze (device A/B, build 509, Jul 2026):
    # every inter-gesture gap > SETTLE_MS flipped the next composite to an
    # unmetered drain pushing tens of MB through glTexSubImage in one frame —
    # mean scroll FPS 2.0 unlimited vs 7.4 metered. 16MB drains post-scroll
    # fill-in in 1-2 big directional waves (anti-popping kept) while bounding
    # any single composite. 0 = unlimited (the build-507/508 behavior).
    export WEBKIT_TILE_UPLOAD_REST_BUDGET_MB="${WEBKIT_TILE_UPLOAD_REST_BUDGET_MB:-16}"

    # ── Load-time responsiveness ─────────────────────────────────────────────
    # Honoured by webkit-loading-timer-alignment-env.patch and
    # webkit-parser-time-limit-env.patch. During a heavy page load the
    # WebProcess main thread is saturated (measured ~91% CPU, mostly site JS)
    # and queued touch events starve — the page can't scroll until the load
    # event fires. Align maximally-nested DOM timers to a coarse grid while
    # the top document is loading (batches setTimeout storms from
    # ads/analytics into bursts with input-sized gaps between them), and
    # yield the HTML parser every 100 ms instead of 500 ms. Both revert to
    # stock behavior once the load event fires; =0 disables (timer) /
    # restores stock (parser) for A/B.
    export WEBKIT_LOADING_TIMER_ALIGNMENT_MS="${WEBKIT_LOADING_TIMER_ALIGNMENT_MS:-50}"
    export WEBKIT_PARSER_TIME_LIMIT_MS="${WEBKIT_PARSER_TIME_LIMIT_MS:-100}"
    # (Load-time rendering-update throttle: DROPPED after builds 465-471. Coalescing
    # rendering updates during load to cut the ~340 Mpx/load paint storm always
    # deadlocked the compositor composition<-tiles<-flush handshake on
    # move-during-load — m_isWaitingForRenderer stuck true = permanent freeze
    # (device-repro'd on onche.org). It also never moved DCL. The env + observer
    # patches and WEBKIT_LOAD_RENDERING_INTERVAL_MS are removed. See memory
    # franceinfo-load-slowness-analysis.md.)
    # Touch-ack timeout (webkit-touch-ack-timeout-env.patch): if the WebProcess
    # doesn't ack touch events within this many ms, the UIProcess recognizes the
    # gesture itself and scrolls via the scrolling thread — flicks work during
    # page load instead of being silently dropped. =0 disables for A/B.
    export WEBKIT_TOUCH_ACK_TIMEOUT_MS="${WEBKIT_TOUCH_ACK_TIMEOUT_MS:-100}"

    # ── Smart stylesheet reconstructs (PoC, default OFF) ──────────────────────
    # Honoured by webkit-style-smart-reconstruct.patch. =1 downgrades spurious
    # ContentsOrInterpretation updates (updateStyleForLayout resolver-null hack)
    # from full resolver Reconstruct + whole-document restyle to an additive
    # resolver update + scoped invalidation (or a no-op). Default ON (user
    # accepted the risk for the perf upside); =0 to A/B against stock.
    # WEBKIT_STYLE_LOG=1 logs the decision mix ([stylelog]).
    export WEBKIT_STYLE_SMART_RECONSTRUCT="${WEBKIT_STYLE_SMART_RECONSTRUCT:-1}"

    # ── Overlay scrollbar size ────────────────────────────────────────────────
    # Honoured by webkit-adwaita-scrollbar-scale-env.patch. Atlantic's 3x UI
    # scale is implemented as page zoom (webkit_web_view_set_zoom_level), which
    # the native overlay scrollbar ignores — unscaled, the Adwaita thumb paints
    # 3 physical px wide on the 1080px screen. Scale the scrollbar metrics by
    # the same factor as the zoom level.
    export WEBKIT_SCROLLBAR_SCALE="${WEBKIT_SCROLLBAR_SCALE:-3}"
    # Honoured by webkit-scrollbar-sprite-and-smoothing.patch. Sprite mode
    # paints the thumb once (CPU raster) and moves it as compositor geometry —
    # fixes the blink/teleport from unsynchronized per-frame Ganesh repaints
    # into reused pooled GL textures on this driver. Smoothing (0..1, 1 = off)
    # low-pass filters the displayed position so residual data jumps glide.
    export WEBKIT_SCROLLBAR_SPRITE="${WEBKIT_SCROLLBAR_SPRITE:-1}"
    export WEBKIT_SCROLLBAR_SMOOTHING="${WEBKIT_SCROLLBAR_SMOOTHING:-0.4}"

    # ── Skia painting backend ────────────────────────────────────────────────
    # WEBKIT_SKIA_ENABLE_CPU_RENDERING and WEBKIT_SKIA_GPU_PAINTING_THREADS are
    # intentionally NOT set here. The browser auto-selects the painting backend
    # from a GPU capability probe in main.cpp (configureGpuModeFromCapabilities):
    # CPU painting on conservative stacks — e.g. the libhybris Adreno 610 — and
    # multi-threaded GPU painting on surfaceless-capable stacks (Mali, desktop).
    # CPU raster is the conservative default for two reasons: (1) the driver does
    # not honour cross-context EGL fence server-waits, so GPU tile painting can
    # corrupt tiles; (2) device A/B showed the synchronous cross-context GPU tile
    # submit is the scroll bottleneck, and all-CPU raster is ~2x faster (MDN
    # 4.2->8.2 fps) with better worst-frame on image grids and no corruption.
    # Fallbacks are env-gated in main.cpp: ATLANTIC_GPU_FORCE_GPU_PAINT=1
    # (gpu-explicit, the pre-build-316 default) and ATLANTIC_GPU_FORCE_GLFINISH=1
    # (gpu-sync). Export the WEBKIT_SKIA_* variables before launch to override
    # the auto-selection directly (the probe honours explicit values).
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
