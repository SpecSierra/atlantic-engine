#!/bin/bash
# build-rpms-native.sh — Build all WPE SFOS RPMs using fpm (no sfdk required).
#
# Prerequisite: everything already built and installed under /opt/wpe-sfos/
# by the test build, plus browser binaries in sailfish-browser-wpe/build_*.
#
# Usage: bash build-rpms-native.sh
# Output RPMs are placed in /tmp/wpe-sfos-rpms/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/scripts/common.sh"
source "${SCRIPT_DIR}/deploy/runtime-common.sh"

cleanup_target() {
    rm -rf "${SCRIPT_DIR}/adblock-engine/target"
}
trap cleanup_target EXIT

OUT="${OUT:-/tmp/wpe-sfos-rpms}"
STAGING="${STAGING:-/tmp/wpe-sfos-stage}"
PACKAGE_RUNTIME_PREFIX="${PACKAGE_RUNTIME_PREFIX:-/opt/wpe-sfos}"
ATLANTIC_RUNTIME_PREFIX="${PACKAGE_RUNTIME_PREFIX}"
CONTENT_BLOCKER_DATA_DIR="${SCRIPT_DIR}/data/content-blocker"

mkdir -p "$OUT"

maybe_patch_glibc_versions() {
    [ "${PATCH_GLIBC_VERSIONS}" = "1" ] || return 0
        python3 "${SCRIPT_DIR}/patch-glibc-versions.py" "$@"
}

if [ "${USE_COW_STRING_COMPAT:-0}" = "1" ]; then
    echo "ERROR: USE_COW_STRING_COMPAT is no longer supported in the SFOS ${SFOS_SYSROOT_VERSION} default path." >&2
    echo "       The opaque prebuilt libcow_string_compat shim has been removed; keep the flag disabled." >&2
    exit 1
fi

WPE_COMPAT_PRELOAD="$(atlantic_build_ld_preload)"
WPE_COMPAT_LIBRARY_PATH="$(atlantic_default_library_path)"
WPE_HELPER_LIBRARY_PATH="$(atlantic_default_helper_library_path)"

# ---------------------------------------------------------------------------
# Helper: copy a file/symlink tree into staging root
# ---------------------------------------------------------------------------
stage_cp() {
    local src="$1" dst_dir="$2" root="$3"
    mkdir -p "${root}${dst_dir}"
    cp -a "$src" "${root}${dst_dir}/"
}

stage_shared_library_family() {
    local source_stem="$1" dst_dir="$2" root="$3"
    local matches=("${source_stem}"*)

    if [ ! -e "${matches[0]}" ]; then
        echo "ERROR: no shared-library files found for ${source_stem}" >&2
        return 1
    fi

    mkdir -p "${root}${dst_dir}"
    cp -a "${matches[@]}" "${root}${dst_dir}/"
}

patch_staged_library_family() {
    local staged_symlink="$1"
    maybe_patch_glibc_versions "$(readlink -f "${staged_symlink}")"
}

patch_binary_prefix_string() {
    local file="$1" old="$2" new="$3"
    python3 - "$file" "$old" "$new" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
old = sys.argv[2].encode()
new = sys.argv[3].encode()

if len(new) > len(old):
    raise SystemExit(f"replacement is longer than source: {new!r} > {old!r}")

data = path.read_bytes()
count = data.count(old)
if count == 0:
    raise SystemExit(f"source string not found in {path}: {sys.argv[2]}")

data = data.replace(old, new + b"\0" * (len(old) - len(new)))
path.write_bytes(data)
print(f"patched {count} occurrence(s) of {sys.argv[2]} in {path}")
PY
}

patch_webkit_runtime_paths() {
    local file="$1"
    patch_binary_prefix_string "$file" \
        "${WPE_PREFIX}/libexec/wpe-webkit-2.0" \
        "${PACKAGE_RUNTIME_PREFIX}/libexec/wpe-webkit-2.0"
    patch_binary_prefix_string "$file" \
        "${WPE_PREFIX}/share/locale" \
        "/usr/share/locale"
    patch_binary_prefix_string "$file" \
        "${WPE_PREFIX}/lib/wpe-webkit-2.0/injected-bundle/" \
        "${PACKAGE_RUNTIME_PREFIX}/lib/wpe-webkit-2.0/injected-bundle/"
    patch_binary_prefix_string "$file" \
        "${WPE_PREFIX}/share/wpe-webkit-2.0" \
        "/usr/share/wpe-webkit-2.0"
}

# ---------------------------------------------------------------------------
# Helper: build an RPM with fpm from a staging root
# ---------------------------------------------------------------------------
fpm_rpm() {
    local name="$1" version="$2" summary="$3" stage_root="$4"
    shift 4
    local iteration="${RPM_ITERATION:-1}"

    # Write ldconfig scripts; FPM_POST_EXTRA may inject extra commands into post
    local post="${STAGING}/post-${name}.sh" postun="${STAGING}/postun-${name}.sh"
    printf '#!/bin/sh\n/sbin/ldconfig || :\n%s\n' "${FPM_POST_EXTRA:-}" > "$post"
    printf '#!/bin/sh\n/sbin/ldconfig || :\n' > "$postun"

    echo "==> Building RPM: ${name}-${version}-${iteration}"
    fpm -s dir -t rpm \
        -n "$name" \
        -v "$version" \
        --iteration "${iteration}" \
        --architecture aarch64 \
        --rpm-summary "$summary" \
        --after-install "$post" \
        --after-remove "$postun" \
        --force \
        --package "${OUT}/${name}-${version}-${iteration}.aarch64.rpm" \
        "$@" \
        -C "$stage_root" .
    echo "    -> ${OUT}/${name}-${version}-${iteration}.aarch64.rpm"
}

# ===========================================================================
# 1. libwpe
# ===========================================================================
echo "--- Staging libwpe ---"
S="${STAGING}/libwpe"; rm -rf "$S"; mkdir -p "$S"
stage_shared_library_family "${WPE_PREFIX}/lib/libwpe-1.0.so" /usr/lib64 "$S"
# devel files (include in same RPM for simplicity)
stage_cp "${WPE_PREFIX}/include/wpe-1.0"             /usr/include "$S"
mkdir -p "${S}/usr/lib64/pkgconfig"
cp -a "${WPE_PREFIX}/lib/pkgconfig/wpe-1.0.pc"      "${S}/usr/lib64/pkgconfig/"
sed -i "s|${WPE_PREFIX}|/usr|g"                      "${S}/usr/lib64/pkgconfig/wpe-1.0.pc"

fpm_rpm libwpe "$LIBWPE_VERSION" "WPE platform library for Sailfish OS" "$S"

# ===========================================================================
# 2. libepoxy
# ===========================================================================
echo "--- Staging libepoxy ---"
S="${STAGING}/libepoxy"; rm -rf "$S"; mkdir -p "$S"
stage_shared_library_family "${WPE_PREFIX}/lib/libepoxy.so" /usr/lib64 "$S"
patch_staged_library_family "${S}/usr/lib64/libepoxy.so"
stage_cp "${WPE_PREFIX}/include/epoxy"               /usr/include "$S"
mkdir -p "${S}/usr/lib64/pkgconfig"
cp -a "${WPE_PREFIX}/lib/pkgconfig/epoxy.pc"         "${S}/usr/lib64/pkgconfig/"
sed -i "s|${WPE_PREFIX}|/usr|g"                      "${S}/usr/lib64/pkgconfig/epoxy.pc"

fpm_rpm libepoxy "$LIBEPOXY_VERSION" "OpenGL function pointer management for Sailfish OS" "$S"

# ===========================================================================
# 3. wpebackend-fdo
# ===========================================================================
echo "--- Staging wpebackend-fdo ---"
S="${STAGING}/wpebackend-fdo"; rm -rf "$S"; mkdir -p "$S"
stage_shared_library_family "${WPE_PREFIX}/lib/libWPEBackend-fdo-1.0.so" /usr/lib64 "$S"
patch_staged_library_family "${S}/usr/lib64/libWPEBackend-fdo-1.0.so"
stage_cp "${WPE_PREFIX}/include/wpe-fdo-1.0"              /usr/include "$S"
mkdir -p "${S}/usr/lib64/pkgconfig"
cp -a "${WPE_PREFIX}/lib/pkgconfig/wpebackend-fdo-1.0.pc"    "${S}/usr/lib64/pkgconfig/"
sed -i "s|${WPE_PREFIX}|/usr|g" "${S}/usr/lib64/pkgconfig/wpebackend-fdo-1.0.pc"

fpm_rpm wpebackend-fdo "$WPEBACKEND_FDO_VERSION" "WPE backend (freedesktop.org/Wayland) for Sailfish OS" "$S" \
    --depends libwpe --depends libepoxy

# ===========================================================================
# 3b. Sandbox runtime executables (bwrap, xdg-dbus-proxy)
# ===========================================================================
# These are the device-side binaries libWPEWebKit exec's when the bubblewrap
# sandbox is enabled (the compiled-in BWRAP_EXECUTABLE / DBUS_PROXY_EXECUTABLE
# paths are /usr/bin/bwrap and /usr/bin/xdg-dbus-proxy).  Built by
# scripts/build-sandbox-deps.sh into ${WPE_PREFIX}/bin.  Packaged under their
# upstream names so atlantic-browser can Requires them; libcap (bwrap) and
# glib2 (xdg-dbus-proxy) are core SFOS libs always present, so they are not
# listed as explicit Requires here.
if [ -x "${WPE_PREFIX}/bin/bwrap" ]; then
    echo "--- Staging bubblewrap ---"
    S="${STAGING}/bubblewrap"; rm -rf "$S"; mkdir -p "${S}/usr/bin"
    cp -a "${WPE_PREFIX}/bin/bwrap" "${S}/usr/bin/bwrap"
    maybe_patch_glibc_versions "${S}/usr/bin/bwrap"
    fpm_rpm bubblewrap "$BUBBLEWRAP_VERSION" "Bubblewrap sandbox helper (for the WPE WebKit sandbox)" "$S"
else
    echo "WARNING: ${WPE_PREFIX}/bin/bwrap missing — skipping bubblewrap package (run scripts/build-sandbox-deps.sh)" >&2
fi

if [ -x "${WPE_PREFIX}/bin/xdg-dbus-proxy" ]; then
    echo "--- Staging xdg-dbus-proxy ---"
    S="${STAGING}/xdg-dbus-proxy"; rm -rf "$S"; mkdir -p "${S}/usr/bin"
    cp -a "${WPE_PREFIX}/bin/xdg-dbus-proxy" "${S}/usr/bin/xdg-dbus-proxy"
    maybe_patch_glibc_versions "${S}/usr/bin/xdg-dbus-proxy"
    fpm_rpm xdg-dbus-proxy "$XDG_DBUS_PROXY_VERSION" "D-Bus proxy for the WPE WebKit sandbox" "$S"
else
    echo "WARNING: ${WPE_PREFIX}/bin/xdg-dbus-proxy missing — skipping xdg-dbus-proxy package (run scripts/build-sandbox-deps.sh)" >&2
fi

# ===========================================================================
# 4. wpewebkit2
# ===========================================================================
echo "--- Staging wpewebkit2 ---"
S="${STAGING}/wpewebkit2"; rm -rf "$S"; mkdir -p "$S"

# Main library — patch the staged copy rather than mutating the source prefix.
stage_shared_library_family "${WPE_PREFIX}/lib/libWPEWebKit-2.0.so" /usr/lib64 "$S"
patch_staged_library_family "${S}/usr/lib64/libWPEWebKit-2.0.so"
patch_webkit_runtime_paths "$(readlink -f "${S}/usr/lib64/libWPEWebKit-2.0.so")"

# WOFF2 runtime shared libraries are required when USE_WOFF2=ON.
# Bundle them into /usr/lib64 so Atlantic can start on stock SFOS images.
stage_shared_library_family "/usr/lib/aarch64-linux-gnu/libwoff2common.so" /usr/lib64 "$S"
stage_shared_library_family "/usr/lib/aarch64-linux-gnu/libwoff2dec.so" /usr/lib64 "$S"
patch_staged_library_family "${S}/usr/lib64/libwoff2common.so"
patch_staged_library_family "${S}/usr/lib64/libwoff2dec.so"

# InjectedBundle — staged in both the install path AND the compile-time prefix
# (WPEWebProcess binary has /opt/wpe-sfos hard-coded as the injected-bundle dir)
mkdir -p "${S}/usr/lib64/wpe-webkit-2.0"
mkdir -p "${S}${PACKAGE_RUNTIME_PREFIX}/lib/wpe-webkit-2.0/injected-bundle"
cp -a "${WPE_PREFIX}/lib/wpe-webkit-2.0/injected-bundle/libWPEInjectedBundle.so" \
      "${S}/usr/lib64/wpe-webkit-2.0/"
cp -a "${WPE_PREFIX}/lib/wpe-webkit-2.0/injected-bundle/libWPEInjectedBundle.so" \
      "${S}${PACKAGE_RUNTIME_PREFIX}/lib/wpe-webkit-2.0/injected-bundle/"

# Helper process binaries — patch GLIBC version requirements (2.34→2.17) so they run on SFOS.
# WPEGPUProcess only exists when ENABLE_GPU_PROCESS=ON; skip any helper that the
# WebKit build did not produce (the GPU process is disabled on no-GBM/hybris).
mkdir -p "${S}/usr/libexec/wpe-webkit-2.0"
for helper in WPEWebProcess WPENetworkProcess WPEGPUProcess; do
    src="${WPE_PREFIX}/libexec/wpe-webkit-2.0/${helper}"
    if [ ! -e "${src}" ]; then
        echo "  helper ${helper} not built — skipping"
        continue
    fi
    cp -a "${src}" "${S}/usr/libexec/wpe-webkit-2.0/"
    maybe_patch_glibc_versions "${S}/usr/libexec/wpe-webkit-2.0/${helper}"
done

# Shared runtime environment for generated wrappers.
mkdir -p "${S}${PACKAGE_RUNTIME_PREFIX}/libexec/atlantic"
install -m 755 "${SCRIPT_DIR}/deploy/runtime-common.sh" \
    "${S}${PACKAGE_RUNTIME_PREFIX}/libexec/atlantic/runtime-common.sh"

# Wrapper scripts for helper processes (set runtime env and launch the real helper).
mkdir -p "${S}${PACKAGE_RUNTIME_PREFIX}/libexec/wpe-webkit-2.0"
for helper in WPEWebProcess WPENetworkProcess WPEGPUProcess; do
    # Only wrap helpers that were actually staged (WPEGPUProcess absent when the
    # GPU process is disabled).
    [ -e "${S}/usr/libexec/wpe-webkit-2.0/${helper}" ] || continue
    cat > "${S}${PACKAGE_RUNTIME_PREFIX}/libexec/wpe-webkit-2.0/${helper}" <<WRAPPER
#!/bin/sh
. "${PACKAGE_RUNTIME_PREFIX}/libexec/atlantic/runtime-common.sh"
ATLANTIC_LD_PRELOAD='${WPE_COMPAT_PRELOAD}'
ATLANTIC_LD_LIBRARY_PATH='${WPE_HELPER_LIBRARY_PATH}'
atlantic_export_helper_env
# Pin the WPE helpers (WebProcess/NetworkProcess/GPUProcess) to the big cores.
# The WebProcess runs the compositor/paint threads, so letting them drift onto
# the little cluster (cores 0-3 on the Snapdragon 665) causes visible scroll
# jank — device-verified. An earlier "unpin to all cores for heavy-page
# throughput" assumed the scheduler keeps hot threads on the big cluster by
# itself; it does not, and scrolling regressed. Big cores = upper half of the
# CPU range (Kryo 260 Gold 4-7 here), derived from nproc so the future
# Mali/Dimensity device is handled too. ATLANTIC_HELPER_CPUSET overrides.
if command -v taskset >/dev/null 2>&1 && command -v nproc >/dev/null 2>&1; then
    cpuset="\${ATLANTIC_HELPER_CPUSET:-\$(( \$(nproc) / 2 ))-\$(( \$(nproc) - 1 ))}"
    exec taskset -c "\${cpuset}" "${ATLANTIC_WPE_HELPER_DIR}/${helper}" "\$@"
fi
exec "${ATLANTIC_WPE_HELPER_DIR}/${helper}" "\$@"
WRAPPER
    chmod 755 "${S}${PACKAGE_RUNTIME_PREFIX}/libexec/wpe-webkit-2.0/${helper}"
done

# Inspector resource (not MiniBrowser)
mkdir -p "${S}/usr/share/wpe-webkit-2.0"
cp -a "${WPE_PREFIX}/share/wpe-webkit-2.0/inspector.gresource" \
      "${S}/usr/share/wpe-webkit-2.0/"
if [ -d "${WPE_PREFIX}/share/wpe-webkit-2.0/build-config" ]; then
    stage_cp "${WPE_PREFIX}/share/wpe-webkit-2.0/build-config" /usr/share/wpe-webkit-2.0 "$S"
fi

# devel headers and pkg-config
stage_cp "${WPE_PREFIX}/include/wpe-webkit-2.0"            /usr/include "$S"
mkdir -p "${S}/usr/lib64/pkgconfig"
for pc in wpe-webkit-2.0.pc wpe-web-process-extension-2.0.pc; do
    cp -a "${WPE_PREFIX}/lib/pkgconfig/${pc}" "${S}/usr/lib64/pkgconfig/"
    sed -i "s|${WPE_PREFIX}|/usr|g"          "${S}/usr/lib64/pkgconfig/${pc}"
done

# libseccomp: libWPEWebKit links it unconditionally now that the bubblewrap
# sandbox is compiled in (ENABLE_BUBBLEWRAP_SANDBOX=ON), so it is a hard runtime
# dependency even when the sandbox is left disabled at runtime.  SFOS 5.1 ships
# libseccomp.so.2 (2.5.2), so this resolves on-device.
# NOTE: bwrap + xdg-dbus-proxy are NOT added as Requires here on purpose — they
# are only exec'd when the sandbox is actually enabled (ATLANTIC_ENABLE_SANDBOX=1),
# and hard-depending on packages that may be absent from SFOS repos would break
# the default (sandbox-off) install.  Provision them separately for the on-device
# sandbox test.
fpm_rpm wpewebkit2 "$LEGACY_WPEWEBKIT_VERSION" "WPE WebKit ${LEGACY_WPEWEBKIT_VERSION} for Sailfish OS" "$S" \
    --depends libwpe --depends libepoxy --depends wpebackend-fdo --depends libseccomp

# ===========================================================================
# 5. wpewebkit2-qt5
# ===========================================================================
echo "--- Staging wpewebkit2-qt5 ---"
S="${STAGING}/wpewebkit2-qt5"; rm -rf "$S"; mkdir -p "$S"

mkdir -p "${S}/usr/lib64/qt5/qml/org/wpewebkit/qtwpe"
cp -a "${WPE_PREFIX}/lib/qt5/qml/org/wpewebkit/qtwpe/libqtwpe.so" \
      "${S}/usr/lib64/qt5/qml/org/wpewebkit/qtwpe/"
cp -a "${WPE_PREFIX}/lib/qt5/qml/org/wpewebkit/qtwpe/qmldir" \
      "${S}/usr/lib64/qt5/qml/org/wpewebkit/qtwpe/"
maybe_patch_glibc_versions "${S}/usr/lib64/qt5/qml/org/wpewebkit/qtwpe/libqtwpe.so"
if ! patchelf --print-needed "${S}/usr/lib64/qt5/qml/org/wpewebkit/qtwpe/libqtwpe.so" | grep -qx 'libEGL.so.1'; then
    patchelf --add-needed libEGL.so.1 \
        "${S}/usr/lib64/qt5/qml/org/wpewebkit/qtwpe/libqtwpe.so"
fi
# Flat symlink so the browser binary can find libqtwpe.so via ldconfig
ln -sfn /usr/lib64/qt5/qml/org/wpewebkit/qtwpe/libqtwpe.so \
        "${S}/usr/lib64/libqtwpe.so"

fpm_rpm wpewebkit2-qt5 "$LEGACY_WPEWEBKIT_VERSION" "WPE WebKit Qt5 QML plugin for Sailfish OS" "$S" \
    --depends wpewebkit2

# ===========================================================================
# 6. wpe-sfos-compat  (compiled from source)
# ===========================================================================
# Compile the C compat shims + gather Ubuntu runtime libs into ${COMPAT_BUILD}.
# shellcheck source=scripts/stage-compat-shims.sh
. "${SCRIPT_DIR}/scripts/stage-compat-shims.sh"

echo "--- Staging wpe-sfos-compat ---"
S="${STAGING}/wpe-sfos-compat"; rm -rf "$S"; mkdir -p "$S"
mkdir -p "${S}/usr/lib64/wpe-compat"
# Copy all compat shims
for so in "${COMPAT_BUILD}"/*.so "${COMPAT_BUILD}"/*.so.[0-9]*; do
    [ -f "$so" ] && cp -a "$so" "${S}/usr/lib64/wpe-compat/"
done

# Create versioned symlinks for bundled runtime libs
(cd "${S}/usr/lib64/wpe-compat"
    ln -sfn libsoup-3.0.so.0.7.1    libsoup-3.0.so.0
    ln -sfn libsoup-3.0.so.0.7.1    libsoup-3.0.so
    ln -sfn libbrotlidec.so.1.1.0   libbrotlidec.so.1
    ln -sfn libbrotlicommon.so.1.1.0 libbrotlicommon.so.1
    ln -sfn libatomic.so.1.2.0      libatomic.so.1
    ln -sfn libjpeg.so.8.2.2        libjpeg.so.8
    ln -sfn libgbm.so.1.0.0         libgbm.so.1
)

# Keep shim preload/library-path scoped to Atlantic launcher/helper wrappers only.
# Global nemo session injection breaks unrelated services (e.g. PulseAudio).

# CPU governor repair: the Xperia 10 II vendor init leaves the big cluster
# (cpu4-7) stuck in "powersave" at 300 MHz, and Atlantic pins the browser +
# WPE helpers to that cluster. Ship a boot-time oneshot that revs it back up.
install -d -m 755 "${S}/usr/libexec/atlantic"
install -m 755 "${SCRIPT_DIR}/deploy/atlantic-cpu-governor.sh" \
    "${S}/usr/libexec/atlantic/atlantic-cpu-governor.sh"
install -d -m 755 "${S}/usr/lib/systemd/system"
install -m 644 "${SCRIPT_DIR}/deploy/atlantic-cpu-governor.service" \
    "${S}/usr/lib/systemd/system/atlantic-cpu-governor.service"

# Enable + start the governor service on install (idempotent; tolerant on a
# host without the unit running, e.g. during image builds).
FPM_POST_EXTRA="systemctl daemon-reload >/dev/null 2>&1 || :
systemctl enable atlantic-cpu-governor.service >/dev/null 2>&1 || :
systemctl start atlantic-cpu-governor.service >/dev/null 2>&1 || :" \
fpm_rpm wpe-sfos-compat "$WPE_SFOS_COMPAT_VERSION" "SFOS compatibility shims for WPE WebKit" "$S"

# ===========================================================================
# 7. atlantic-browser
# ===========================================================================
echo "--- Staging atlantic-browser ---"
S="${STAGING}/atlantic-browser"; rm -rf "$S"; mkdir -p "$S"

# Fetch filter lists, build the Brave/Rust engine, compile engine.dat.
# Sets CONTENT_BLOCKER_BUILD_DIR / CONTENT_BLOCKER_FETCH_DIR for staging below.
# shellcheck source=scripts/build-adblock-lists.sh
. "${SCRIPT_DIR}/scripts/build-adblock-lists.sh"

# Binary
mkdir -p "${S}/usr/bin"
cp -a "${BROWSER_SRC}/build_browser/atlantic-browser" "${S}/usr/bin/"

# WPE launcher environment wrapper
cat > "${S}/usr/bin/atlantic-browser-env" <<LAUNCHER
#!/bin/sh
. "${PACKAGE_RUNTIME_PREFIX}/libexec/atlantic/runtime-common.sh"
ATLANTIC_LD_PRELOAD='${WPE_COMPAT_PRELOAD}'
ATLANTIC_LD_LIBRARY_PATH='${WPE_HELPER_LIBRARY_PATH}'
atlantic_export_browser_env
# Pin to big cores (Kryo 260 Gold / A73 @ 2.0 GHz) on Snapdragon 665.
if command -v taskset >/dev/null 2>&1; then
    exec taskset -c 4-7 /usr/bin/atlantic-browser.bin "\$@"
else
    exec /usr/bin/atlantic-browser.bin "\$@"
fi
LAUNCHER
chmod 755 "${S}/usr/bin/atlantic-browser-env"

# WPE launcher wrapper (/usr/bin/atlantic-browser), used by the D-Bus
# activation services (org.atlantic.browser[.ui]).
#
# Primary confinement is Sailjail, applied by the .desktop entry
# (Exec=sailjail --profile=atlantic-browser ...) — that is the default launch
# path. bwrap is NOT used: it is incompatible with the libhybris/Adreno GPU
# stack. This wrapper additionally offers OPTIONAL firejail confinement for
# launches that do not go through Sailjail; it is OFF by default. Opt in with
# ATLANTIC_ENABLE_SAILJAIL=1.
cat > "${S}/usr/bin/atlantic-browser" <<LAUNCHER
#!/bin/sh
if [ "\${ATLANTIC_ENABLE_SAILJAIL:-0}" = "1" ] && [ -z "\${ATLANTIC_IN_SAILJAIL:-}" ] && command -v firejail >/dev/null 2>&1; then
    export ATLANTIC_IN_SAILJAIL=1
    exec firejail --quiet --profile=/etc/firejail/atlantic-browser.profile -- /usr/bin/atlantic-browser-env "\$@"
fi
exec /usr/bin/atlantic-browser-env "\$@"
LAUNCHER
chmod 755 "${S}/usr/bin/atlantic-browser"
cp -a "${BROWSER_SRC}/build_browser/atlantic-browser" "${S}/usr/bin/atlantic-browser.bin"

# firejail profile for the optional wrapper confinement above (used only when
# ATLANTIC_ENABLE_SAILJAIL=1, which is not the default). Installed to /etc/firejail.
mkdir -p "${S}/etc/firejail"
cp -a "${SCRIPT_DIR}/deploy/atlantic-browser.firejail.profile" \
      "${S}/etc/firejail/atlantic-browser.profile"

# Sailjail custom permission. The .desktop [X-Sailjail] Permissions list
# references "atlantic-browser", which sailjaild resolves from
# /etc/sailjail/permissions/atlantic-browser.permission. Without installing it
# the permission is unresolved (and the GPU/hybris noblacklists + Downloads
# whitelist it carries are missing) once sandboxing is enabled.
mkdir -p "${S}/etc/sailjail/permissions"
cp -a "${SCRIPT_DIR}/sailjail/atlantic-browser.permission" \
      "${S}/etc/sailjail/permissions/atlantic-browser.permission"

# libsailfishbrowser (versioned + symlinks — SONAME is libsailfishbrowser.so.1)
mkdir -p "${S}/usr/lib64"
cp -a "${BROWSER_SRC}/build_wpe/libsailfishbrowser.so.1.0.0" "${S}/usr/lib64/"
ln -sfn libsailfishbrowser.so.1.0.0 "${S}/usr/lib64/libsailfishbrowser.so.1.0"
ln -sfn libsailfishbrowser.so.1.0.0 "${S}/usr/lib64/libsailfishbrowser.so.1"
ln -sfn libsailfishbrowser.so.1.0.0 "${S}/usr/lib64/libsailfishbrowser.so"

# Adblock engine shared library
cp -a "${SCRIPT_DIR}/adblock-engine/target/release/libatlantic_adblock.so" "${S}/usr/lib64/"

# Adblock WebProcess extension — does the network blocking inside the WebProcess
# (the only place that sees every subresource). Links libatlantic_adblock so the
# Brave engine is pulled into the WebProcess. Built with the same SFOS toolchain
# as the qt5 plugin; installed where the UI process points the extensions dir.
echo "--- Building adblock web-process extension ---"
EXT_BUILD="${STAGING}/web-extension-build"
rm -rf "${EXT_BUILD}"
PKG_CONFIG_PATH="${WPE_PREFIX}/lib/pkgconfig:${WPE_PREFIX}/lib/aarch64-linux-gnu/pkgconfig" \
cmake -B "${EXT_BUILD}" -S "${SCRIPT_DIR}/web-extension" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="${SCRIPT_DIR}/sfos-toolchain.cmake" \
    -DCMAKE_BUILD_TYPE=Release \
    -DATLANTIC_ADBLOCK_LIBDIR="${SCRIPT_DIR}/adblock-engine/target/release"
ninja -C "${EXT_BUILD}"
mkdir -p "${S}/usr/lib64/atlantic-browser/web-extensions"
cp -a "${EXT_BUILD}/libatlantic-adblock-extension.so" \
      "${S}/usr/lib64/atlantic-browser/web-extensions/"
maybe_patch_glibc_versions "${S}/usr/lib64/atlantic-browser/web-extensions/libatlantic-adblock-extension.so"

# Adblock engine cache (FlatBuffers .dat)
mkdir -p "${S}/usr/share/atlantic-browser"
cp -a "${CONTENT_BLOCKER_BUILD_DIR}/engine.dat" \
      "${S}/usr/share/atlantic-browser/engine.dat"

# QML files
mkdir -p "${S}/usr/share/atlantic-browser"
cp -a "${BROWSER_SRC}/apps/browser/qml/browser.qml" "${S}/usr/share/atlantic-browser/"
cp -a "${BROWSER_SRC}/apps/browser/qml/browser-silica-main-smoke.qml" "${S}/usr/share/atlantic-browser/"
cp -a "${BROWSER_SRC}/apps/browser/qml/browser-minimal.qml" "${S}/usr/share/atlantic-browser/"
cp -a "${BROWSER_SRC}/apps/browser/qml/pages"        "${S}/usr/share/atlantic-browser/"
cp -a "${BROWSER_SRC}/apps/browser/qml/cover"        "${S}/usr/share/atlantic-browser/"
mkdir -p "${S}/usr/share/atlantic-browser/shared"
cp -a "${BROWSER_SRC}/apps/shared/"*.qml             "${S}/usr/share/atlantic-browser/shared/"
cp -a "${BROWSER_SRC}/apps/shared/"*.js              "${S}/usr/share/atlantic-browser/shared/"

# Data files
mkdir -p "${S}/usr/share/atlantic-browser/data"
cp -a "${BROWSER_SRC}/data/icon-launcher-browser.png" "${S}/usr/share/atlantic-browser/data/"

# Launcher icon
mkdir -p "${S}/usr/share/icons/hicolor/86x86/apps"
cp -a "${BROWSER_SRC}/data/icon-launcher-browser.png" \
    "${S}/usr/share/icons/hicolor/86x86/apps/icon-launcher-atlantic.png"

# Desktop file
mkdir -p "${S}/usr/share/applications"
cat > "${S}/usr/share/applications/atlantic-browser.desktop" << 'DESKTOP'
[Desktop Entry]
Type=Application
Name=Atlantic
X-MeeGo-Logical-Id=atlantic-browser-ap-name
X-MeeGo-Translation-Catalog=atlantic-browser
Icon=icon-launcher-atlantic
Exec=sailjail --profile=atlantic-browser -- /usr/bin/atlantic-browser-env %U
Comment=Atlantic Browser (WPE WebKit)
MimeType=text/html;application/xhtml+xml;application/xml;text/xml;x-scheme-handler/http;x-scheme-handler/https;
X-Maemo-Service=org.atlantic.browser.ui
X-Maemo-Object-Path=/ui
X-Maemo-Method=org.atlantic.browser.ui.openUrl

[X-Sailjail]
Permissions=Internet;Audio;WebView;UserDirs;atlantic-browser
OrganizationName=org.sailfishos
ApplicationName=browser
DESKTOP

# DBus service files
mkdir -p "${S}/usr/share/dbus-1/services"
cat > "${S}/usr/share/dbus-1/services/org.atlantic.browser.service" << 'DBUS'
[D-BUS Service]
Name=org.atlantic.browser
Exec=/usr/bin/atlantic-browser
DBUS
cat > "${S}/usr/share/dbus-1/services/org.atlantic.browser.ui.service" << 'DBUS'
[D-BUS Service]
Name=org.atlantic.browser.ui
Exec=/usr/bin/atlantic-browser
DBUS

# Translation
mkdir -p "${S}/usr/share/translations"
cp -a "${BROWSER_SRC}/build_browser/atlantic-browser_eng_en.qm" "${S}/usr/share/translations/"

# Sailjail profile
mkdir -p "${S}/etc/sailjail/applications"
cat > "${S}/etc/sailjail/applications/atlantic-browser.profile" << 'EOF'
[sailfish]
# Sailjail is the default launch path (.desktop Exec=sailjail). Sandbox
# ENFORCEMENT is enabled: the custom atlantic-browser permission supplies the
# GPU/hybris noblacklists + Downloads whitelist on top of Base/Internet/WebView
# (which cover SSL/DNS/fonts/transferengine). Base uses no private-dev, so the
# /dev/kgsl|ion|binder noblacklists apply. If WPE rendering/launch breaks,
# discover denied paths on device with `firejail --debug` / journalctl and add
# them to sailjail/atlantic-browser.permission.
Sandboxing=enabled

# Keep in sync with the .desktop [X-Sailjail] block. "atlantic-browser" pulls in
# the custom permission (GPU/hybris noblacklists) needed once sandboxing is on.
[X-Sailjail]
Permissions=Internet;Audio;WebView;UserDirs;atlantic-browser
OrganizationName=org.sailfishos
ApplicationName=browser
EOF

# GPU performance udev rule — Snapdragon 665 Adreno 610
# Power levels: 0=950 1=900 2=820 3=745 4=600 5=465 6=320 MHz
# Without a floor the GPU idles at 320 MHz; Skia tile rendering stalls on
# every scroll/repaint waiting for the clock to ramp back up.
mkdir -p "${S}/lib/udev/rules.d"
cat > "${S}/lib/udev/rules.d/99-atlantic-gpu.rules" << 'UDEV'
# Atlantic Browser: keep Adreno 610 GPU above 820 MHz for responsive rendering.
# Level 2=820MHz is a good perf/battery balance; level 0 would be 950MHz max.
SUBSYSTEM=="kgsl", KERNEL=="kgsl-3d0", ATTR{min_pwrlevel}="2"
UDEV

# Post-install: apply GPU boost immediately (udev rule handles reboots)
FPM_POST_EXTRA='[ -w /sys/class/kgsl/kgsl-3d0/min_pwrlevel ] && echo 2 > /sys/class/kgsl/kgsl-3d0/min_pwrlevel || :'
fpm_rpm atlantic-browser "$ATLANTIC_BROWSER_VERSION" "Atlantic Browser (WPE WebKit engine)" "$S" \
    --depends wpewebkit2 \
    --depends wpewebkit2-qt5 \
    --depends wpe-sfos-compat \
    --depends bubblewrap \
    --depends xdg-dbus-proxy \
    --depends firejail
unset FPM_POST_EXTRA

# ===========================================================================
echo ""
echo "All RPMs built successfully:"
ls -lh "$OUT"/*.rpm
