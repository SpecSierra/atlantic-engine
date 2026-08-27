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

    # Write ldconfig scripts; FPM_{POST,PREUN,POSTUN}_EXTRA inject extra commands.
    #
    # Directory ownership: without --rpm-auto-add-directories RPM knows only the
    # files, so uninstalling leaves the now-empty /usr/libexec/atlantic and
    # friends behind. systemd's own directories are excluded — co-owning those
    # with the systemd package buys nothing and risks a file conflict.
    #
    # preun is where units get disabled. It must exist: `systemctl enable`
    # creates .wants symlinks under /etc that RPM does not own, so without a
    # matching disable an uninstall leaves them dangling and systemd reports
    # the unit as "not-found" forever. postun then reloads so systemd forgets
    # the units whose files have just been deleted.
    #
    # Enabling belongs in posttrans, not post. The .aio bundle Obsoletes the
    # split packages, and RPM erases an obsoleted package AFTER installing its
    # replacement — so a split->bundle upgrade would run the old package's
    # preun (disable) after the bundle's post (enable) and leave the units off.
    # posttrans runs once the whole transaction is done, so it always wins.
    local post="${STAGING}/post-${name}.sh" postun="${STAGING}/postun-${name}.sh"
    local preun="${STAGING}/preun-${name}.sh"
    local posttrans="${STAGING}/posttrans-${name}.sh"
    printf '#!/bin/sh\n/sbin/ldconfig || :\n%s\n' "${FPM_POST_EXTRA:-}" > "$post"
    printf '#!/bin/sh\n%s\n' "${FPM_PREUN_EXTRA:-:}" > "$preun"
    printf '#!/bin/sh\n/sbin/ldconfig || :\n%s\n' "${FPM_POSTUN_EXTRA:-}" > "$postun"
    printf '#!/bin/sh\n%s\n' "${FPM_POSTTRANS_EXTRA:-:}" > "$posttrans"

    echo "==> Building RPM: ${name}-${version}-${iteration}"
    fpm -s dir -t rpm \
        -n "$name" \
        -v "$version" \
        --iteration "${iteration}" \
        --architecture aarch64 \
        --rpm-summary "$summary" \
        --after-install "$post" \
        --before-remove "$preun" \
        --after-remove "$postun" \
        --rpm-posttrans "$posttrans" \
        --rpm-auto-add-directories \
        --rpm-auto-add-exclude-directories /usr/lib/systemd \
        --rpm-auto-add-exclude-directories /usr/lib/systemd/system \
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

# SQLCipher is NOT packaged here — the browser links Jolla's stock `sqlcipher`
# (a devel header from the sysroot at build time, the runtime package on-device).
# Shipping our own libsqlcipher collided with it (identical libsqlcipher.so.0).

# ===========================================================================
# 3b. Sandbox runtime executable (bwrap)
# ===========================================================================
# The device-side binary libWPEWebKit exec's when the bubblewrap sandbox is
# enabled (the compiled-in BWRAP_EXECUTABLE path is /usr/bin/bwrap).  Built by
# scripts/build-sandbox-deps.sh into ${WPE_PREFIX}/bin.  Packaged under its
# upstream name so atlantic-browser can Requires it; libcap is a core SFOS lib
# always present, so it is not listed as an explicit Requires here.
#
# The other half of the pair, xdg-dbus-proxy (DBUS_PROXY_EXECUTABLE =
# /usr/bin/xdg-dbus-proxy), is a stock Jolla package and is no longer built or
# packaged here — ours only shadowed theirs.  The Requires below still names it.
if [ -x "${WPE_PREFIX}/bin/bwrap" ]; then
    echo "--- Staging bubblewrap ---"
    S="${STAGING}/bubblewrap"; rm -rf "$S"; mkdir -p "${S}/usr/bin"
    cp -a "${WPE_PREFIX}/bin/bwrap" "${S}/usr/bin/bwrap"
    maybe_patch_glibc_versions "${S}/usr/bin/bwrap"
    fpm_rpm bubblewrap "$BUBBLEWRAP_VERSION" "Bubblewrap sandbox helper (for the WPE WebKit sandbox)" "$S"
else
    echo "WARNING: ${WPE_PREFIX}/bin/bwrap missing — skipping bubblewrap package (run scripts/build-sandbox-deps.sh)" >&2
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
install -m 644 "${SCRIPT_DIR}/deploy/pulse-client.conf" \
    "${S}${PACKAGE_RUNTIME_PREFIX}/libexec/atlantic/pulse-client.conf"

# Helper process launchers at ${PACKAGE_RUNTIME_PREFIX}/libexec/wpe-webkit-2.0 —
# the path WebKit spawns (libexecdir is baked to /opt/wpe-sfos). These USED to be
# shell-script wrappers (source runtime-common.sh + taskset, then exec the real
# ELF at ${ATLANTIC_WPE_HELPER_DIR}). That is INCOMPATIBLE with the Sailjail
# sandbox: firejail's --private-bin=<app> strips /usr/bin (and /bin) down to just
# the browser binary, so the wrapper's #!/bin/sh interpreter is gone and the
# spawn fails ENOENT (device-verified). Make them symlinks to the real ELFs so
# WebKit execs an ELF directly. The runtime env that the wrappers used to
# apply now comes from the environment they inherit:
#   - sandboxed (default): the per-app firejail profile's `env` directives
#     (see the atlantic-browser.profile generated below);
#   - unconfined (dev/ATLANTIC_SANDBOX=none): the /usr/bin/atlantic-browser
#     wrapper sets the env on the UI process; helpers inherit it.
# Deliberately NO cpu pin on either path any more. The old big-core pin
# (wrapper taskset 4-7 / profile `cpu 4,5,6,7`) was inherited by the helper
# ELFs, confining ALL browser work — JSC JIT/GC workers, Skia raster, the
# WebProcess main thread — to 4 of 8 cores while the little cluster idled.
# EAS up-migrates the hot threads to the big cores by itself (device A/B
# 2026-07-06: theverge DOMContentLoaded 8.7 s pinned + floor-stuck governor
# -> 2.0 s unpinned at full clock; the governor half of that fix now lives in
# sfos-qcom-boost).
mkdir -p "${S}${PACKAGE_RUNTIME_PREFIX}/libexec/wpe-webkit-2.0"
for helper in WPEWebProcess WPENetworkProcess WPEGPUProcess; do
    [ -e "${S}/usr/libexec/wpe-webkit-2.0/${helper}" ] || continue
    ln -sfn "${ATLANTIC_WPE_HELPER_DIR}/${helper}" \
        "${S}${PACKAGE_RUNTIME_PREFIX}/libexec/wpe-webkit-2.0/${helper}"
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
# NOTE: bwrap is NOT added as a Requires here on purpose — it
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

# GStreamer droid camera device provider — must live in the scanned plugin
# path (GST_PLUGIN_SYSTEM_PATH_1_0=/usr/lib64/gstreamer-1.0), not wpe-compat.
mkdir -p "${S}/usr/lib64/gstreamer-1.0"
cp -a "${COMPAT_BUILD}/gstreamer-1.0/libgstdroidcamdeviceprovider.so" \
      "${S}/usr/lib64/gstreamer-1.0/"
maybe_patch_glibc_versions "${S}/usr/lib64/gstreamer-1.0/libgstdroidcamdeviceprovider.so"

# Create versioned symlinks for bundled runtime libs
(cd "${S}/usr/lib64/wpe-compat"
    ln -sfn libsoup-3.0.so.0.7.1    libsoup-3.0.so.0
    ln -sfn libsoup-3.0.so.0.7.1    libsoup-3.0.so
    ln -sfn libbrotlidec.so.1.1.0   libbrotlidec.so.1
    ln -sfn libbrotlicommon.so.1.1.0 libbrotlicommon.so.1
    ln -sfn libatomic.so.1.2.0      libatomic.so.1
    ln -sfn libjpeg.so.8.2.2        libjpeg.so.8
    ln -sfn libgbm.so.1.0.0         libgbm.so.1
    ln -sfn libenchant-2.so.2.3.3   libenchant-2.so.2
    ln -sfn libhunspell-1.7.so.0.0.1 libhunspell-1.7.so.0
    ln -sfn libdav1d.so.7.0.0       libdav1d.so.7
    # libavif is source-built, so derive its soname from the real file rather
    # than hardcode the version (libavif.so.16.0.4 -> libavif.so.16 + libavif.so).
    avif_real="$(ls libavif.so.*.*.* 2>/dev/null | head -1)"
    if [ -n "${avif_real}" ]; then
        ln -sfn "${avif_real}" "${avif_real%.*.*}"   # -> libavif.so.16
        ln -sfn "${avif_real}" libavif.so
    fi
)

# Spellcheck support files: enchant loads its backend from the Ubuntu-baked
# module path, and hunspell finds dictionaries under /usr/share/hunspell.
install -d -m 755 "${S}/usr/lib/aarch64-linux-gnu/enchant-2" "${S}/usr/share/hunspell"
install -m 755 "${COMPAT_BUILD}/enchant-2/enchant_hunspell.so" \
    "${S}/usr/lib/aarch64-linux-gnu/enchant-2/enchant_hunspell.so"
install -m 644 "${COMPAT_BUILD}/hunspell/en_US.aff" "${COMPAT_BUILD}/hunspell/en_US.dic" \
    "${S}/usr/share/hunspell/"

# Keep shim preload/library-path scoped to Atlantic launcher/helper wrappers only.
# Global nemo session injection breaks unrelated services (e.g. PulseAudio).

# CPU governor repair, per-touch CPU boost and the GPU power floor all live in
# sfos-qcom-boost now (Requires, below). None of it is browser-specific, and
# shipping a second copy here would mean two units rewriting the same governor
# at boot with no ordering between them — each runs a load probe, so one can
# read a floor-stuck frequency caused by the other's rewrite and escalate the
# cluster to "performance" permanently.
install -d -m 755 "${S}/usr/libexec/atlantic"
install -d -m 755 "${S}/usr/lib/systemd/system"

# Boot-time oneshot: enlarge compressed swap (extra zram) + create a
# memory-contained cgroup for the browser so a heavy page (reddit) can't
# OOM-crash the phone. Device profiling proved reddit is memory-bound, not
# paint-bound (system MemAvailable cratered to ~344 MB on scroll).
install -m 755 "${SCRIPT_DIR}/deploy/atlantic-browser-memory.sh" \
    "${S}/usr/libexec/atlantic/atlantic-browser-memory.sh"
install -m 644 "${SCRIPT_DIR}/deploy/atlantic-browser-memory.service" \
    "${S}/usr/lib/systemd/system/atlantic-browser-memory.service"

# Periodic low-memory reclaim: the seine vendor kernel leaks pages into
# driver pools (ION pool + the "Bad rss-counter idx:4" unaccounted pool)
# whose shrinkers never fire on their own — device-measured 1.6 GB recovered
# by a manual drop_caches after heavy browser use. The timer pokes the
# shrinkers whenever MemFree runs low; self-gated to < 6 GB RAM devices.
install -m 755 "${SCRIPT_DIR}/deploy/atlantic-memory-reclaim.sh" \
    "${S}/usr/libexec/atlantic/atlantic-memory-reclaim.sh"
install -m 644 "${SCRIPT_DIR}/deploy/atlantic-memory-reclaim.service" \
    "${S}/usr/lib/systemd/system/atlantic-memory-reclaim.service"
install -m 644 "${SCRIPT_DIR}/deploy/atlantic-memory-reclaim.timer" \
    "${S}/usr/lib/systemd/system/atlantic-memory-reclaim.timer"

# Enable + start the boot oneshots and the reclaim timer on install
# (idempotent; tolerant on a host without the unit running, e.g. during
# image builds).
#
# On removal ($1 = 0; an upgrade passes 1 and must leave the services running)
# the units are disabled again, which is what deletes the .wants symlinks that
# `systemctl enable` put under /etc. RPM never owned those, so skipping this
# leaves them dangling and systemd lists the unit as "not-found" for good.
#
# The rm heals devices carrying atlantic-cpu-governor.service: Atlantic's own
# governor unit moved to sfos-qcom-boost in 709af98, and installs older than
# that kept an enable symlink no later package could ever clean up, since
# nothing still ships a unit by that name to disable.
FPM_POSTTRANS_EXTRA="rm -f /etc/systemd/system/*.target.wants/atlantic-cpu-governor.service >/dev/null 2>&1 || :
systemctl daemon-reload >/dev/null 2>&1 || :
systemctl enable atlantic-browser-memory.service >/dev/null 2>&1 || :
systemctl start atlantic-browser-memory.service >/dev/null 2>&1 || :
systemctl enable atlantic-memory-reclaim.timer >/dev/null 2>&1 || :
systemctl start atlantic-memory-reclaim.timer >/dev/null 2>&1 || :" \
FPM_PREUN_EXTRA="if [ \"\$1\" = 0 ]; then
    systemctl disable --now atlantic-memory-reclaim.timer >/dev/null 2>&1 || :
    systemctl disable --now atlantic-memory-reclaim.service >/dev/null 2>&1 || :
    systemctl disable --now atlantic-browser-memory.service >/dev/null 2>&1 || :
fi" \
FPM_POSTUN_EXTRA="systemctl daemon-reload >/dev/null 2>&1 || :" \
fpm_rpm wpe-sfos-compat "$WPE_SFOS_COMPAT_VERSION" "SFOS compatibility shims for WPE WebKit" "$S" \
    --depends sfos-qcom-boost

# ===========================================================================
# 7. atlantic-browser
# ===========================================================================
echo "--- Staging atlantic-browser ---"
S="${STAGING}/atlantic-browser"; rm -rf "$S"; mkdir -p "$S"

# Fetch filter lists, build the Brave/Rust engine, compile engine.dat.
# Sets CONTENT_BLOCKER_BUILD_DIR / CONTENT_BLOCKER_FETCH_DIR for staging below.
# shellcheck source=scripts/build-adblock-lists.sh
. "${SCRIPT_DIR}/scripts/build-adblock-lists.sh"

# Stage the filter payload for GitHub Pages publish (…/adblock/ next to the
# rpm repo) — the on-device list updater downloads these between releases.
if [ -n "${ARTIFACT_ROOT:-}" ]; then
    mkdir -p "${ARTIFACT_ROOT}/adblock"
    cp -a "${CONTENT_BLOCKER_BUILD_DIR}/engine.dat" \
          "${CONTENT_BLOCKER_BUILD_DIR}/adblock-resources.json" \
          "${CONTENT_BLOCKER_BUILD_DIR}/engine.version" \
          "${ARTIFACT_ROOT}/adblock/"
fi

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
# No CPU pin (was: taskset -c 4-7). The helper ELFs inherit the mask, so the
# pin confined the WHOLE browser — JSC JIT/GC workers, Skia raster, WebProcess
# main — to 4 of 8 cores while the little cluster idled. EAS up-migrates the
# hot threads to the big cores on its own; device A/B 2026-07-06: theverge
# DOMContentLoaded 8.7 s pinned (+ floor-stuck governor) -> 2.0 s unpinned.
exec /usr/bin/atlantic-browser.bin "\$@"
LAUNCHER
chmod 755 "${S}/usr/bin/atlantic-browser-env"

# WPE launcher wrapper (/usr/bin/atlantic-browser) — UNCONFINED dev/fallback
# entry only. The shipped launch path is sandboxed: the .desktop and the D-Bus
# .service files invoke `sailjail -p atlantic-browser.desktop
# /usr/bin/atlantic-browser.bin` directly (sailjail rejects shell scripts, so it
# cannot go through this wrapper), and the runtime env is supplied inside the
# jail by the generated per-app profile. This wrapper is kept so a developer can
# still run the browser unconfined (`/usr/bin/atlantic-browser`) — it sets the
# same env; the helper ELFs inherit it. No CPU pin here either (see
# atlantic-browser-env above).
cat > "${S}/usr/bin/atlantic-browser" <<LAUNCHER
#!/bin/sh
. "${PACKAGE_RUNTIME_PREFIX}/libexec/atlantic/runtime-common.sh"
ATLANTIC_LD_PRELOAD='${WPE_COMPAT_PRELOAD}'
ATLANTIC_LD_LIBRARY_PATH='${WPE_HELPER_LIBRARY_PATH}'
atlantic_export_browser_env
exec /usr/bin/atlantic-browser.bin "\$@"
LAUNCHER
chmod 755 "${S}/usr/bin/atlantic-browser"
cp -a "${BROWSER_SRC}/build_browser/atlantic-browser" "${S}/usr/bin/atlantic-browser.bin"

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

# Adblock engine cache (FlatBuffers .dat) + scriptlet/redirect resources
# (resources are not part of the serialized engine; loaded at runtime by both
# the UI-process AdBlockEngine and the WebProcess extension)
mkdir -p "${S}/usr/share/atlantic-browser"
cp -a "${CONTENT_BLOCKER_BUILD_DIR}/engine.dat" \
      "${S}/usr/share/atlantic-browser/engine.dat"
cp -a "${CONTENT_BLOCKER_BUILD_DIR}/adblock-resources.json" \
      "${S}/usr/share/atlantic-browser/adblock-resources.json"
cp -a "${CONTENT_BLOCKER_BUILD_DIR}/engine.version" \
      "${S}/usr/share/atlantic-browser/engine.version"
# DuckDuckGo autoconsent bundle — injected by the browser as a document-start
# user script to auto-reject CMP cookie banners
cp -a "${CONTENT_BLOCKER_BUILD_DIR}/autoconsent.js" \
      "${S}/usr/share/atlantic-browser/autoconsent.js"

# QML files
mkdir -p "${S}/usr/share/atlantic-browser"
cp -a "${BROWSER_SRC}/apps/browser/qml/browser.qml" "${S}/usr/share/atlantic-browser/"
cp -a "${BROWSER_SRC}/apps/browser/qml/browser-silica-main-smoke.qml" "${S}/usr/share/atlantic-browser/"
cp -a "${BROWSER_SRC}/apps/browser/qml/browser-minimal.qml" "${S}/usr/share/atlantic-browser/"
cp -a "${BROWSER_SRC}/apps/browser/qml/pages"        "${S}/usr/share/atlantic-browser/"
cp -a "${BROWSER_SRC}/apps/browser/qml/cover"        "${S}/usr/share/atlantic-browser/"
# Our own icon-m-* glyphs; the pages reach them as ../icons/, which resolves the
# same in the source tree and in the installed layout.
cp -a "${BROWSER_SRC}/apps/browser/qml/icons"        "${S}/usr/share/atlantic-browser/"
mkdir -p "${S}/usr/share/atlantic-browser/shared"
cp -a "${BROWSER_SRC}/apps/shared/"*.qml             "${S}/usr/share/atlantic-browser/shared/"
cp -a "${BROWSER_SRC}/apps/shared/"*.js              "${S}/usr/share/atlantic-browser/shared/"

# Data files
mkdir -p "${S}/usr/share/atlantic-browser/data"
cp -a "${BROWSER_SRC}/data/icon-launcher-browser.png" "${S}/usr/share/atlantic-browser/data/"

# Search engines shipped by the browser (beyond the mozembedlite system set)
# Curated extension catalog for the store page; the packages themselves are
# downloaded from addons.mozilla.org at runtime, nothing is mirrored here.
cp -a "${BROWSER_SRC}/data/extension-catalog.json" "${S}/usr/share/atlantic-browser/"

mkdir -p "${S}/usr/share/atlantic-browser/searchEngines"
cp -a "${BROWSER_SRC}/data/searchEngines/"*.xml "${S}/usr/share/atlantic-browser/searchEngines/"

# Launcher icon
mkdir -p "${S}/usr/share/icons/hicolor/86x86/apps"
cp -a "${BROWSER_SRC}/data/icon-launcher-browser.png" \
    "${S}/usr/share/icons/hicolor/86x86/apps/icon-launcher-atlantic.png"

# Desktop file — launches the browser INSIDE the Sailjail sandbox, boosterless.
# The Exec self-references this desktop (like stock jolla-gallery/jolla-notes):
# `sailjail -p <desktop> <elf>`. sailjail validates that the launched ELF appears
# in this desktop's Exec line and reads the [X-Sailjail] block for permissions;
# the whole browser (UI + WPEWebProcess + WPENetworkProcess) then runs confined
# (device-verified: seccomp + nonewprivs + cpu 4-7). Design notes:
#  - Exec MUST target the ELF /usr/bin/atlantic-browser.bin. sailjail rejects
#    shell scripts ("is not elf binary"), so the /usr/bin/atlantic-browser env
#    wrapper CANNOT be the sandbox entry. The runtime env is injected by the
#    per-app firejail profile below instead (firejail scrubs inherited LD_* and
#    --private-bin strips /bin/sh, so no wrapper can carry env into the jail).
#  - NO X-Maemo-Service: that key makes lipstick D-Bus-ACTIVATE the browser, so
#    dbus-daemon runs the .service Exec UNCONFINED, bypassing sailjail — this was
#    the "only the booster got isolated" bug. Removed so lipstick runs Exec
#    (= sailjail) directly.
#  - OrganizationName=org.atlantic + a UNIQUE ApplicationName (NOT "browser",
#    which stock sailfish-browser already claims — the collision makes sailjaild
#    silently force OrganizationName back to org.sailfishos). This lets the
#    sandbox dbus filter permit the browser to own org.atlantic.browser[.ui]
#    (added via dbus-user.own in the profile) → single-instance + openUrl work.
#  - The custom "atlantic-browser" permission is gone from Permissions: sailjaild
#    strips unknown permissions anyway; its GPU/hybris noblacklists + Downloads
#    whitelist moved into the per-app profile.
mkdir -p "${S}/usr/share/applications"
cat > "${S}/usr/share/applications/atlantic-browser.desktop" << 'DESKTOP'
[Desktop Entry]
Type=Application
Name=Atlantic
X-MeeGo-Logical-Id=atlantic-browser-ap-name
X-MeeGo-Translation-Catalog=atlantic-browser
Icon=icon-launcher-atlantic
Exec=/usr/bin/sailjail -p atlantic-browser.desktop /usr/bin/atlantic-browser.bin %U
Comment=Atlantic Browser (WPE WebKit)
MimeType=text/html;application/xhtml+xml;application/xml;text/xml;x-scheme-handler/http;x-scheme-handler/https;

[X-Sailjail]
Permissions=Internet;Audio;Camera;Microphone;WebView;UserDirs;MediaIndexing;RemovableMedia
OrganizationName=org.atlantic
ApplicationName=atlanticbrowser
DESKTOP

# DBus service files — external "open link in browser" activations. Route the
# cold start through sailjail so an activation when no instance is running still
# lands confined; a running instance owns org.atlantic.browser.ui and handles
# the call in-process (permissions must already be granted via the launcher tap).
mkdir -p "${S}/usr/share/dbus-1/services"
cat > "${S}/usr/share/dbus-1/services/org.atlantic.browser.service" << 'DBUS'
[D-BUS Service]
Name=org.atlantic.browser
Exec=/usr/bin/sailjail -p atlantic-browser.desktop /usr/bin/atlantic-browser.bin
DBUS
cat > "${S}/usr/share/dbus-1/services/org.atlantic.browser.ui.service" << 'DBUS'
[D-BUS Service]
Name=org.atlantic.browser.ui
Exec=/usr/bin/sailjail -p atlantic-browser.desktop /usr/bin/atlantic-browser.bin
DBUS

# Translation
mkdir -p "${S}/usr/share/translations"
cp -a "${BROWSER_SRC}/build_browser/atlantic-browser_eng_en.qm" "${S}/usr/share/translations/"

# Per-app Sailjail/firejail profile. sailjail auto-includes
# /etc/sailjail/permissions/<desktop-basename>.profile (atlantic-browser) as a
# firejail --profile. This carries everything the WPE runtime needs now that the
# shell wrappers can't cross the sandbox boundary:
#   - env <NAME=VALUE>: the full runtime env, GENERATED from runtime-common.sh
#     (single source of truth) so it never drifts. LD_LIBRARY_PATH here resolves
#     the wpe-compat libs incl. libjpeg.so.8 — no /usr/lib64 copy / ld.so.conf.
#   - NO `cpu` pin: firejail's cpu directive applies to the whole jail, so the
#     old `cpu 4,5,6,7` starved the browser onto 4 of 8 cores (helpers
#     included) — see the helper-launcher comment above for the device A/B.
#   - noblacklist: GPU/hybris nodes Base's disable-common.inc would hide.
#   - whitelist /usr/share/atlantic-browser: Base whitelist-LOCKS /usr/share.
#     (NEVER whitelist under /usr/lib64 — firejail then locks the whole dir and
#     hides libQt5*.)
#   - data dirs (the fork persists under org.sailfishos/browser) + Downloads.
#   - dbus-user.own: the browser's real bus names (under org.atlantic, which the
#     template's OrganizationName permits).
PROFILE_ENV_LINES="$(env -i sh -c '. "'"${SCRIPT_DIR}"'/deploy/runtime-common.sh"
export ATLANTIC_LD_PRELOAD="'"${WPE_COMPAT_PRELOAD}"'"
export ATLANTIC_LD_LIBRARY_PATH="'"${WPE_HELPER_LIBRARY_PATH}"'"
export XDG_RUNTIME_DIR=/run/user/100000
export PULSE_SERVER=unix:/run/user/100000/pulse/native
atlantic_export_browser_env
env' 2>/dev/null | grep -vE '^(PWD|_|SHLVL|HOME|PATH|OLDPWD|ATLANTIC_LD_PRELOAD|ATLANTIC_LD_LIBRARY_PATH)=' | LC_ALL=C sort | sed 's/^/env /')"

mkdir -p "${S}/etc/sailjail/permissions"
{
cat << 'PROFHDR'
# -*- mode: sh -*-
# Atlantic Browser — per-app Sailjail/firejail profile (auto-included by sailjail
# via the desktop basename). GENERATED by build-rpms-native.sh; the env block
# mirrors deploy/runtime-common.sh. See atlantic-browser.desktop for the design.

# GPU / hybris / Wayland nodes Base's disable-common.inc would blacklist.
noblacklist /opt/wpe-sfos
noblacklist /usr/libexec/wpe-webkit-2.0
noblacklist /usr/libexec/droid-hybris
noblacklist /usr/lib64/wpe-compat
noblacklist /dev/kgsl-3d0
noblacklist /dev/ion
noblacklist /dev/dri

# QML/assets (Base whitelist-locks /usr/share).
whitelist /usr/share/atlantic-browser

# Ambience wallpaper for the UI chrome / start page. Background.qml opens the
# active ambience image FILE directly (screen-pinned blurred wallpaper), and
# Base whitelist-locks /usr/share, so expose the stock ambiences plus a
# user-picked custom image cached in home. Without this the UI renders on black.
whitelist /usr/share/ambience
whitelist ${HOME}/.cache/ambienced
# Custom (photo-based) ambiences: ambienced copies the picked photo here and
# Ambience.source points straight at that jpg.
mkdir     ${HOME}/.local/share/ambienced/wallpapers
whitelist ${HOME}/.local/share/ambienced/wallpapers

# Browser data (the fork persists under org.sailfishos/browser) + config.
mkdir     ${HOME}/.local/share/org.sailfishos/browser
whitelist ${HOME}/.local/share/org.sailfishos/browser
mkdir     ${HOME}/.cache/org.sailfishos/browser
whitelist ${HOME}/.cache/org.sailfishos/browser
mkdir     ${HOME}/.config/org.sailfishos/browser
whitelist ${HOME}/.config/org.sailfishos/browser

# WebKit's default cache tree. The bounded HTTP disk cache
# (WEBKIT_URL_CACHE_DISK_CAPACITY_MB, webkit-http-cache.patch)
# and the CacheStorage / service-worker store live under ~/.cache/wpe; Base
# whitelist-locks ~/.cache, so without this every NetworkProcess cache write
# vanishes inside the jail and the HTTP cache silently stays empty.
mkdir     ${HOME}/.cache/wpe
whitelist ${HOME}/.cache/wpe
mkdir     ${HOME}/.config/atlantic-browser
whitelist ${HOME}/.config/atlantic-browser

# Downloads.
mkdir     ${HOME}/Downloads
whitelist ${HOME}/Downloads
whitelist ${HOME}/android_storage/Download

# Bus names the browser owns (single-instance + external openUrl).
dbus-user.own org.atlantic.browser
dbus-user.own org.atlantic.browser.ui

# Popup-menu "Downloads" opens Settings > Transfers (same rule as the stock
# sailfish-browser profile); without it the dbus proxy drops the call silently.
dbus-user.call com.jolla.settings=com.jolla.settings.ui.showTransfers@/com/jolla/settings/ui

# ── Runtime environment (generated — mirrors runtime-common.sh) ──────────────
PROFHDR
printf '%s\n' "${PROFILE_ENV_LINES}"
} > "${S}/etc/sailjail/permissions/atlantic-browser.profile"

# SFOS PulseAudio policy classification for WebKit audio streams — without it
# OHM corks browser audio ~0.5 s after each stream starts (see the file's
# header). Read by module-policy-enforcement at PA startup only, so first
# install needs a PulseAudio restart or reboot.
mkdir -p "${S}/etc/pulse/xpolicy.conf.d"
install -m 644 "${SCRIPT_DIR}/deploy/atlantic-audio-policy.conf" \
    "${S}/etc/pulse/xpolicy.conf.d/atlantic-audio.conf"

# The GPU power floor moved to sfos-qcom-boost with the rest of the tuning. Its
# udev rule derives the power level from the device's own frequency table
# instead of hardcoding 2, which only meant 820 MHz on an Adreno 610.
fpm_rpm atlantic-browser "$ATLANTIC_BROWSER_VERSION" "Atlantic Browser (WPE WebKit engine)" "$S" \
    --depends wpewebkit2 \
    --depends wpewebkit2-qt5 \
    --depends wpe-sfos-compat \
    --depends sqlcipher \
    --depends sailjail \
    --depends xdg-dbus-proxy \
    --depends firejail \
    --depends sfos-qcom-boost
unset FPM_POST_EXTRA

# ===========================================================================
# 8. atlantic-browser all-in-one bundle (OpenRepos single-RPM distribution)
# ===========================================================================
# Merges every Atlantic-built package into ONE rpm so OpenRepos users install
# a single file (300 MB size limit there — we're well under). Deliberately
# excludes bubblewrap: the bwrap sandbox is permanently disabled at runtime
# (Sailjail/firejail confines instead).  xdg-dbus-proxy was excluded here for the
# same reason it is no longer built at all — it is a stock Jolla package.
#
# The bundle goes to ${OUT}/bundle/ so CI signs/uploads it as an artifact but
# does NOT index it into the zypper repo (the dev channel keeps the split
# packages). Release gets a ".aio" suffix so its NEVRA differs from the split
# atlantic-browser rpm and rpm can tell the two apart.
# Device tuning (cpufreq governor repair, per-touch CPU boost, GPU power floor)
# lives in sfos-qcom-boost, not here: none of it is browser-specific, and two
# copies of the same sysfs writes would drift. Both this bundle and the split
# atlantic-browser rpm Require it; it is published alongside them on OpenRepos.
#   https://github.com/SpecSierra/sfos-qcom-boost
echo "--- Staging atlantic-browser bundle (single-RPM, OpenRepos) ---"
B="${STAGING}/atlantic-bundle"; rm -rf "$B"; mkdir -p "$B"
for pkg in libwpe libepoxy wpebackend-fdo wpewebkit2 wpewebkit2-qt5 \
           wpe-sfos-compat atlantic-browser; do
    cp -a "${STAGING}/${pkg}/." "$B/"
done

# The memory oneshot SHIPS in the bundle; its safety comes from a self-gate
# (atlantic-browser-memory exits untouched on >= 6 GB RAM devices) rather than
# from dropping it.
#
# The CPU governor repair used to ship here too, and dropping it once cost every
# Xperia 10 II .aio user 48% of their achievable clock (device-proven
# 2026-07-06: theverge DCL 8.7 s floor-stuck -> 2.0 s repaired). It is still
# applied — sfos-qcom-boost carries it now, and the bundle Requires that
# package, so the repair reaches the same devices through a dependency instead
# of a second copy.

mkdir -p "${OUT}/bundle"
# Merged post-install: immediate GPU boost only (udev rule handles reboots;
# both are Adreno-gated so they no-op on other SoCs).
# Subshell keeps the OUT/RPM_ITERATION overrides from leaking out.
(
OUT="${OUT}/bundle"
RPM_ITERATION="${RPM_ITERATION:-1}.aio"
#
# Same enable/disable pairing as the split wpe-sfos-compat package, and it
# matters more here: this is the OpenRepos bundle, so it is what most users
# actually install and remove. See the comment there for why a missing preun
# strands .wants symlinks, and for the atlantic-cpu-governor.service heal.
FPM_POSTTRANS_EXTRA="rm -f /etc/systemd/system/*.target.wants/atlantic-cpu-governor.service >/dev/null 2>&1 || :
systemctl daemon-reload >/dev/null 2>&1 || :
systemctl enable atlantic-browser-memory.service >/dev/null 2>&1 || :
systemctl start atlantic-browser-memory.service >/dev/null 2>&1 || :
systemctl enable atlantic-memory-reclaim.timer >/dev/null 2>&1 || :
systemctl start atlantic-memory-reclaim.timer >/dev/null 2>&1 || :"
FPM_PREUN_EXTRA="if [ \"\$1\" = 0 ]; then
    systemctl disable --now atlantic-memory-reclaim.timer >/dev/null 2>&1 || :
    systemctl disable --now atlantic-memory-reclaim.service >/dev/null 2>&1 || :
    systemctl disable --now atlantic-browser-memory.service >/dev/null 2>&1 || :
fi"
FPM_POSTUN_EXTRA="systemctl daemon-reload >/dev/null 2>&1 || :"
fpm_rpm atlantic-browser "$ATLANTIC_BROWSER_VERSION" "Atlantic Browser (WPE WebKit engine, all-in-one)" "$B" \
    --depends sailjail \
    --depends firejail \
    --depends libseccomp \
    --depends sqlcipher \
    --provides wpewebkit2 --replaces wpewebkit2 \
    --provides wpewebkit2-qt5 --replaces wpewebkit2-qt5 \
    --provides wpe-sfos-compat --replaces wpe-sfos-compat \
    --provides libwpe --replaces libwpe \
    --provides libepoxy --replaces libepoxy \
    --provides wpebackend-fdo --replaces wpebackend-fdo \
    --depends sfos-qcom-boost
)

# ===========================================================================
echo ""
echo "All RPMs built successfully:"
ls -lh "$OUT"/*.rpm "$OUT"/bundle/*.rpm
