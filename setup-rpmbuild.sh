#!/usr/bin/env bash
# setup-rpmbuild.sh — Stage all source tarballs for the WPE SFOS RPM build.
#
# Run this once before using `sfdk build` or `rpmbuild`.
# All tarballs land in ~/rpmbuild/SOURCES/ as expected by the spec files.
#
# Prerequisites:
#   git, meson (for version queries), curl/wget, bzip2, xz
#
# Usage:
#   bash setup-rpmbuild.sh [--sources-dir /path/to/rpmbuild/SOURCES]
#
set -euo pipefail

SOURCES_DIR="${1:-$HOME/rpmbuild/SOURCES}"
mkdir -p "$SOURCES_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/common.sh"

echo "==> Staging RPM sources to: $SOURCES_DIR"

# ---------------------------------------------------------------------------
# 1. wpe-sfos-compat — create tarball from this git repo
# ---------------------------------------------------------------------------
echo ""
echo "--- wpe-sfos-compat 1.0.0 ---"
(
  cd "$SCRIPT_DIR"
  if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "ERROR: $SCRIPT_DIR is not a git repo" >&2
    exit 1
  fi
  git archive --prefix=wpe-sfos-compat-1.0.0/ HEAD \
    | bzip2 > "$SOURCES_DIR/wpe-sfos-compat-1.0.0.tar.bz2"
  echo "  Created wpe-sfos-compat-1.0.0.tar.bz2"
)

# ---------------------------------------------------------------------------
# 2. libwpe
# ---------------------------------------------------------------------------
echo ""
echo "--- libwpe ${LIBWPE_VERSION} ---"
if [ ! -f "$SOURCES_DIR/libwpe-${LIBWPE_VERSION}.tar.xz" ]; then
  TMP=$(mktemp -d)
  git clone --depth=1 --branch "${LIBWPE_VERSION}" \
    https://github.com/WebPlatformForEmbedded/libwpe "$TMP/libwpe" \
    2>/dev/null || {
      echo "  Tag ${LIBWPE_VERSION} not found, cloning HEAD..."
      git clone --depth=1 https://github.com/WebPlatformForEmbedded/libwpe "$TMP/libwpe"
    }
  git -C "$TMP/libwpe" archive --prefix="libwpe-${LIBWPE_VERSION}/" HEAD \
    | xz > "$SOURCES_DIR/libwpe-${LIBWPE_VERSION}.tar.xz"
  rm -rf "$TMP"
  echo "  Created libwpe-${LIBWPE_VERSION}.tar.xz"
else
  echo "  Already present: libwpe-${LIBWPE_VERSION}.tar.xz"
fi

# ---------------------------------------------------------------------------
# 3. libepoxy
# ---------------------------------------------------------------------------
echo ""
echo "--- libepoxy ${LIBEPOXY_VERSION} ---"
if [ ! -f "$SOURCES_DIR/libepoxy-${LIBEPOXY_VERSION}.tar.xz" ]; then
  TMP=$(mktemp -d)
  git clone --depth=1 --branch "${LIBEPOXY_VERSION}" \
    https://github.com/anholt/libepoxy "$TMP/libepoxy" \
    2>/dev/null || {
      echo "  Tag ${LIBEPOXY_VERSION} not found, cloning HEAD..."
      git clone --depth=1 https://github.com/anholt/libepoxy "$TMP/libepoxy"
    }
  git -C "$TMP/libepoxy" archive --prefix="libepoxy-${LIBEPOXY_VERSION}/" HEAD \
    | xz > "$SOURCES_DIR/libepoxy-${LIBEPOXY_VERSION}.tar.xz"
  rm -rf "$TMP"
  echo "  Created libepoxy-${LIBEPOXY_VERSION}.tar.xz"
else
  echo "  Already present: libepoxy-${LIBEPOXY_VERSION}.tar.xz"
fi

# ---------------------------------------------------------------------------
# 4. WPEBackend-fdo
# ---------------------------------------------------------------------------
echo ""
echo "--- wpebackend-fdo ${WPEBACKEND_FDO_VERSION} ---"
if [ ! -f "$SOURCES_DIR/wpebackend-fdo-${WPEBACKEND_FDO_VERSION}.tar.xz" ]; then
  TMP=$(mktemp -d)
  git clone --depth=1 --branch "${WPEBACKEND_FDO_VERSION}" \
    https://github.com/igalia/WPEBackend-fdo "$TMP/wpebackend-fdo" \
    2>/dev/null || {
      echo "  Tag ${WPEBACKEND_FDO_VERSION} not found, cloning HEAD..."
      git clone --depth=1 https://github.com/igalia/WPEBackend-fdo "$TMP/wpebackend-fdo"
    }
  git -C "$TMP/wpebackend-fdo" archive --prefix="wpebackend-fdo-${WPEBACKEND_FDO_VERSION}/" HEAD \
    | xz > "$SOURCES_DIR/wpebackend-fdo-${WPEBACKEND_FDO_VERSION}.tar.xz"
  rm -rf "$TMP"
  echo "  Created wpebackend-fdo-${WPEBACKEND_FDO_VERSION}.tar.xz"
else
  echo "  Already present: wpebackend-fdo-${WPEBACKEND_FDO_VERSION}.tar.xz"
fi

# ---------------------------------------------------------------------------
# 5. WPEWebKit
# ---------------------------------------------------------------------------
echo ""
echo "--- wpewebkit ${LEGACY_WPEWEBKIT_VERSION} ---"
if [ ! -f "$SOURCES_DIR/wpewebkit-${LEGACY_WPEWEBKIT_VERSION}.tar.xz" ]; then
  echo "  Downloading from wpewebkit.org..."
  curl -L --progress-bar \
    "https://wpewebkit.org/releases/wpewebkit-${LEGACY_WPEWEBKIT_VERSION}.tar.xz" \
    -o "$SOURCES_DIR/wpewebkit-${LEGACY_WPEWEBKIT_VERSION}.tar.xz"
  echo "  Downloaded wpewebkit-${LEGACY_WPEWEBKIT_VERSION}.tar.xz"
else
  echo "  Already present: wpewebkit-${LEGACY_WPEWEBKIT_VERSION}.tar.xz"
fi

# ---------------------------------------------------------------------------
# 6. Qt5 carry-forward snapshot (standalone qt5/ source tree)
# ---------------------------------------------------------------------------
echo ""
echo "--- wpewebkit-qt5 ${LEGACY_QT5_PLUGIN_SOURCE_VERSION} snapshot ---"
QT5_SNAPSHOT_ROOT="${QT5_PLUGIN_SOURCE_DIR_DEFAULT}/Source/WebKit/UIProcess/API/wpe/qt5"
QT5_SNAPSHOT_TARBALL="wpewebkit-qt5-${LEGACY_QT5_PLUGIN_SOURCE_VERSION}.tar.xz"
if [ ! -f "${SOURCES_DIR}/${QT5_SNAPSHOT_TARBALL}" ]; then
  if [ ! -d "${QT5_SNAPSHOT_ROOT}" ]; then
    echo "ERROR: Qt5 carry-forward snapshot not found at ${QT5_SNAPSHOT_ROOT}" >&2
    exit 1
  fi
  TMP=$(mktemp -d)
  cp -a "${QT5_SNAPSHOT_ROOT}" "${TMP}/wpewebkit-qt5-${LEGACY_QT5_PLUGIN_SOURCE_VERSION}"
  # No qt-bridge patches are applied here anymore: the historical qt5-plugin
  # patches are baked into the self-contained qt5-plugin/ source tree.
  tar -C "${TMP}" -cJf "${SOURCES_DIR}/${QT5_SNAPSHOT_TARBALL}" \
    "wpewebkit-qt5-${LEGACY_QT5_PLUGIN_SOURCE_VERSION}"
  rm -rf "${TMP}"
  echo "  Created ${QT5_SNAPSHOT_TARBALL}"
else
  echo "  Already present: ${QT5_SNAPSHOT_TARBALL}"
fi

# ---------------------------------------------------------------------------
# Copy spec helper files (toolchain, patches, scripts)
# ---------------------------------------------------------------------------
echo ""
echo "--- Copying spec helper files ---"
for f in \
    sfos-toolchain.cmake \
    sfos-meson-cross.ini \
    patches/webkit/webkit-quirks-no-video.patch \
    patches/webkit/webkit-icu-imported-targets.patch \
    patches/webkit/webkit-renderbox-isnan.patch \
    patches/webkit/webkit-shapeoutside-isnan.patch \
    patches/webkit/webkit-gst-buffer-tuning.patch \
    patch-glibc-versions.py \
    cmake/atlantic-wpe-features.cmake \
    scripts/write-webkit-feature-flags.py; do
  cp -v "$SCRIPT_DIR/$f" "$SOURCES_DIR/$(basename "$f")"
done

echo ""
echo "==> Done. All sources staged in: $SOURCES_DIR"
echo ""
echo "Build order:"
echo "  sfdk build rpm/libwpe.spec"
echo "  sfdk build rpm/libepoxy.spec"
echo "  sfdk build rpm/wpebackend-fdo.spec"
echo "  sfdk build rpm/wpe-sfos-compat.spec"
echo "  sfdk build rpm/wpewebkit2.spec"
echo "  sfdk build rpm/wpewebkit2-qt5.spec"
echo "  sfdk build sailfish-browser/rpm/sailfish-browser.spec"
