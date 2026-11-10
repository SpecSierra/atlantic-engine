#!/bin/bash
# Build the INSTRUMENTED engine the PGO training run executes: the engine
# dependencies and WebKit only, with ATLANTIC_PGO=generate. No UI, no RPMs —
# this build is slow by design and must never reach a phone.
#
# Run it with its own CI_CACHE_ROOT / WPE_PREFIX so it cannot replace the
# release build's tree (the "PGO" workflow does).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
export ATLANTIC_PGO=generate
export WEBKIT_COMPILER=clang
: "${CI_CACHE_ROOT:?set CI_CACHE_ROOT to a directory used only for the instrumented build}"
: "${WPE_PREFIX:?set WPE_PREFIX (under CI_CACHE_ROOT)}"

# Same clean slate as scripts/ci-build.sh: ccache, not a stale tree, is what
# makes repeat builds fast.
rm -rf "${CI_CACHE_ROOT}/wpe-sfos-prefix" "${CI_CACHE_ROOT}/sources"
mkdir -p "${CI_CACHE_ROOT}"

bash "${repo_root}/scripts/bootstrap-host.sh"
bash "${repo_root}/scripts/build-engine.sh"
bash "${repo_root}/scripts/build-sandbox-deps.sh"
bash "${repo_root}/scripts/build-webkit.sh"

echo "Instrumented engine installed in ${WPE_PREFIX}"
