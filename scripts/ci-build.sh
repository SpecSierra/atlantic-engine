#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

export WORK="${WORK:-$(cd "${REPO_ROOT}/.." && pwd)}"
export BUILD_TOOLS="${BUILD_TOOLS:-${REPO_ROOT}}"
export BROWSER_SRC="${BROWSER_SRC:-${WORK}/atlantic-browser}"
# The official 5.1.0.11 SDK target is public, so CI downloads the sysroot
# directly from https://releases.sailfishos.org/sdk/targets/.
export PUBLIC_SFOS_BASE_VERSION="${PUBLIC_SFOS_BASE_VERSION:-5.1.0.11}"
export LOCAL_SFOS_SOURCE_SYSROOT="${LOCAL_SFOS_SOURCE_SYSROOT:-/opt/sfos-sysroot}"
export CI_CACHE_ROOT="${CI_CACHE_ROOT:-/opt/github-runner/cache/atlantic-build}"
export WPE_PREFIX="${WPE_PREFIX:-${WORK}/wpe-sfos-prefix}"
export SYSROOT="${SYSROOT:-/opt/github-runner/cache/sfos-sysroot-5.1.0.11}"
export OUT="${OUT:-/tmp/wpe-sfos-rpms}"
export STAGING="${STAGING:-/tmp/wpe-sfos-stage}"

ARTIFACT_ROOT="${ARTIFACT_ROOT:-${REPO_ROOT}/artifacts}"
LOG_PATH="${LOG_PATH:-${ARTIFACT_ROOT}/build.log}"
SUMMARY_PATH="${SUMMARY_PATH:-${ARTIFACT_ROOT}/summary.txt}"
BUILD_TOOLS_COMMIT=""
if git -C "${BUILD_TOOLS}" rev-parse HEAD >/dev/null 2>&1; then
    BUILD_TOOLS_COMMIT="$(git -C "${BUILD_TOOLS}" rev-parse HEAD)"
fi

rm -rf "${ARTIFACT_ROOT}/rpms" "${ARTIFACT_ROOT}/build-config"
mkdir -p "${ARTIFACT_ROOT}" "${OUT}" "${STAGING}"

cat > "${SUMMARY_PATH}" <<EOF
repo_root=${REPO_ROOT}
work=${WORK}
build_tools=${BUILD_TOOLS}
browser_src=${BROWSER_SRC}
ccache_dir=${CCACHE_DIR:-}
ccache_maxsize=${CCACHE_MAXSIZE:-}
ccache_basedir=${CCACHE_BASEDIR:-}
ccache_nohashdir=${CCACHE_NOHASHDIR:-}
ci_cache_root=${CI_CACHE_ROOT:-}
wpe_prefix=${WPE_PREFIX}
rpm_iteration=${RPM_ITERATION:-1}
sysroot=${SYSROOT}
public_sfos_base_version=${PUBLIC_SFOS_BASE_VERSION}
local_sfos_source_sysroot=${LOCAL_SFOS_SOURCE_SYSROOT}
  qt5_plugin_source_dir=${QT5_PLUGIN_SOURCE_DIR:-}
nproc=${NPROC:-}
out=${OUT}
staging=${STAGING}
build_tools_commit=${BUILD_TOOLS_COMMIT}
started_at=$(date --iso-8601=seconds)
EOF

rm -rf "${CI_CACHE_ROOT}/wpe-sfos-prefix" "${CI_CACHE_ROOT}/sources"

ccache_smoke_test() {
    if ! command -v ccache >/dev/null 2>&1; then
        echo "ERROR: ccache is not available in CI" >&2
        exit 1
    fi

    local smoke_dir="${ARTIFACT_ROOT}/ccache-smoke"
    local smoke_source="${smoke_dir}/smoke.cpp"

    rm -rf "${smoke_dir}"
    mkdir -p "${smoke_dir}"
    cat > "${smoke_source}" <<'CPP'
int smoke() { return 42; }
CPP

    # Use the same compiler the WebKit build will use so we actually validate
    # the ccache path that matters.
    local smoke_cxx
    if [ "${WEBKIT_COMPILER:-gcc}" = "clang" ]; then
        smoke_cxx="clang++-18"
    else
        smoke_cxx="g++"
    fi

    ccache -z >/dev/null
    ccache "${smoke_cxx}" -c "${smoke_source}" -o "${smoke_dir}/first.o"
    ccache "${smoke_cxx}" -c "${smoke_source}" -o "${smoke_dir}/second.o"
    ccache -s > "${ARTIFACT_ROOT}/ccache-smoke.txt"

    local hits
    hits="$(awk '/^[[:space:]]*Hits:/ {print $2; exit}' "${ARTIFACT_ROOT}/ccache-smoke.txt")"
    if [ "${hits:-0}" -lt 1 ]; then
        echo "ERROR: ccache smoke test did not record a cache hit" >&2
        cat "${ARTIFACT_ROOT}/ccache-smoke.txt" >&2
        exit 1
    fi

    ccache -z >/dev/null
}

ccache_smoke_test

if command -v ccache >/dev/null 2>&1; then
    ccache -s > "${ARTIFACT_ROOT}/ccache-before.txt" || true
fi

bash "${REPO_ROOT}/build-all.sh" 2>&1 | tee "${LOG_PATH}"

if command -v ccache >/dev/null 2>&1; then
    ccache -s > "${ARTIFACT_ROOT}/ccache-after.txt" || true
fi

mkdir -p "${ARTIFACT_ROOT}/rpms"
shopt -s nullglob
rpms=("${OUT}"/*.rpm)
if [ "${#rpms[@]}" -eq 0 ]; then
    echo "ERROR: build completed without producing RPMs in ${OUT}" >&2
    exit 1
fi

cp -a "${rpms[@]}" "${ARTIFACT_ROOT}/rpms/"

if [ -d "${WPE_PREFIX}/share/wpe-webkit-2.0/build-config" ]; then
    cp -a "${WPE_PREFIX}/share/wpe-webkit-2.0/build-config" "${ARTIFACT_ROOT}/build-config"
fi

{
    echo "completed_at=$(date --iso-8601=seconds)"
    echo "rpm_count=${#rpms[@]}"
} >> "${SUMMARY_PATH}"
