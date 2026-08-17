#!/bin/bash
#
# Patch apply order.
#
# WHY a patch exists lives in a header comment at the top of the patch file
# itself (`patch` skips leading text before the first diff header), so the
# rationale cannot drift from the diff. This file carries only the ORDER and the
# ordering constraints, which are load-bearing: patches touching the same file
# must stay in this sequence.
#
# `patches/SERIES.md` is generated from this list (scripts/gen-patch-series.py).
# Disabled-but-kept patches live in `patches/disabled/` and are never applied.
#
# On a version bump: validate the stack SEQUENTIALLY (isolated dry-runs give
# false failures), and regenerate the portability patches from compile errors
# rather than hand-fixing hunks — see docs/STREAMLINE-PLAN.md A1.

readonly ENGINE_SOURCE_PATCHES=(
    "patches/engine/libepoxy-rtld-default-fallback.patch"
)

readonly WEBKIT_SOURCE_PATCHES=(
    # --- Build the tree at all on this host/sysroot (behaviour-neutral) -----
    # Mechanical: CMake repairs, then missing includes / owner headers per
    # subsystem. Must come first; everything below assumes a compiling tree.
    "patches/webkit/webkit-build-cmake-fixes.patch"
    "patches/webkit/webkit-portability-wtf-pal.patch"
    "patches/webkit/webkit-portability-jsc.patch"
    "patches/webkit/webkit-portability-webcore.patch"

    # --- Compositing, raster and scroll ------------------------------------
    # Order within this block is the ordering constraint that matters most:
    # SkiaPaintingEngine.cpp, CoordinatedBackingStoreProxy.{cpp,h},
    # CoordinatedBackingStoreTile.cpp, CoordinatedPlatformLayer.cpp,
    # ThreadedCompositor.cpp and LayerTreeHost.cpp are each touched by several
    # of these.
    "patches/webkit/webkit-glfence-disable-env.patch"
    "patches/webkit/webkit-texture-pool.patch"
    "patches/webkit/webkit-raster-on-compositor-thread-env.patch"
    # AFTER raster-on-compositor (same file).
    "patches/webkit/webkit-skia-record-rtree-env.patch"
    # AFTER raster-on-compositor + skia-record-rtree (SkiaPaintingEngine.cpp).
    "patches/webkit/webkit-scroll-degradation.patch"

    # --- Memory ------------------------------------------------------------
    "patches/webkit/webkit-memory-pressure.patch"
    "patches/webkit/webkit-image-subsampling.patch"

    # --- GPU process / JSC -------------------------------------------------
    # See patches/disabled/ for the GPU-process DOM-rendering patch: it renders
    # blank on this libhybris/Adreno device (no GBM/DRM render node) and is kept
    # only for future hybris GPU-export work.
    "patches/webkit/webkit-gpu-process-egl-default-display-fallback.patch"
    "patches/webkit/webkit-jsc-arm64-tuning.patch"

    # --- Input, scrollbars, media -----------------------------------------
    "patches/webkit/webkit-kinetic-fling.patch"
    "patches/webkit/webkit-scrollbar.patch"
    "patches/webkit/webkit-gst-media.patch"
    "patches/webkit/webkit-wpe-dark-mode-runtime.patch"
    "patches/webkit/webkit-wpe-page-scale-api.patch"

    # --- Sandboxing --------------------------------------------------------
    # Disjoint files, order between these two is irrelevant.
    "patches/webkit/webkit-bubblewrap-sfos-sandbox.patch"
    "patches/webkit/webkit-seccomp-filter-no-namespace.patch"

    # --- Scroll/composite synchronisation ----------------------------------
    # Applies on top of the fully patched compositor above.
    "patches/webkit/webkit-composite-scroll-sync.patch"

    "patches/webkit/webkit-wpe-spellcheck-enchant.patch"

    # --- Load-time responsiveness and caching ------------------------------
    "patches/webkit/webkit-load-responsiveness.patch"
    "patches/webkit/webkit-http-cache.patch"
    "patches/webkit/webkit-repaint-scope.patch"

    # --- Off-main-thread scrolling (the APZ bargain) -----------------------
    # AFTER composite-scroll-sync (LayerTreeHost.cpp contexts overlap).
    "patches/webkit/webkit-fling-throttle-env.patch"
    "patches/webkit/webkit-independent-scroll.patch"
    # AFTER composite-scroll-sync and fling-throttle (ThreadedCompositor.cpp,
    # ScrollingTree.*, CoordinatedBackingStoreTile.*).
    "patches/webkit/webkit-tile-upload.patch"

    "patches/webkit/webkit-no-fake-mouse-move-env.patch"
    "patches/webkit/webkit-video-proxy-target-unbind-guard.patch"

    # AFTER every other patch touching LayerTreeHost.cpp.
    "patches/webkit/webkit-damage-limited-composite-env.patch"
    # AFTER tile-upload (CoordinatedTileBuffer.cpp).
    "patches/webkit/webkit-tile-buffer-skip-zero-env.patch"
    # Frame-trace tooling: atlFrameTrace() is used by patches below.
    "patches/webkit/webkit-frame-trace-env.patch"
    "patches/webkit/webkit-root-customprop-repaint-skip-env.patch"
    "patches/webkit/webkit-drop-tiles-when-hidden-env.patch"
    # AFTER every other patch touching CoordinatedPlatformLayer.cpp
    # (scroll-degradation, tile-upload, drop-tiles-when-hidden).
    "patches/webkit/webkit-composite-skip-locked-layers-env.patch"

    # --- Rendering features ------------------------------------------------
    "patches/webkit/webkit-svg.patch"
    "patches/webkit/webkit-clipboard-qt-hook.patch"
    "patches/webkit/webkit-viewport-unit-font-size-zoom.patch"
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
