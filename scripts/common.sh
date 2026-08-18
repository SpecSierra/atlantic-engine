#!/bin/bash

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/versions.env"
source "${REPO_ROOT}/scripts/patches.sh"

export REPO_ROOT
export WORK="${WORK:-$(cd "${REPO_ROOT}/.." && pwd)}"
export BUILD_TOOLS="${BUILD_TOOLS:-${REPO_ROOT}}"
export BROWSER_SRC="${BROWSER_SRC:-${WORK}/atlantic-browser}"
export CI_CACHE_ROOT="${CI_CACHE_ROOT:-/opt/github-runner/cache/atlantic-build}"
export WPE_PREFIX="${WPE_PREFIX:-/opt/wpe-sfos}"
export SYSROOT="${SYSROOT:-/opt/sfos-sysroot}"
export NPROC="${NPROC:-$(nproc)}"
export CCACHE_DIR="${CCACHE_DIR:-/opt/github-runner/cache/ccache}"
export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-40G}"
export CCACHE_BASEDIR="${CCACHE_BASEDIR:-${CI_CACHE_ROOT:-${CI_ROOT:-${WORK}}}}"
export CCACHE_NOHASHDIR="${CCACHE_NOHASHDIR:-1}"

if [ -d /usr/lib/ccache ]; then
    export PATH="/usr/lib/ccache:${PATH}"
fi

export LEGACY_WPE_SOURCE_DIR="${WORK}/wpewebkit-${LEGACY_WPEWEBKIT_VERSION}"
export TARGET_WPE_SOURCE_DIR="${WORK}/wpewebkit-${TARGET_WPEWEBKIT_VERSION}"
export QT5_PLUGIN_SOURCE_DIR_DEFAULT="${BUILD_TOOLS}/qt5-plugin"

# Clone a dependency at an EXACT upstream commit.
#
# The previous form was `git clone --depth=1 --branch "${VERSION}" ... 2>/dev/null
# || git clone --depth=1 ...`. For libwpe, WPEBackend-fdo and libepoxy those tags
# do not exist upstream (1.17.0 / 1.5.11 are the in-development version strings on
# main, not releases), so the first clone failed silently every time and the
# fallback built whatever main happened to be that day. The *_VERSION values stay
# as-is because they name the RPMs and match what the tree self-reports; the
# *_COMMIT values below are what is actually checked out.
#
# GitHub allows fetching an arbitrary reachable SHA, so this stays a shallow
# fetch. A bad or ungraftable SHA now fails the build instead of silently
# drifting to HEAD.
clone_pinned() {
    local url="$1"
    local dir="$2"
    local commit="$3"

    if [ -z "${commit}" ]; then
        echo "ERROR: clone_pinned ${url}: no commit pinned" >&2
        return 1
    fi

    rm -rf "${dir}"
    mkdir -p "${dir}"
    git -C "${dir}" init -q
    git -C "${dir}" remote add origin "${url}"
    if ! git -C "${dir}" fetch -q --depth=1 origin "${commit}"; then
        echo "ERROR: ${url}: cannot fetch pinned commit ${commit}" >&2
        echo "       (force-push or GC upstream? re-pin in versions.env)" >&2
        rm -rf "${dir}"
        return 1
    fi
    git -C "${dir}" checkout -q FETCH_HEAD
    echo "  ${dir##*/} pinned at ${commit}"
}

maybe_patch_glibc_versions() {
    [ "${PATCH_GLIBC_VERSIONS:-0}" = "1" ] || return 0
    python3 "${BUILD_TOOLS}/patch-glibc-versions.py" "$@"
}
