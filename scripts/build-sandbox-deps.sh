#!/bin/bash
set -euo pipefail

# build-sandbox-deps.sh — build the device-side executable the WPE bubblewrap
# sandbox exec's at runtime: bwrap (bubblewrap).
#
# xdg-dbus-proxy is NOT built here: SFOS ships it as a stock Jolla package
# (0.1.7+git1 in the 5.1.0.11 sysroot, at the /usr/bin/xdg-dbus-proxy path
# libWPEWebKit is compiled to exec).  We used to build and package our own,
# which only shadowed Jolla's.  atlantic-browser still Requires it.
#
# This is the binary baked into libWPEWebKit as BWRAP_EXECUTABLE (see
# scripts/build-webkit.sh; DBUS_PROXY_EXECUTABLE points at Jolla's).  It is built NATIVE
# (aarch64-on-aarch64) like the rest of the engine: the SFOS 5.1 runtime ships a
# newer glibc (2.41) / glib (2.86) / libcap than the Ubuntu 24.04 build host, so
# host-built binaries run forward-compatibly on-device, and the SFOS sysroot
# does not carry capability.h for a cross build anyway.
#
# Installed into ${WPE_PREFIX}/bin; build-rpms-native.sh stages them to /usr/bin.

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

# meson's built-in c_args come AFTER a project's own add_project_arguments, so
# appending a -Wno-error there is the only way to relax an upstream -Werror.
# The native file already defines c_args (CPU tuning); CFLAGS is ignored once it
# does, so read the list back out rather than restate the tuning flags here and
# let the two drift.
native_c_args() {
    python3 - "$@" <<'PYEOF'
import ast, configparser, os, sys
cfg = configparser.ConfigParser()
cfg.read(os.path.join(os.environ["BUILD_TOOLS"], "native-meson.ini"))
args = ast.literal_eval(cfg["built-in options"]["c_args"]) + list(sys.argv[1:])
print("-Dc_args=[%s]" % ",".join(repr(a) for a in args))
PYEOF
}

build_meson_release() {
    # $1 src dir, then meson extra args
    local src_dir="$1"; shift
    cd "${src_dir}"
    rm -rf build
    CC="ccache gcc" CXX="ccache g++" \
    meson setup build \
        --native-file "${BUILD_TOOLS}/native-meson.ini" \
        --prefix "${WPE_PREFIX}" \
        --buildtype release \
        "$@"
    ninja -C build -j"${NPROC}" install
}

echo ""
echo "--- Building sandbox runtime deps (bwrap) ---"

# ── bwrap (bubblewrap) ───────────────────────────────────────────────────────
_bwrap_stamp="${WPE_PREFIX}/bin/.bwrap-version"
if [ ! -x "${WPE_PREFIX}/bin/bwrap" ] || [ "$(cat "${_bwrap_stamp}" 2>/dev/null || true)" != "${BUBBLEWRAP_VERSION}" ]; then
    cd "${WORK}"
    if [ ! -d "bubblewrap-${BUBBLEWRAP_VERSION}" ]; then
        echo "  Downloading bubblewrap ${BUBBLEWRAP_VERSION}..."
        wget -q "https://github.com/containers/bubblewrap/releases/download/v${BUBBLEWRAP_VERSION}/bubblewrap-${BUBBLEWRAP_VERSION}.tar.xz" \
            -O "/tmp/bubblewrap-${BUBBLEWRAP_VERSION}.tar.xz"
        tar -xf "/tmp/bubblewrap-${BUBBLEWRAP_VERSION}.tar.xz" -C "${WORK}"
        rm -f "/tmp/bubblewrap-${BUBBLEWRAP_VERSION}.tar.xz"
    fi
    # No man/completions/tests. support_setuid defaults to false upstream since
    # 0.11.2, which compiles out the setuid path CVE-2026-41163 lives in; we do
    # not install setuid either way.
    #
    # -Wno-error=format-overflow: 0.11.2's overlay-mount error path passes
    # possibly-NULL args to a "%s" format, and GCC 13 on this host escalates
    # upstream's -Werror=format=2 over it. Error path only, and 0.11.0 built
    # clean, so this is a new upstream/GCC-13 interaction rather than something
    # we introduced. Still warns, just does not fail the build.
    build_meson_release "${WORK}/bubblewrap-${BUBBLEWRAP_VERSION}" \
        -Dman=disabled -Dselinux=disabled \
        -Dbash_completion=disabled -Dzsh_completion=disabled \
        -Dtests=false \
        "$(native_c_args -Wno-error=format-overflow)"
    printf '%s\n' "${BUBBLEWRAP_VERSION}" > "${_bwrap_stamp}"
    echo "  bwrap installed: $("${WPE_PREFIX}/bin/bwrap" --version)"
else
    echo "  bwrap already built (${BUBBLEWRAP_VERSION})."
fi
