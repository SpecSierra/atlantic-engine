#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

PUBLIC_SFOS_BASE_VERSION="${PUBLIC_SFOS_BASE_VERSION:-5.1.0.11}"
LOCAL_SFOS_SOURCE_SYSROOT="${LOCAL_SFOS_SOURCE_SYSROOT:-/opt/sfos-sysroot}"

sysroot_version_of() {
    local root="$1"
    local os_release

    for os_release in "${root}/etc/os-release" "${root}/usr/lib/os-release"; do
        [ -f "${os_release}" ] || continue
        sed -n 's/^VERSION_ID=//p' "${os_release}" | tr -d '"'
        return 0
    done

    return 1
}

replace_sysroot_with_copy() {
    local source_root="$1"
    local dest_root="$2"

    mkdir -p "$(dirname "${dest_root}")"
    rm -rf "${dest_root}"
    cp -a "${source_root}" "${dest_root}"
}

# The public SFOS SDK target is a stock runtime image: it ships the runtime
# libraries (libgbm, libsoup3, transfer engine, dsme, ...) but NOT their -devel
# headers/.pc files, which the WPE Qt5 plugin and the browser UI need at compile
# time. Install them into the sysroot using its own zypper (aarch64 host -> no
# QEMU needed):
#   mesa-llvmpipe-libgbm-devel    -> gbm.h               (WPE Qt5 plugin)
#   libsoup3-devel                -> libsoup/soup.h      (WPE Qt5 plugin)
#   libnemotransferengine-qt5-devel -> nemotransferengine-qt5.pc (browser apps/lib)
#   libdsme-devel                 -> dsme_dbus_if.pc     (browser apps/lib)
# libsoup3-devel lands headers under /usr/include/libsoup-3.0/; expose them at the
# bare <libsoup/...> path too, because build-webkit.sh strips the libsoup-3.0
# Requires from wpe-webkit-2.0.pc so no -I .../libsoup-3.0 reaches the plugin.
SYSROOT_DEVEL_PACKAGES="${SYSROOT_DEVEL_PACKAGES:-mesa-llvmpipe-libgbm-devel libsoup3-devel libnemotransferengine-qt5-devel libdsme-devel}"

ensure_sysroot_devel() {
    local root="$1"
    local ver="${SFOS_SYSROOT_VERSION}"
    local repos="${root}/etc/zypp/repos.d"
    local base="https://releases.jolla.com"
    local arch="aarch64"
    local m

    if [ -f "${root}/usr/include/gbm.h" ] && [ -e "${root}/usr/include/libsoup/soup.h" ] \
       && [ -f "${root}/usr/lib64/pkgconfig/nemotransferengine-qt5.pc" ] \
       && [ -f "${root}/usr/lib64/pkgconfig/dsme_dbus_if.pc" ]; then
        echo "  Sysroot dev headers already present."
        return 0
    fi

    if [ ! -x "${root}/usr/bin/zypper" ]; then
        echo "ERROR: ${root} has no zypper; cannot install dev headers (${SYSROOT_DEVEL_PACKAGES})." >&2
        exit 1
    fi

    echo "  Installing dev headers into sysroot: ${SYSROOT_DEVEL_PACKAGES}"
    mkdir -p "${repos}"
    cat > "${repos}/atlantic_jolla.repo" <<EOF
[jolla]
name=jolla
enabled=1
gpgcheck=0
baseurl=${base}/releases/${ver}/jolla/${arch}/
EOF
    cat > "${repos}/atlantic_sdk.repo" <<EOF
[sdk]
name=sdk
enabled=1
gpgcheck=0
baseurl=${base}/releases/${ver}/sdk/${arch}/
EOF
    cat > "${repos}/atlantic_adaptation-common.repo" <<EOF
[adaptation-common]
name=adaptation-common
enabled=1
gpgcheck=0
baseurl=${base}/releases/${ver}/jolla-hw/adaptation-common/${arch}/
EOF

    cp -L /etc/resolv.conf "${root}/etc/resolv.conf" 2>/dev/null || true

    for m in proc sys dev; do
        mountpoint -q "${root}/${m}" || mount --bind "/${m}" "${root}/${m}"
    done
    trap 'for m in proc sys dev; do umount -lf "'"${root}"'/${m}" 2>/dev/null || true; done' EXIT

    chroot "${root}" /usr/bin/zypper --non-interactive --no-gpg-checks ref
    chroot "${root}" /usr/bin/zypper --non-interactive --no-gpg-checks in ${SYSROOT_DEVEL_PACKAGES}

    for m in proc sys dev; do umount -lf "${root}/${m}" 2>/dev/null || true; done
    trap - EXIT

    if [ -d "${root}/usr/include/libsoup-3.0/libsoup" ] && [ ! -e "${root}/usr/include/libsoup" ]; then
        ln -sfn libsoup-3.0/libsoup "${root}/usr/include/libsoup"
    fi

    if [ ! -f "${root}/usr/include/gbm.h" ] || [ ! -e "${root}/usr/include/libsoup/soup.h" ]; then
        echo "ERROR: dev headers still missing after install (need gbm.h and libsoup/soup.h)." >&2
        exit 1
    fi
    echo "  Sysroot dev headers installed."
}

echo ""
echo "--- [0] Setting up 64 GB swap ---"
if ! swapon --show | grep -q /swapfile; then
    fallocate -l 64G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo "Swap activated: $(free -h | awk '/Swap/{print $2}')"
else
    echo "Swap already active"
fi

echo ""
echo "--- [1] Installing build dependencies ---"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y \
    build-essential gcc g++ cmake ninja-build meson \
    ccache \
    clang-18 lld-18 llvm-18 \
    pkg-config python3 python3-pip \
    git curl wget p7zip-full \
    patchelf bzip2 xz-utils \
    ruby ruby-dev rpm \
    libglib2.0-dev \
    libwayland-dev libxkbcommon-dev \
    libegl-dev libgles2-mesa-dev \
    libharfbuzz-dev libfontconfig1-dev libfreetype6-dev \
    libicu-dev libsqlite3-dev libxml2-dev libxslt1-dev \
    libpng-dev libjpeg-dev libwebp-dev zlib1g-dev \
    libdrm-dev libgbm-dev libcap-dev \
    libsoup-3.0-dev libsystemd-dev \
    libgcrypt20-dev libgpg-error-dev \
    libtasn1-6-dev \
    libwoff-dev libopenjp2-7-dev \
    liblcms2-dev libhyphen-dev \
    libcairo2-dev \
    libudev-dev libinput-dev \
    wayland-protocols \
    libmanette-0.2-dev \
    unifdef gperf flex bison perl \
    libseccomp-dev bubblewrap xdg-dbus-proxy \
    2>/dev/null

gem list fpm | grep -q fpm || gem install --no-document fpm

if command -v ccache >/dev/null 2>&1; then
    mkdir -p "${CCACHE_DIR}"
    ccache --set-config=cache_dir="${CCACHE_DIR}" >/dev/null
    ccache --set-config=max_size="${CCACHE_MAXSIZE}" >/dev/null
    ccache --set-config=base_dir="${CCACHE_BASEDIR}" >/dev/null
    if [ "${CCACHE_NOHASHDIR}" = "1" ]; then
        ccache --set-config=hash_dir=false >/dev/null
    else
        ccache --set-config=hash_dir=true >/dev/null
    fi
    ccache --set-config=compression=true >/dev/null
    ccache --set-config=compiler_check=content >/dev/null
fi

echo "Build tools ready."

echo ""
echo "--- [2] Setting up SFOS ${SFOS_SYSROOT_VERSION} aarch64 sysroot ---"
current_sysroot_version="$(sysroot_version_of "${SYSROOT}" || true)"
local_source_version=""
if [ "${LOCAL_SFOS_SOURCE_SYSROOT}" != "${SYSROOT}" ]; then
    local_source_version="$(sysroot_version_of "${LOCAL_SFOS_SOURCE_SYSROOT}" || true)"
fi

if [ -d "${SYSROOT}/usr/include" ] && [ "${current_sysroot_version}" = "${SFOS_SYSROOT_VERSION}" ]; then
    echo "  Sysroot already present at target version ${current_sysroot_version}."
elif [ -n "${local_source_version}" ] && [ "${local_source_version}" = "${SFOS_SYSROOT_VERSION}" ]; then
    echo "  Seeding sysroot from local ${LOCAL_SFOS_SOURCE_SYSROOT} (${local_source_version})..."
    replace_sysroot_with_copy "${LOCAL_SFOS_SOURCE_SYSROOT}" "${SYSROOT}"
    echo "  Sysroot ready from local updated source."
else
    if [ ! -d "${SYSROOT}/usr/include" ]; then
        mkdir -p "${SYSROOT}"
        sysroot_url="https://releases.sailfishos.org/sdk/targets/Sailfish_OS-${PUBLIC_SFOS_BASE_VERSION}-Sailfish_SDK_Target-aarch64.tar.7z"
        sysroot_tar="/tmp/Sailfish_OS-${PUBLIC_SFOS_BASE_VERSION}-Sailfish_SDK_Target-aarch64.tar"
        echo "  Downloading public base sysroot ${PUBLIC_SFOS_BASE_VERSION}..."
        curl -L --progress-bar "${sysroot_url}" -o /tmp/sfos-sysroot.tar.7z
        echo "  Extracting..."
        cd "${SYSROOT}"
        7z x /tmp/sfos-sysroot.tar.7z -so | tar -x --numeric-owner 2>/dev/null || {
            7z e /tmp/sfos-sysroot.tar.7z -o/tmp -y
            tar -xf "${sysroot_tar}" -C "${SYSROOT}" --numeric-owner
        }
        rm -f /tmp/sfos-sysroot.tar.7z "${sysroot_tar}"
    else
        echo "  Existing sysroot version is ${current_sysroot_version:-unknown}; keeping it for validation."
    fi

    current_sysroot_version="$(sysroot_version_of "${SYSROOT}" || true)"
    if [ "${current_sysroot_version}" != "${SFOS_SYSROOT_VERSION}" ]; then
        echo "ERROR: sysroot at ${SYSROOT} is ${current_sysroot_version:-unknown}, but ${SFOS_SYSROOT_VERSION} is required." >&2
        echo "       The public SDK target downloaded was ${PUBLIC_SFOS_BASE_VERSION}; set PUBLIC_SFOS_BASE_VERSION to match SFOS_SYSROOT_VERSION (${SFOS_SYSROOT_VERSION}), or provide a matching sysroot source (for example ${LOCAL_SFOS_SOURCE_SYSROOT}) to seed CI builds." >&2
        exit 1
    fi

    echo "  Sysroot ready."
fi

# Stock SDK targets lack the -devel headers the WPE Qt5 plugin compiles against.
ensure_sysroot_devel "${SYSROOT}"

echo ""
echo "--- [3] Cloning repositories ---"
mkdir -p "${WORK}"

if [ ! -d "${BUILD_TOOLS}/.git" ]; then
    git clone https://github.com/SpecSierra/atlantic-engine "${BUILD_TOOLS}"
else
    echo "  atlantic-engine already cloned"
fi

if [ ! -d "${BROWSER_SRC}/.git" ]; then
    git clone https://github.com/SpecSierra/atlantic-browser "${BROWSER_SRC}"
else
    echo "  atlantic-browser already cloned"
fi

mkdir -p "${WPE_PREFIX}"
