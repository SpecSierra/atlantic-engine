#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

echo ""
echo "--- [4] Building engine dependencies ---"

echo ""
echo "--- [5] Building libwpe ---"
if [ ! -f "${WPE_PREFIX}/lib/libwpe-1.0.so" ]; then
    cd "${WORK}"
    if [ ! -d libwpe ]; then
        git clone --depth=1 --branch "${LIBWPE_VERSION}" \
            https://github.com/WebPlatformForEmbedded/libwpe libwpe 2>/dev/null || \
        git clone --depth=1 https://github.com/WebPlatformForEmbedded/libwpe libwpe
    fi
    cd libwpe
    rm -rf build
    CC="ccache gcc" CXX="ccache g++" PKG_CONFIG_PATH="${WPE_PREFIX}/lib/pkgconfig" \
    meson setup build \
        --native-file "${BUILD_TOOLS}/native-meson.ini" \
        --prefix "${WPE_PREFIX}" \
        --libdir lib \
        --buildtype release \
        -Dlibxkbcommon:enable-x11=false \
        -Dlibxkbcommon:enable-wayland=false \
        -Dlibxkbcommon:enable-tools=false \
        -Dlibxkbcommon:enable-docs=false \
        -Dlibxkbcommon:enable-xkbregistry=false
    ninja -C build -j"${NPROC}" install
    echo "  libwpe installed."
else
    echo "  libwpe already built."
fi

echo ""
echo "--- [6] Building libepoxy ---"
if [ ! -f "${WPE_PREFIX}/lib/libepoxy.so" ]; then
    cd "${WORK}"
    if [ ! -d libepoxy ]; then
        git clone --depth=1 --branch "${LIBEPOXY_VERSION}" \
            https://github.com/anholt/libepoxy libepoxy 2>/dev/null || \
        git clone --depth=1 https://github.com/anholt/libepoxy libepoxy
    fi
    cd libepoxy
    apply_repo_patches 1 "${PWD}" "${ENGINE_SOURCE_PATCHES[@]}"
    rm -rf build
    CC="ccache gcc" CXX="ccache g++" PKG_CONFIG_PATH="${WPE_PREFIX}/lib/pkgconfig" \
    meson setup build \
        --native-file "${BUILD_TOOLS}/native-meson.ini" \
        --prefix "${WPE_PREFIX}" \
        --libdir lib \
        --buildtype release \
        -Dx11=false -Dglx=no -Degl=yes
    ninja -C build -j"${NPROC}" install
    echo "  libepoxy installed."
else
    echo "  libepoxy already built."
fi

echo ""
echo "--- [7] Building WPEBackend-fdo ---"
if [ ! -f "${WPE_PREFIX}/lib/libWPEBackend-fdo-1.0.so" ]; then
    cd "${WORK}"
    if [ ! -d WPEBackend-fdo ]; then
        git clone --depth=1 --branch "${WPEBACKEND_FDO_VERSION}" \
            https://github.com/igalia/WPEBackend-fdo WPEBackend-fdo 2>/dev/null || \
        git clone --depth=1 https://github.com/igalia/WPEBackend-fdo WPEBackend-fdo
    fi
    cd WPEBackend-fdo
    rm -rf build
    CC="ccache gcc" CXX="ccache g++" PKG_CONFIG_PATH="${WPE_PREFIX}/lib/pkgconfig" \
    meson setup build \
        --native-file "${BUILD_TOOLS}/native-meson.ini" \
        --prefix "${WPE_PREFIX}" \
        --libdir lib \
        --buildtype release
    ninja -C build -j"${NPROC}" install
    echo "  WPEBackend-fdo installed."
else
    echo "  WPEBackend-fdo already built."
fi

echo ""
echo "--- [8] Building libavif (decode-only, dav1d) ---"
# WebKit's USE_AVIF links libavif (soname libavif.so.16). Ubuntu's prebuilt
# libavif hard-links ALL codecs (aom/rav1e/svt/gav1/yuv) as NEEDED, which would
# force bundling ~7 libs (incl. Rust) onto the device. Build a lean libavif here
# with dav1d decode only and no libyuv, so the device lib NEEDs just libdav1d +
# libc. Host is aarch64, so this native build is device-compatible; it is bundled
# into wpe-sfos-compat (with libdav1d) by stage-compat-shims.sh and glibc-patched.
if [ ! -f "${WPE_PREFIX}/lib/libavif.so" ]; then
    cd "${WORK}"
    if [ ! -d libavif ]; then
        git clone --depth=1 --branch "${LIBAVIF_VERSION}" \
            https://github.com/AOMediaCodec/libavif libavif 2>/dev/null || \
        git clone --depth=1 https://github.com/AOMediaCodec/libavif libavif
    fi
    cd libavif
    rm -rf build
    PKG_CONFIG_PATH="${WPE_PREFIX}/lib/pkgconfig" \
    cmake -B build -G Ninja \
        -DCMAKE_INSTALL_PREFIX="${WPE_PREFIX}" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER_LAUNCHER=ccache \
        -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
        -DBUILD_SHARED_LIBS=ON \
        -DAVIF_CODEC_DAV1D=SYSTEM \
        -DAVIF_LIBYUV=OFF \
        -DAVIF_LIBSHARPYUV=OFF \
        -DAVIF_BUILD_APPS=OFF \
        -DAVIF_BUILD_TESTS=OFF \
        -DAVIF_BUILD_EXAMPLES=OFF \
        -DAVIF_ENABLE_WERROR=OFF
    ninja -C build -j"${NPROC}"
    ninja -C build install
    echo "  libavif installed."
else
    echo "  libavif already built."
fi
