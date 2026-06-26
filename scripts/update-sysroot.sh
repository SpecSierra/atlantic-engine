#!/bin/bash
# update-sysroot.sh — upgrade an SFOS aarch64 sysroot to a new release in-place
# Usage: sudo ./scripts/update-sysroot.sh [TARGET_VERSION] [SYSROOT_PATH]
#
# Example:
#   sudo ./scripts/update-sysroot.sh 5.1.0.11 /opt/github-runner/cache/sfos-sysroot-5.1.0.11
#
# Requires: running on aarch64 (no QEMU needed); internet access to releases.jolla.com
set -euo pipefail

TARGET_VERSION="${1:-5.1.0.11}"
SYSROOT="${2:-/opt/github-runner/cache/sfos-sysroot-${TARGET_VERSION}}"
SOURCE_SYSROOT="${SOURCE_SYSROOT:-/opt/github-runner/cache/sfos-sysroot-5.1.0.11}"

if [ "$(uname -m)" != "aarch64" ]; then
    echo "ERROR: This script must run on an aarch64 host (runner is $(uname -m))." >&2
    exit 1
fi

if [ "$(id -u)" != "0" ]; then
    echo "ERROR: Run as root (sudo)." >&2
    exit 1
fi

# ── 1. Seed sysroot from source if not already present ────────────────────────
if [ ! -f "${SYSROOT}/usr/bin/zypper" ]; then
    if [ ! -d "${SOURCE_SYSROOT}/usr/include" ]; then
        echo "ERROR: Source sysroot not found at ${SOURCE_SYSROOT}." >&2
        exit 1
    fi
    echo "Seeding ${SYSROOT} from ${SOURCE_SYSROOT}..."
    mkdir -p "$(dirname "${SYSROOT}")"
    cp -a "${SOURCE_SYSROOT}" "${SYSROOT}"
    echo "Seed complete."
else
    echo "Sysroot already exists at ${SYSROOT}, updating in-place."
fi

current_version="$(sed -n 's/^VERSION_ID=//p' "${SYSROOT}/etc/os-release" | tr -d '"')"
echo "Current version: ${current_version} → upgrading to ${TARGET_VERSION}"

# ── 2. Replace SSU plugin repos with direct HTTPS URLs ────────────────────────
# The ssu plugin (plugin:ssu?repo=...) can't resolve on the build host.
# We write concrete repo files pointing at releases.jolla.com directly.
REPOS_D="${SYSROOT}/etc/zypp/repos.d"
BASE="https://releases.jolla.com"
ARCH="aarch64"

echo "Writing direct-URL repo files for ${TARGET_VERSION}..."
cat > "${REPOS_D}/ssu_jolla_release.repo" <<EOF
[jolla]
name=jolla
enabled=1
gpgcheck=0
baseurl=${BASE}/releases/${TARGET_VERSION}/jolla/${ARCH}/
EOF

cat > "${REPOS_D}/ssu_hotfixes_release.repo" <<EOF
[hotfixes]
name=hotfixes
enabled=1
gpgcheck=0
baseurl=${BASE}/releases/${TARGET_VERSION}/hotfixes/${ARCH}/
EOF

cat > "${REPOS_D}/ssu_adaptation-common_release.repo" <<EOF
[adaptation-common]
name=adaptation-common
enabled=1
gpgcheck=0
baseurl=${BASE}/releases/${TARGET_VERSION}/jolla-hw/adaptation-common/${ARCH}/
EOF

cat > "${REPOS_D}/ssu_apps_release.repo" <<EOF
[apps]
name=apps
enabled=1
gpgcheck=0
baseurl=${BASE}/jolla-apps/${TARGET_VERSION}/${ARCH}/
EOF

cat > "${REPOS_D}/ssu_sdk_release.repo" <<EOF
[sdk]
name=sdk
enabled=1
gpgcheck=0
baseurl=${BASE}/releases/${TARGET_VERSION}/sdk/${ARCH}/
EOF

# Disable customer-jolla (requires Jolla credentials)
cat > "${REPOS_D}/ssu_customer-jolla_release.repo" <<EOF
[customer-jolla]
name=customer-jolla
enabled=0
gpgcheck=0
baseurl=${BASE}/features/${TARGET_VERSION}/customers/jolla/${ARCH}/
EOF

# ── 3. Bind-mount proc/sys/dev and chroot ────────────────────────────────────
cleanup() {
    echo "Unmounting chroot filesystems..."
    umount -lf "${SYSROOT}/proc"  2>/dev/null || true
    umount -lf "${SYSROOT}/sys"   2>/dev/null || true
    umount -lf "${SYSROOT}/dev"   2>/dev/null || true
}
trap cleanup EXIT

mount -t proc  proc  "${SYSROOT}/proc"
mount -t sysfs sysfs "${SYSROOT}/sys"
mount --bind   /dev  "${SYSROOT}/dev"

echo ""
echo "Running zypper dup inside chroot to ${TARGET_VERSION}..."
chroot "${SYSROOT}" /usr/bin/zypper \
    --non-interactive \
    --no-gpg-checks \
    ref

chroot "${SYSROOT}" /usr/bin/zypper \
    --non-interactive \
    --no-gpg-checks \
    dup \
    --allow-vendor-change \
    --no-recommends

# ── 4. Update os-release to reflect new version ──────────────────────────────
# zypper dup should handle this via sailfish-version RPM, but patch it
# manually as a safety net in case the RPM didn't change it.
current_after="$(sed -n 's/^VERSION_ID=//p' "${SYSROOT}/etc/os-release" | tr -d '"')"
if [ "${current_after}" != "${TARGET_VERSION}" ]; then
    echo "Patching os-release VERSION_ID to ${TARGET_VERSION}..."
    sed -i \
        -e "s/^VERSION_ID=.*/VERSION_ID=${TARGET_VERSION}/" \
        -e "s/^VERSION=.*/VERSION=\"${TARGET_VERSION}\"/" \
        -e "s/^PRETTY_NAME=.*/PRETTY_NAME=\"Sailfish OS ${TARGET_VERSION}\"/" \
        "${SYSROOT}/etc/os-release"
fi

echo ""
echo "Done. Sysroot at ${SYSROOT} is now:"
grep "^VERSION_ID\|^PRETTY_NAME" "${SYSROOT}/etc/os-release"
