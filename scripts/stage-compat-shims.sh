# shellcheck shell=bash
#
# Compile the wpe-sfos-compat C shims and gather the Ubuntu runtime libs that
# SFOS lacks into ${COMPAT_BUILD}. SOURCED by build-rpms-native.sh (runs in the
# parent shell), not executed standalone.
#
# Requires from the caller: SCRIPT_DIR, STAGING, USE_GLIBC_COMPAT,
#   USE_GLIB_COMPAT, SFOS_SYSROOT, PATCH_GLIBC_VERSIONS, maybe_patch_glibc_versions().
# Exports for the caller: COMPAT_SRC, COMPAT_BUILD (consumed by the
#   "Staging wpe-sfos-compat" section).

echo "--- Building wpe-sfos-compat shims ---"
COMPAT_SRC="${SCRIPT_DIR}/shims/compat"
COMPAT_BUILD="${STAGING}/compat-build"
rm -rf "$COMPAT_BUILD"; mkdir -p "$COMPAT_BUILD"

CC=gcc
CFLAGS="-O2 -march=armv8-a -mtune=cortex-a73.cortex-a53 -fPIC -fvisibility=hidden"
SHARED="-shared -Wl,--allow-shlib-undefined"

for lib in \
    "libsigill_skip.so:libsigill_skip.c"
do
    name="${lib%%:*}"; src="${lib##*:}"
    $CC $CFLAGS $SHARED -o "${COMPAT_BUILD}/${name}" "${COMPAT_SRC}/${src}"
done

# libegl-stubs.so: must NOT use -fvisibility=hidden — symbols must be globally
# visible so dlsym(RTLD_DEFAULT, "eglCreateSync") finds them in patched libepoxy
$CC -O2 -march=armv8-a -mtune=cortex-a73.cortex-a53 -fPIC $SHARED \
    -o "${COMPAT_BUILD}/libegl-stubs.so" "${COMPAT_SRC}/libegl-stubs.c"

# libglibc-compat.so: needs version script (GLIBC_2.17 + GLIBC_2.34 sections)
# and must export dlopen/dlsym/dlerror@GLIBC_2.34 for binaries built on glibc 2.34+
if [ "${USE_GLIBC_COMPAT}" = "1" ]; then
    $CC -O2 -march=armv8-a -mtune=cortex-a73.cortex-a53 -fPIC $SHARED \
        -Wl,--version-script="${COMPAT_SRC}/libglibc-compat.map" \
        -o "${COMPAT_BUILD}/libglibc-compat.so" "${COMPAT_SRC}/libglibc-compat.c" \
        -ldl
fi

# GLib compat: provides g_once_init_enter/leave_pointer absent from Jolla's GLib 2.78.4 build
# Must link against SFOS libglib-2.0 so the wrappers call the real SFOS implementation
if [ "${USE_GLIB_COMPAT}" = "1" ]; then
    $CC -O2 -march=armv8-a -mtune=cortex-a73.cortex-a53 -fPIC $SHARED \
        --sysroot="${SFOS_SYSROOT}" \
        -Wl,-soname,libglib-compat.so \
        -o "${COMPAT_BUILD}/libglib-compat.so" "${COMPAT_SRC}/libglib_compat.c" \
        -L"${SFOS_SYSROOT}/usr/lib64" -lglib-2.0
    ln -sfn libglib-compat.so "${COMPAT_BUILD}/libglib-compat-preload.so"
fi

# Stub: libgssapi_krb5.so.2 (GSSAPI for libsoup3 — always returns unavailable on SFOS)
# Note: must NOT use -fvisibility=hidden here — version-script requires GLOBAL symbols
$CC -O2 -march=armv8-a -mtune=cortex-a73.cortex-a53 -fPIC $SHARED \
    -Wl,--version-script="${COMPAT_SRC}/libgssapi_krb5.map" \
    -Wl,-soname,libgssapi_krb5.so.2 \
    -o "${COMPAT_BUILD}/libgssapi_krb5.so.2" "${COMPAT_SRC}/libgssapi_krb5_stub.c"
ln -sfn libgssapi_krb5.so.2 "${COMPAT_BUILD}/libgssapi_krb5.so"

# Stub: libharfbuzz-icu.so.0 (avoids pulling in libicuuc.so.74 which SFOS doesn't have)
# Note: must NOT use -fvisibility=hidden here — symbols must be globally visible
$CC -O2 -march=armv8-a -mtune=cortex-a73.cortex-a53 -fPIC $SHARED \
    -Wl,-soname,libharfbuzz-icu.so.0 \
    -o "${COMPAT_BUILD}/libharfbuzz-icu.so.0" "${COMPAT_SRC}/libharfbuzz_icu_stub.c"
ln -sfn libharfbuzz-icu.so.0 "${COMPAT_BUILD}/libharfbuzz-icu.so"

# GStreamer device provider exposing gst-droid cameras (droidcamsrc) to
# WebKit's GstDeviceMonitor — without it getUserMedia({video}) finds no
# camera. Built against host GStreamer headers (ABI-stable, links the
# device's libgstreamer at runtime); staged to /usr/lib64/gstreamer-1.0.
mkdir -p "${COMPAT_BUILD}/gstreamer-1.0"
$CC -O2 -march=armv8-a -mtune=cortex-a73.cortex-a53 -fPIC $SHARED \
    $(pkg-config --cflags gstreamer-1.0) \
    -o "${COMPAT_BUILD}/gstreamer-1.0/libgstdroidcamdeviceprovider.so" \
    "${SCRIPT_DIR}/shims/droidcam/gstdroidcamdeviceprovider.c" \
    $(pkg-config --libs gstreamer-1.0)

# Copy missing runtime libs from Ubuntu (not present on SFOS) into compat dir
UBUNTU_LIBS=/usr/lib/aarch64-linux-gnu
for lib in \
    libsoup-3.0.so.0.7.1 \
    libbrotlidec.so.1.1.0 \
    libbrotlicommon.so.1.1.0 \
    libatomic.so.1.2.0 \
    libjpeg.so.8.2.2 \
    libgbm.so.1.0.0 \
    libenchant-2.so.2.3.3 \
    libhunspell-1.7.so.0.0.1 \
    libdav1d.so.7.0.0; do
    cp "${UBUNTU_LIBS}/${lib}" "${COMPAT_BUILD}/${lib}"
done

# libavif (decode-only, dav1d) built from source into WPE_PREFIX by build-engine.sh
# step [8]. WebKit links libavif.so.16; at runtime it pulls libdav1d.so.7 (copied
# above) — both resolve from wpe-compat via the browser's LD_LIBRARY_PATH. Copy the
# real versioned file; the soname symlinks are created in build-rpms-native.sh.
avif_real="$(readlink -f "${WPE_PREFIX}/lib/libavif.so")"
cp "${avif_real}" "${COMPAT_BUILD}/$(basename "${avif_real}")"

# Spellcheck: enchant loads its hunspell backend from the Ubuntu-baked module
# path (/usr/lib/aarch64-linux-gnu/enchant-2), so the rpm installs it there on
# the device; hunspell dictionaries go to /usr/share/hunspell.
mkdir -p "${COMPAT_BUILD}/enchant-2" "${COMPAT_BUILD}/hunspell"
cp "${UBUNTU_LIBS}/enchant-2/enchant_hunspell.so" "${COMPAT_BUILD}/enchant-2/"
cp /usr/share/hunspell/en_US.aff /usr/share/hunspell/en_US.dic "${COMPAT_BUILD}/hunspell/"

# Patch glibc version symbols in all compat shims and bundled libs
if [ "${PATCH_GLIBC_VERSIONS}" = "1" ]; then
    for f in "${COMPAT_BUILD}"/*.so "${COMPAT_BUILD}"/*.so.[0-9]* "${COMPAT_BUILD}"/enchant-2/*.so; do
        [ -f "$f" ] && maybe_patch_glibc_versions "$f"
    done
fi
