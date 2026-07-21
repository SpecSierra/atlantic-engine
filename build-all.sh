#!/bin/bash
# Master build script for WPE SFOS — native aarch64 Ubuntu 24.04
# Logs to /tmp/wpe-build.log
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/scripts/common.sh"

echo "================================================================"
echo "=== WPE SFOS Build started at $(date)"
echo "=== CPUs: ${NPROC}"
echo "=== Scripted baseline: SFOS ${SFOS_SYSROOT_VERSION} / WPE WebKit ${LEGACY_WPEWEBKIT_VERSION}"
echo "=== Migration target: SFOS ${TARGET_SFOS_VERSION} / WPE WebKit ${TARGET_WPEWEBKIT_VERSION}"
echo "================================================================"

bash "${SCRIPT_DIR}/scripts/bootstrap-host.sh"
bash "${SCRIPT_DIR}/scripts/build-engine.sh"
bash "${SCRIPT_DIR}/scripts/build-sandbox-deps.sh"
bash "${SCRIPT_DIR}/scripts/build-webkit.sh"
bash "${SCRIPT_DIR}/scripts/build-adblock-engine.sh"
bash "${SCRIPT_DIR}/scripts/build-ui.sh"
bash "${SCRIPT_DIR}/scripts/package-rpms.sh"

echo ""
echo "================================================================"
echo "=== Build COMPLETE at $(date)"
rpm_out="${OUT:-/tmp/wpe-sfos-rpms}"
echo "=== RPMs in ${rpm_out}/:"
shopt -s nullglob
rpms=("${rpm_out}"/*.rpm)
if [ "${#rpms[@]}" -eq 0 ]; then
    echo "ERROR: no RPMs found in ${rpm_out}" >&2
    exit 1
fi
ls -lh "${rpms[@]}"
echo "================================================================"
