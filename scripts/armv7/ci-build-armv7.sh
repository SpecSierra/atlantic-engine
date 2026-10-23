#!/bin/bash
# The armv7hl build: runs scripts/ci-build.sh, unchanged, inside a 32-bit
# Ubuntu 24.04 (armhf) chroot on the aarch64 build host.
#
# The host's Neoverse-N1 cores and its kernel (CONFIG_COMPAT) run 32-bit ARM
# code natively, so this is not emulation: under `setarch linux32` the chroot is
# an ordinary armhf machine, and the build does there what the aarch64 build
# does on the host. It compiles against Ubuntu's armhf libraries and the armv7hl
# SFOS sysroot (scripts/arch.sh has the per-architecture values). That is also
# how Debian builds its own 32-bit ARM packages, WebKit included.
#
# Run as root (the workflow uses sudo), with the same environment as
# ci-build.sh: BUILD_TOOLS, BROWSER_SRC, WORK, CI_ROOT, CI_CACHE_ROOT, SYSROOT,
# WPE_PREFIX, OUT, STAGING, ARTIFACT_ROOT, CCACHE_*, RPM_ITERATION, ...
# The chroot itself lives in ARMHF_CHROOT and is made once, then reused.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHROOT="${ARMHF_CHROOT:-/opt/github-runner/cache/atlantic-armv7/armhf-noble}"
UBUNTU_SUITE="${UBUNTU_SUITE:-noble}"
UBUNTU_MIRROR="${UBUNTU_MIRROR:-http://ports.ubuntu.com/ubuntu-ports}"

if [ "$(id -u)" != "0" ]; then
    echo "ERROR: run as root (debootstrap, mounts, chroot)" >&2
    exit 1
fi
if ! setarch linux32 true 2>/dev/null; then
    echo "ERROR: this host cannot run 32-bit code (setarch linux32 failed)" >&2
    exit 1
fi

# ── The chroot, made once ───────────────────────────────────────────────────
if [ ! -x "${CHROOT}/usr/bin/apt-get" ]; then
    echo "--- Creating the armhf ${UBUNTU_SUITE} chroot in ${CHROOT} ---"
    command -v debootstrap >/dev/null || { apt-get update -qq; apt-get install -y debootstrap; }
    rm -rf "${CHROOT}"
    mkdir -p "${CHROOT}"
    setarch linux32 debootstrap --arch=armhf --variant=buildd \
        --components=main,universe "${UBUNTU_SUITE}" "${CHROOT}" "${UBUNTU_MIRROR}"
fi
# Written on every run, not only at creation: debootstrap lists the release
# pocket alone, and without -updates the copied runtime libs stay at release
# versions (mesa 24.0.5's libgbm links libxcb-randr, which SFOS lacks).
cat > "${CHROOT}/etc/apt/sources.list" <<EOF
deb ${UBUNTU_MIRROR} ${UBUNTU_SUITE} main universe
deb ${UBUNTU_MIRROR} ${UBUNTU_SUITE}-updates main universe
deb ${UBUNTU_MIRROR} ${UBUNTU_SUITE}-security main universe
EOF

# ── Mounts: the kernel's, and the build's directories at the same paths ─────
mounted=()
cleanup() {
    local i
    for (( i=${#mounted[@]}-1; i>=0; i-- )); do
        umount -lf "${mounted[$i]}" 2>/dev/null || true
    done
}
trap cleanup EXIT

bind() {
    local src="$1" dst="${CHROOT}$1"
    mkdir -p "${src}" "${dst}"
    mountpoint -q "${dst}" || { mount --bind "${src}" "${dst}"; mounted+=("${dst}"); }
}

for m in /proc /sys /dev /dev/pts; do
    mkdir -p "${CHROOT}${m}"
    mountpoint -q "${CHROOT}${m}" || { mount --bind "${m}" "${CHROOT}${m}"; mounted+=("${CHROOT}${m}"); }
done
cp -L /etc/resolv.conf "${CHROOT}/etc/resolv.conf"

work="$(realpath -m "${WORK}")"
bind "${work}"
bind "$(realpath -m "${CI_ROOT}")"
bind "$(realpath -m "${CI_CACHE_ROOT}")"
bind "$(realpath -m "$(dirname "${SYSROOT}")")"
bind "$(realpath -m "${CCACHE_DIR}")"
case "$(realpath -m "${BUILD_TOOLS}")" in
    "${work}"/*) ;;
    *) bind "$(realpath -m "${BUILD_TOOLS}")" ;;
esac
case "$(realpath -m "${BROWSER_SRC}")" in
    "${work}"/*) ;;
    *) bind "$(realpath -m "${BROWSER_SRC}")" ;;
esac
case "$(realpath -m "${ARTIFACT_ROOT}")" in
    "${work}"/*) ;;
    *) bind "$(realpath -m "${ARTIFACT_ROOT}")" ;;
esac

in_chroot() {
    setarch linux32 chroot "${CHROOT}" /usr/bin/env -i \
        HOME=/root LANG=C.UTF-8 DEBIAN_FRONTEND=noninteractive \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        "$@"
}

# ── What ci-build.sh needs before bootstrap-host.sh installs the rest ───────
in_chroot sh -c 'apt-get update -qq && apt-get dist-upgrade -y -qq >/dev/null && apt-get install -y -qq ca-certificates curl wget git ccache build-essential python3 p7zip-full xz-utils >/dev/null'
if ! in_chroot sh -c '[ -x /root/.cargo/bin/cargo ]'; then
    echo "--- Installing Rust (armv7) in the chroot ---"
    in_chroot sh -c 'curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable'
fi
in_chroot sh -c '/root/.cargo/bin/rustup update stable >/dev/null 2>&1 || true'

echo "--- Building armv7hl in the chroot ($(in_chroot uname -m)) ---"
pass=()
for v in WORK BUILD_TOOLS BROWSER_SRC PUBLIC_SFOS_BASE_VERSION LOCAL_SFOS_SOURCE_SYSROOT \
         CI_ROOT CI_CACHE_ROOT WPE_PREFIX SYSROOT OUT STAGING ARTIFACT_ROOT NPROC \
         CCACHE_DIR CCACHE_MAXSIZE CCACHE_BASEDIR CCACHE_NOHASHDIR RPM_ITERATION WEBKIT_COMPILER; do
    [ -n "${!v+x}" ] && pass+=("${v}=${!v}")
done
in_chroot "${pass[@]}" ATL_ARCH=armv7hl ATL_SKIP_SWAP=1 \
    bash "$(realpath -m "${BUILD_TOOLS}")/scripts/ci-build.sh"
