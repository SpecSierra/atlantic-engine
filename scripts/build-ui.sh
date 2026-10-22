#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

if [ -n "${WPE_SOURCE_DIR:-}" ]; then
    WPE_SOURCE_DIR="${WPE_SOURCE_DIR}"
elif [ -n "${CI_CACHE_ROOT:-}" ]; then
    WPE_SOURCE_DIR="${CI_CACHE_ROOT}/sources/wpewebkit-${LEGACY_WPEWEBKIT_VERSION}"
else
    WPE_SOURCE_DIR="${LEGACY_WPE_SOURCE_DIR}"
fi

echo ""
echo "--- [11] Setting up Qt5 symlinks ---"
# A real directory in the way (the armhf chroot gets /usr/share/qt5/translations
# from Ubuntu packages) would make ln put the link INSIDE it, and qmake would
# then find no Qt modules; move such a non-Qt directory aside first.
for qt_dir in /usr/share/qt5; do
    if [ -d "${qt_dir}" ] && [ ! -L "${qt_dir}" ] && [ ! -e "${qt_dir}/mkspecs" ]; then
        rm -rf "${qt_dir}.distro"
        mv "${qt_dir}" "${qt_dir}.distro"
    fi
done
ln -sfn "${SYSROOT}/usr/share/qt5" /usr/share/qt5 2>/dev/null || true
ln -sfn "${SYSROOT}/usr/${ATL_LIBDIR}/qt5" "/usr/${ATL_LIBDIR}/qt5" 2>/dev/null || true
ln -sfn "${SYSROOT}/usr/include/qt5" /usr/include/qt5 2>/dev/null || true
for lib in libQt5Core.so.5 libQt5Xml.so.5 libicui18n.so.70 libicuuc.so.70 libicudata.so.70 libpcre16.so.0; do
    [ -f "${SYSROOT}/usr/${ATL_LIBDIR}/${lib}" ] && \
        ln -sfn "${SYSROOT}/usr/${ATL_LIBDIR}/${lib}" "/usr/lib/${lib}" 2>/dev/null || true
done

echo ""
echo "--- [12] Building atlantic-browser ---"
cd "${BROWSER_SRC}"
rm -rf build_browser build_wpe
mkdir -p build_browser build_wpe

export PATH="${SYSROOT}/usr/${ATL_LIBDIR}/qt5/bin:${PATH}"
export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
export PKG_CONFIG_PATH="${SYSROOT}/usr/${ATL_LIBDIR}/pkgconfig:${WPE_PREFIX}/lib/pkgconfig"

rm -rf build
mkdir build
cd build
qmake -spec "${SYSROOT}/usr/share/qt5/mkspecs/linux-g++" \
    ../sailfish-browser.pro \
    "CONFIG+=release" \
    "QMAKE_CXX=ccache g++ --sysroot=${SYSROOT}" \
    "QMAKE_CC=ccache gcc --sysroot=${SYSROOT}" \
    "QMAKE_LINK=ccache g++ --sysroot=${SYSROOT}" \
    "WPE_SFOS_PREFIX=${WPE_PREFIX}" \
    "SFOS_SYSROOT=${SYSROOT}" \
    "WPE_SOURCE_DIR=${WPE_SOURCE_DIR}" \
    "SFOS_LIBDIR=${ATL_LIBDIR}"

mkdir -p apps
cd apps
qmake -spec "${SYSROOT}/usr/share/qt5/mkspecs/linux-g++" \
    "${BROWSER_SRC}/apps/apps.pro" \
    "CONFIG+=release" \
    "QMAKE_CXX=ccache g++ --sysroot=${SYSROOT}" \
    "QMAKE_CC=ccache gcc --sysroot=${SYSROOT}" \
    "QMAKE_LINK=ccache g++ --sysroot=${SYSROOT}" \
    "WPE_SFOS_PREFIX=${WPE_PREFIX}" \
    "SFOS_SYSROOT=${SYSROOT}" \
    "WPE_SOURCE_DIR=${WPE_SOURCE_DIR}" \
    "SFOS_LIBDIR=${ATL_LIBDIR}"
make -j"${NPROC}" sub-lib-all
cp -a lib/libsailfishbrowser.so* "${BROWSER_SRC}/build_wpe/" 2>/dev/null || true
make -j"${NPROC}" sub-browser-all

cd "${BROWSER_SRC}"
find build -name "atlantic-browser" -not -name "*.o" -type f \
    -exec cp {} build_browser/atlantic-browser \; 2>/dev/null || true
find build -name "libsailfishbrowser.so*" \
    -exec cp -a {} build_wpe/ \; 2>/dev/null || true
find build -name "*.qm" -exec cp {} build_browser/ \; 2>/dev/null || true

echo "  atlantic-browser built."
