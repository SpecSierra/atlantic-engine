#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

WPE_WEBKIT_VERSION="${WPE_WEBKIT_VERSION:-${LEGACY_WPEWEBKIT_VERSION}}"
if [ -n "${WPE_SOURCE_DIR:-}" ]; then
    WPE_SOURCE_DIR="${WPE_SOURCE_DIR}"
elif [ -n "${CI_CACHE_ROOT:-}" ]; then
    WPE_SOURCE_DIR="${CI_CACHE_ROOT}/sources/wpewebkit-${WPE_WEBKIT_VERSION}"
elif [ -n "${CI_ROOT:-}" ]; then
    WPE_SOURCE_DIR="${CI_ROOT}/sources/wpewebkit-${WPE_WEBKIT_VERSION}"
else
    WPE_SOURCE_DIR="${WORK}/wpewebkit-${WPE_WEBKIT_VERSION}"
fi
QT5_PLUGIN_SOURCE_DIR="${QT5_PLUGIN_SOURCE_DIR:-${QT5_PLUGIN_SOURCE_DIR_DEFAULT}}"

resolve_sysroot_library() {
    local stem="$1"
    local direct="${SYSROOT}/usr/${ATL_LIBDIR}/${stem}.so"
    local candidate

    if [ -e "${direct}" ]; then
        printf '%s\n' "${direct}"
        return 0
    fi

    for candidate in "${SYSROOT}/usr/${ATL_LIBDIR}/${stem}.so".[0-9]*; do
        [ -e "${candidate}" ] || continue
        readlink -f "${candidate}"
        return 0
    done

    echo "ERROR: unable to resolve ${stem}.so under ${SYSROOT}/usr/${ATL_LIBDIR}" >&2
    exit 1
}

ICU_UC_LIB="$(resolve_sysroot_library libicuuc)"
ICU_I18N_LIB="$(resolve_sysroot_library libicui18n)"
ICU_DATA_LIB="$(resolve_sysroot_library libicudata)"

stage_webkit_pkgconfig_files() {
    local build_dir="$1"
    local pc_file

    mkdir -p "${WPE_PREFIX}/lib/pkgconfig"
    for pc_file in wpe-webkit-2.0.pc wpe-web-process-extension-2.0.pc; do
        if [ -f "${build_dir}/${pc_file}" ]; then
            cp "${build_dir}/${pc_file}" "${WPE_PREFIX}/lib/pkgconfig/${pc_file}"
        fi
    done
}

install_webkit_build_metadata() {
    local build_dir="$1"
    local metadata_dir="${WPE_PREFIX}/share/wpe-webkit-2.0/build-config"
    local cache_path="${build_dir}/CMakeCache.txt"
    local config_path="${build_dir}/cmakeconfig.h"

    mkdir -p "${metadata_dir}"

    [ -f "${cache_path}" ] && cp "${cache_path}" "${metadata_dir}/CMakeCache.txt"
    [ -f "${config_path}" ] && cp "${config_path}" "${metadata_dir}/cmakeconfig.h"

    python3 "${BUILD_TOOLS}/scripts/write-webkit-feature-flags.py" \
        "${cache_path}" \
        "${metadata_dir}/feature-flags.txt" \
        "${WPE_WEBKIT_VERSION}" \
        --source-dir "${WPE_SOURCE_DIR}" \
        --build-dir "${build_dir}"
}

echo ""
echo "--- [8] Building WPEWebKit ${WPE_WEBKIT_VERSION} (expect 60-90 min) ---"
# Select compiler toolchain.  WEBKIT_COMPILER=clang uses Clang 18 + lld which
# enables ThinLTO via WebKit's own COMPILER_IS_CLANG guard in
# WebKitCompilerFlags.cmake (GCC LTO is explicitly disabled there because it
# dead-strips LLInt assembly symbols).  The default falls back to GCC.
WEBKIT_COMPILER="${WEBKIT_COMPILER:-gcc}"
if [ "${WEBKIT_COMPILER}" = "clang" ] && [ "${ATL_ARCH}" != "aarch64" ]; then
    echo "ERROR: the Clang toolchain (sfos-toolchain-clang.cmake) is aarch64-only; build ${ATL_ARCH} with WEBKIT_COMPILER=gcc" >&2
    exit 1
fi
if [ "${WEBKIT_COMPILER}" = "clang" ]; then
    WEBKIT_TOOLCHAIN_FILE="${BUILD_TOOLS}/sfos-toolchain-clang.cmake"
    echo "  Compiler: Clang 18 + lld (ThinLTO)"
    # ccache needs CCACHE_CPP2=1 to work correctly with Clang; without it
    # ccache re-preprocesses the source through the compiler preprocessor
    # and misses the cache on second runs.
    export CCACHE_CPP2=1
else
    WEBKIT_TOOLCHAIN_FILE="${ATL_WEBKIT_TOOLCHAIN_GCC}"
    echo "  Compiler: GCC (no LTO)"
fi

# ── Toolchain cache-busting ──────────────────────────────────────────────────
# When the compiler flags change (e.g. adding/removing -fvisibility=hidden,
# changing -mtune from cortex-a73 to cortex-a73.cortex-a53 for Kryo 260),
# the stale .so must be invalidated.  A simple file-exists check would
# preserve the old library forever.  Instead, hash the toolchain and
# compare against a stamp; mismatch → force rebuild.
_toolchain_hash="$(sha256sum "${WEBKIT_TOOLCHAIN_FILE}" 2>/dev/null | awk '{print $1}')"
_toolchain_stamp="${WPE_PREFIX}/lib/.webkit-toolchain-hash"
if [ -n "${_toolchain_hash}" ] && [ -f "${_toolchain_stamp}" ] && [ -f "${WPE_PREFIX}/lib/libWPEWebKit-2.0.so" ]; then
    _saved_hash="$(cat "${_toolchain_stamp}" 2>/dev/null)"
    if [ "${_toolchain_hash}" != "${_saved_hash}" ]; then
        echo "  Toolchain changed (${_saved_hash:0:8} → ${_toolchain_hash:0:8}), forcing rebuild"
        rm -f "${WPE_PREFIX}/lib/libWPEWebKit-2.0.so"
    fi
fi

# ── Feature-policy cache-busting ─────────────────────────────────────────────
# The shared feature cmake (-C atlantic-wpe-features.cmake), the baked-in sandbox
# executable paths, AND the applied WebKit patch set are NOT part of the
# toolchain or version stamps, so a change like flipping ENABLE_BUBBLEWRAP_SANDBOX
# or adding/removing a source patch would otherwise keep the stale .so forever.
# Hash the feature file + bwrap/dbus-proxy paths + patches.sh + every applied
# webkit patch, and force a rebuild on mismatch.  (Patch changes silently NOT
# rebuilding WebKit is exactly how the GPU-process-DOM-rendering regression
# shipped — see scripts/patches.sh.)
_features_hash="$( { sha256sum "${BUILD_TOOLS}/cmake/atlantic-wpe-features.cmake" "${BUILD_TOOLS}/scripts/patches.sh" "${BUILD_TOOLS}"/patches/webkit/*.patch 2>/dev/null; printf '%s\n%s\n' "${BWRAP_EXECUTABLE:-/usr/bin/bwrap}" "${DBUS_PROXY_EXECUTABLE:-/usr/bin/xdg-dbus-proxy}"; } | sha256sum | awk '{print $1}')"
_features_stamp="${WPE_PREFIX}/lib/.webkit-features-hash"
if [ -n "${_features_hash}" ] && [ -f "${_features_stamp}" ] && [ -f "${WPE_PREFIX}/lib/libWPEWebKit-2.0.so" ]; then
    _saved_features_hash="$(cat "${_features_stamp}" 2>/dev/null)"
    if [ "${_features_hash}" != "${_saved_features_hash}" ]; then
        echo "  Feature policy changed (${_saved_features_hash:0:8} → ${_features_hash:0:8}), forcing rebuild"
        rm -f "${WPE_PREFIX}/lib/libWPEWebKit-2.0.so"
    fi
fi

# ── Version cache-busting ────────────────────────────────────────────────────
# The cached prefix may hold the previous WebKit version's build; without this
# check a versions.env bump would silently ship stale binaries under the new
# version label.  A missing stamp (cache predates this check) also forces a
# rebuild — the one-time cost beats shipping a mislabelled engine.
_version_stamp="${WPE_PREFIX}/lib/.webkit-version"
if [ -f "${WPE_PREFIX}/lib/libWPEWebKit-2.0.so" ]; then
    _saved_version="$(cat "${_version_stamp}" 2>/dev/null || true)"
    if [ "${WPE_WEBKIT_VERSION}" != "${_saved_version}" ]; then
        echo "  WebKit version changed (${_saved_version:-unstamped} → ${WPE_WEBKIT_VERSION}), forcing rebuild"
        rm -f "${WPE_PREFIX}/lib/libWPEWebKit-2.0.so"
    fi
fi

if [ ! -f "${WPE_PREFIX}/lib/libWPEWebKit-2.0.so" ]; then
    webkit_source_parent="$(dirname "${WPE_SOURCE_DIR}")"
    mkdir -p "${webkit_source_parent}"

    cd "${webkit_source_parent}"
    if [ -n "${CI_CACHE_ROOT:-}" ] && [ -d "${WPE_SOURCE_DIR}" ]; then
        rm -rf "${WPE_SOURCE_DIR}"
    fi
    if [ ! -d "${WPE_SOURCE_DIR}" ]; then
        echo "  Downloading tarball..."
        wget -q --show-progress \
            "https://wpewebkit.org/releases/wpewebkit-${WPE_WEBKIT_VERSION}.tar.xz" \
            -O "/tmp/wpewebkit-${WPE_WEBKIT_VERSION}.tar.xz"
        tar -xf "/tmp/wpewebkit-${WPE_WEBKIT_VERSION}.tar.xz" -C "${webkit_source_parent}"
        rm -f "/tmp/wpewebkit-${WPE_WEBKIT_VERSION}.tar.xz"
    fi

    cd "${WPE_SOURCE_DIR}"
    apply_repo_patches 1 "${PWD}" "${WEBKIT_SOURCE_PATCHES[@]}"

    PKG_CONFIG_PATH="${WPE_PREFIX}/lib/pkgconfig:${WPE_PREFIX}/lib/${ATL_MULTIARCH}/pkgconfig" \
    cmake -B WebKitBuild/Release -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="${WEBKIT_TOOLCHAIN_FILE}" \
        -DCMAKE_C_COMPILER_LAUNCHER=ccache \
        -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_FLAGS_RELEASE="-O3 -DNDEBUG" \
        -DCMAKE_INSTALL_PREFIX="${WPE_PREFIX}" \
        -C "${BUILD_TOOLS}/cmake/atlantic-wpe-features.cmake" \
        -DICU_INCLUDE_DIR="${SYSROOT}/usr/include" \
        -DICU_INCLUDE_DIRS="${SYSROOT}/usr/include" \
        -DICU_UC_LIBRARY="${ICU_UC_LIB}" \
        -DICU_I18N_LIBRARY="${ICU_I18N_LIB}" \
        -DICU_DATA_LIBRARY="${ICU_DATA_LIB}" \
        -DICU_UC_LIBRARY_RELEASE="${ICU_UC_LIB}" \
        -DICU_I18N_LIBRARY_RELEASE="${ICU_I18N_LIB}" \
        -DICU_DATA_LIBRARY_RELEASE="${ICU_DATA_LIB}" \
        -DPORT=WPE \
        -DENABLE_WPE_LEGACY_API=ON \
        -DBWRAP_EXECUTABLE="${BWRAP_EXECUTABLE:-/usr/bin/bwrap}" \
        -DDBUS_PROXY_EXECUTABLE="${DBUS_PROXY_EXECUTABLE:-/usr/bin/xdg-dbus-proxy}" \
        -DUSE_JPEGXL=OFF \
        -DUSE_THIN_ARCHIVES=ON \
        -DLTO_MODE=thin

    ninja -C WebKitBuild/Release -j"${NPROC:-$(nproc)}"
    cmake --install WebKitBuild/Release --prefix "${WPE_PREFIX}"

    stage_webkit_pkgconfig_files "${WPE_SOURCE_DIR}/WebKitBuild/Release"
    install_webkit_build_metadata "${WPE_SOURCE_DIR}/WebKitBuild/Release"

    sed -i 's/libsoup-3\.0 //' "${WPE_PREFIX}/lib/pkgconfig/wpe-webkit-2.0.pc" 2>/dev/null || true

    ln -sf "${WPE_SOURCE_DIR}/WebKitBuild/Release/cmakeconfig.h" \
       "${WPE_SOURCE_DIR}/WebKitBuild/Release/config.h" 2>/dev/null || true

    mkdir -p "${WPE_PREFIX}/lib/wpe-webkit-2.0/injected-bundle"
    cp WebKitBuild/Release/lib/libWPEInjectedBundle.so \
       "${WPE_PREFIX}/lib/wpe-webkit-2.0/injected-bundle/" 2>/dev/null || \
    cp WebKitBuild/Release/lib/libWPEInjectedBundle.so "${WPE_PREFIX}/lib/" 2>/dev/null || true

    echo "  WPEWebKit installed."
    printf '%s\n' "${_toolchain_hash}" > "${_toolchain_stamp}"
    printf '%s\n' "${WPE_WEBKIT_VERSION}" > "${_version_stamp}"
    printf '%s\n' "${_features_hash}" > "${_features_stamp}"
else
    echo "  WPEWebKit already built."
    cmake --install "${WPE_SOURCE_DIR}/WebKitBuild/Release" --prefix "${WPE_PREFIX}"
    stage_webkit_pkgconfig_files "${WPE_SOURCE_DIR}/WebKitBuild/Release"
    install_webkit_build_metadata "${WPE_SOURCE_DIR}/WebKitBuild/Release"
fi

echo ""
if [ "${PATCH_GLIBC_VERSIONS}" = "1" ]; then
    echo "--- [9] Patching GLIBC version tags ---"
    for file in \
        "${WPE_PREFIX}"/lib/libWPEWebKit-2.0.so.*.*.* \
        "${WPE_PREFIX}/lib/libWPEInjectedBundle.so" \
        "${WPE_PREFIX}/lib/wpe-webkit-2.0/injected-bundle/libWPEInjectedBundle.so" \
        "${WPE_PREFIX}/libexec/wpe-webkit-2.0/WPEWebProcess" \
        "${WPE_PREFIX}/libexec/wpe-webkit-2.0/WPENetworkProcess" \
        "${WPE_PREFIX}/libexec/wpe-webkit-2.0/WPEGPUProcess"
    do
        [ -f "${file}" ] && maybe_patch_glibc_versions "${file}" || true
    done
else
    echo "--- [9] Skipping GLIBC version retagging for SFOS ${SFOS_SYSROOT_VERSION} ---"
fi

echo ""
echo "--- [10] Building Qt5 WPE plugin ---"
# ── Qt5 plugin cache-busting ─────────────────────────────────────────────────
# Like the WebKit version/toolchain stamps above: the cached prefix keeps
# libqtwpe.so forever, so a change to qt5-plugin/ sources would silently
# never be rebuilt.  Hash the plugin source tree and force a rebuild (and a
# fresh copy into the WebKit source tree) when it changes.
_qt5_plugin_hash="$( (cd "${QT5_PLUGIN_SOURCE_DIR}" 2>/dev/null && find . -type f ! -path './build/*' -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}') || true)"
_qt5_plugin_stamp="${WPE_PREFIX}/lib/.qtwpe-source-hash"
if [ -n "${_qt5_plugin_hash}" ] && [ -f "${WPE_PREFIX}/lib/qt5/qml/org/wpewebkit/qtwpe/libqtwpe.so" ]; then
    _saved_qt5_hash="$(cat "${_qt5_plugin_stamp}" 2>/dev/null || true)"
    if [ "${_qt5_plugin_hash}" != "${_saved_qt5_hash}" ]; then
        echo "  Qt5 plugin source changed (${_saved_qt5_hash:0:8} → ${_qt5_plugin_hash:0:8}), forcing plugin rebuild"
        rm -f "${WPE_PREFIX}/lib/qt5/qml/org/wpewebkit/qtwpe/libqtwpe.so"
        rm -rf "${WPE_SOURCE_DIR}/Source/WebKit/UIProcess/API/wpe/qt5"
    fi
fi
if [ ! -f "${WPE_PREFIX}/lib/qt5/qml/org/wpewebkit/qtwpe/libqtwpe.so" ]; then
    export PATH="${SYSROOT}/usr/${ATL_LIBDIR}/qt5/bin:${PATH}"

    if [ ! -d "${WPE_SOURCE_DIR}/Source/WebKit/UIProcess/API/wpe/qt5" ]; then
        if [ ! -d "${QT5_PLUGIN_SOURCE_DIR}" ]; then
            echo "ERROR: ${QT5_PLUGIN_SOURCE_DIR} not found; required to copy the carried-forward Qt5 plugin into ${WPE_WEBKIT_VERSION}" >&2
            exit 1
        fi
        echo "  Copying Qt5 plugin from ${QT5_PLUGIN_SOURCE_DIR}..."
        cp -a "${QT5_PLUGIN_SOURCE_DIR}" \
              "${WPE_SOURCE_DIR}/Source/WebKit/UIProcess/API/wpe/qt5"
    fi

    qt5_plugin_dir="${WPE_SOURCE_DIR}/Source/WebKit/UIProcess/API/wpe/qt5"
    apply_repo_patches 7 "${qt5_plugin_dir}" "${QT5_PLUGIN_PATCHES[@]}"
    cd "${qt5_plugin_dir}"

    rm -rf build

    PKG_CONFIG_PATH="${WPE_PREFIX}/lib/pkgconfig:${WPE_PREFIX}/lib/${ATL_MULTIARCH}/pkgconfig" \
    cmake -B build -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="${ATL_QT_TOOLCHAIN}" \
        -DCMAKE_C_COMPILER_LAUNCHER=ccache \
        -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${WPE_PREFIX}" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DWPE_WEBKIT_BUILD_DIR="${WPE_SOURCE_DIR}/WebKitBuild/Release"
    ninja -C build -j"${NPROC:-$(nproc)}"
    cmake --install build --prefix "${WPE_PREFIX}"
    echo "  Qt5 WPE plugin installed."
    if [ -n "${_qt5_plugin_hash}" ]; then
        printf '%s\n' "${_qt5_plugin_hash}" > "${_qt5_plugin_stamp}"
    fi
else
    echo "  Qt5 WPE plugin already built."
fi
