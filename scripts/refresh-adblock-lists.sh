#!/bin/bash
#
# Standalone rebuild of the adblock filter payload from FRESH upstream lists,
# for the weekly refresh-adblock-lists workflow (no RPM build involved).
# Produces engine.dat + adblock-resources.json + engine.version in $1
# (default: ./adblock-out), ready to publish to the Pages adblock/ path that
# the on-device AdBlockListUpdater polls.
#
# Usage: refresh-adblock-lists.sh [out-dir]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$(mkdir -p "${1:-adblock-out}" && cd "${1:-adblock-out}" && pwd)"

# List URLs / pins / regional lists
set -a
# shellcheck source=../versions.env
source "${SCRIPT_DIR}/versions.env"
set +a

# build-adblock-lists.sh is a sourced fragment; give it the environment
# build-rpms-native.sh normally provides. STAGING is wiped first so every list
# is re-downloaded (the vendored data dir only seeds atlantic-extra.txt, which
# is passed to the builder separately) — sha pins WARN on drift by design.
STAGING="${STAGING:-/tmp/adblock-refresh-stage}"
rm -rf "${STAGING}"
mkdir -p "${STAGING}"
CONTENT_BLOCKER_DATA_DIR="${SCRIPT_DIR}/data/content-blocker"
export CONTENT_BLOCKER_STRICT=0

# shellcheck source=build-adblock-lists.sh
. "${SCRIPT_DIR}/scripts/build-adblock-lists.sh"

cp -a "${CONTENT_BLOCKER_BUILD_DIR}/engine.dat" \
      "${CONTENT_BLOCKER_BUILD_DIR}/adblock-resources.json" \
      "${CONTENT_BLOCKER_BUILD_DIR}/engine.version" \
      "${OUT_DIR}/"

echo "Refreshed filter payload (version $(cat "${OUT_DIR}/engine.version")) in ${OUT_DIR}"
