# shellcheck shell=bash
#
# Fetch the EasyList/EasyPrivacy/annoyance filter lists, build the Brave/Rust
# adblock engine, and compile the serialized engine.dat. SOURCED by
# build-rpms-native.sh (runs in the parent shell), not executed standalone.
#
# Requires from the caller: STAGING, SCRIPT_DIR, CONTENT_BLOCKER_DATA_DIR, the
#   list URLs/pins + REGIONAL_ANTI_CV_LISTS/ANTI_CV_REPO_RAW (from versions.env),
#   HOME, optionally SUDO_USER / CONTENT_BLOCKER_STRICT.
# Exports for the caller: CONTENT_BLOCKER_BUILD_DIR, CONTENT_BLOCKER_FETCH_DIR
#   (and produces engine.dat + adblock-engine/target/release/libatlantic_adblock.so).

CONTENT_BLOCKER_BUILD_DIR="${STAGING}/content-blocker-build"
rm -rf "${CONTENT_BLOCKER_BUILD_DIR}"
mkdir -p "${CONTENT_BLOCKER_BUILD_DIR}"

# Fetch the EasyList sources into the build/staging dir, NOT into the git
# checkout.  Writing them under ${SCRIPT_DIR}/data used to leave root-owned
# files in the working tree that the (non-root) CI runner could not `git clean`,
# breaking the checkout of every subsequent build.  Staging is build-scratch and
# outside the repo, so the checkout is never affected.
CONTENT_BLOCKER_FETCH_DIR="${CONTENT_BLOCKER_BUILD_DIR}"

# Cached: an existing fetched copy is reused; a vendored/offline copy under
# data/content-blocker (read-only seed) is also honoured.
fetch_content_blocker_list() {
    local name="$1" url="$2" pin="$3"
    local dest="${CONTENT_BLOCKER_FETCH_DIR}/${name}.txt"
    local seed="${CONTENT_BLOCKER_DATA_DIR}/${name}.txt"
    if [ ! -s "${dest}" ] && [ -s "${seed}" ]; then
        echo "  Seeding ${name}.txt from vendored copy"
        cp "${seed}" "${dest}"
    fi
    if [ ! -s "${dest}" ]; then
        echo "  Downloading ${name} from ${url}"
        wget -q "${url}" -O "${dest}.tmp"
        mv "${dest}.tmp" "${dest}"
    else
        echo "  Using cached ${name}.txt"
    fi
    if [ -n "${pin}" ]; then
        local got; got="$(sha256sum "${dest}" | awk '{print $1}')"
        if [ "${got}" != "${pin}" ]; then
            echo "  WARNING: ${name}.txt sha256 ${got} != pinned ${pin} (EasyList updates daily)." >&2
            if [ "${CONTENT_BLOCKER_STRICT:-0}" = "1" ]; then
                echo "  CONTENT_BLOCKER_STRICT=1 set — aborting on snapshot drift." >&2
                exit 1
            fi
        fi
    fi
    echo "  ${name}: $(grep -m1 '^! Version:' "${dest}" 2>/dev/null || echo 'version unknown')"
}
fetch_content_blocker_list easylist    "${EASYLIST_URL}"    "${EASYLIST_SHA256:-}"
fetch_content_blocker_list easyprivacy "${EASYPRIVACY_URL}" "${EASYPRIVACY_SHA256:-}"

# Adblock engine filter lists (cookie consent, annoyance, cosmetic)
fetch_content_blocker_list fanboy-annoyance "${FANBOY_ANNOYANCE_URL}"  "${FANBOY_ANNOYANCE_SHA256:-}"
fetch_content_blocker_list ubo-annoyances   "${UBO_ANNOYANCES_URL}"    "${UBO_ANNOYANCES_SHA256:-}"
fetch_content_blocker_list fanboy-social     "${FANBOY_SOCIAL_URL}"    "${FANBOY_SOCIAL_SHA256:-}"
fetch_content_blocker_list anti-cv           "${ANTI_CV_URL}"          "${ANTI_CV_SHA256:-}"
fetch_content_blocker_list fanboy-cookie     "${FANBOY_COOKIE_URL}"    "${FANBOY_COOKIE_SHA256:-}"
fetch_content_blocker_list ubo-cookies       "${UBO_COOKIES_URL}"      "${UBO_COOKIES_SHA256:-}"

# Adblock runtime resources (not filter lists — NOT passed to the engine
# builder args): Brave redirect surrogates + uBO scriptlet bodies, merged below
# by `builder --resources` into adblock-resources.json (loaded at runtime).
fetch_content_blocker_list adblock-resources "${ADBLOCK_RESOURCES_URL}" "${ADBLOCK_RESOURCES_SHA256:-}"
fetch_content_blocker_list ubo-scriptlets    "${UBO_SCRIPTLETS_URL}"    "${UBO_SCRIPTLETS_SHA256:-}"

# Regional Anti-CV language lists
for region in ${REGIONAL_ANTI_CV_LISTS}; do
    fetch_content_blocker_list "anti-cv-${region}" "${ANTI_CV_REPO_RAW}/${region}.txt" ""
done

# ---------------------------------------------------------------------------
# Build adblock-rust engine and compile filter list cache
# ---------------------------------------------------------------------------
echo "--- Building adblock engine ---"
(
    if [ -f "${HOME}/.cargo/env" ]; then
        source "${HOME}/.cargo/env"
    elif [ -n "${SUDO_USER:-}" ] && [ -f "/home/${SUDO_USER}/.cargo/env" ]; then
        source "/home/${SUDO_USER}/.cargo/env"
    fi
    cd "${SCRIPT_DIR}/adblock-engine" && cargo build --release
)

echo "--- Compiling filter list cache ---"
BUILDER_ARGS=(
    "${CONTENT_BLOCKER_BUILD_DIR}/engine.dat"
    "${CONTENT_BLOCKER_FETCH_DIR}/easylist.txt"
    "${CONTENT_BLOCKER_FETCH_DIR}/easyprivacy.txt"
    "${CONTENT_BLOCKER_FETCH_DIR}/fanboy-annoyance.txt"
    "${CONTENT_BLOCKER_FETCH_DIR}/ubo-annoyances.txt"
    "${CONTENT_BLOCKER_FETCH_DIR}/fanboy-social.txt"
    "${CONTENT_BLOCKER_FETCH_DIR}/anti-cv.txt"
    "${CONTENT_BLOCKER_FETCH_DIR}/fanboy-cookie.txt"
    "${CONTENT_BLOCKER_FETCH_DIR}/ubo-cookies.txt"
)
for region in ${REGIONAL_ANTI_CV_LISTS}; do
    BUILDER_ARGS+=("${CONTENT_BLOCKER_FETCH_DIR}/anti-cv-${region}.txt")
done
# Atlantic custom rules: domains EasyList/EasyPrivacy miss (e.g. getjad/getjan,
# the jeuxvideo.com forum ad library that pins the main thread). Vendored in the
# repo (data/content-blocker), always present, no fetch.
if [ -s "${CONTENT_BLOCKER_DATA_DIR}/atlantic-extra.txt" ]; then
    BUILDER_ARGS+=("${CONTENT_BLOCKER_DATA_DIR}/atlantic-extra.txt")
fi
"${SCRIPT_DIR}/adblock-engine/target/release/builder" "${BUILDER_ARGS[@]}"

# Freshness stamp: build epoch, shipped/published next to engine.dat. The
# browser's list updater and both engine loaders compare these to pick the
# newer of the shipped and downloaded copies.
date +%s > "${CONTENT_BLOCKER_BUILD_DIR}/engine.version"

echo "--- Fetching DuckDuckGo autoconsent (cookie-banner auto-reject) ---"
# The standalone dist bundle self-initializes (autoAction=optOut, embedded
# compact rules) — the browser injects it verbatim as a document-start user
# script in every frame. Fetched as the npm tarball; only dist/ is extracted.
AUTOCONSENT_TGZ="${CONTENT_BLOCKER_FETCH_DIR}/autoconsent-${AUTOCONSENT_VERSION}.tgz"
if [ ! -s "${AUTOCONSENT_TGZ}" ]; then
    echo "  Downloading autoconsent ${AUTOCONSENT_VERSION}"
    wget -q "${AUTOCONSENT_URL}" -O "${AUTOCONSENT_TGZ}.tmp"
    mv "${AUTOCONSENT_TGZ}.tmp" "${AUTOCONSENT_TGZ}"
fi
if [ -n "${AUTOCONSENT_SHA256:-}" ]; then
    got="$(sha256sum "${AUTOCONSENT_TGZ}" | awk '{print $1}')"
    if [ "${got}" != "${AUTOCONSENT_SHA256}" ]; then
        echo "  ERROR: autoconsent tarball sha256 ${got} != pinned ${AUTOCONSENT_SHA256}" >&2
        exit 1
    fi
fi
tar -xzf "${AUTOCONSENT_TGZ}" -C "${CONTENT_BLOCKER_BUILD_DIR}" \
    --strip-components=2 package/dist/autoconsent.standalone.js
mv "${CONTENT_BLOCKER_BUILD_DIR}/autoconsent.standalone.js" \
   "${CONTENT_BLOCKER_BUILD_DIR}/autoconsent.js"
echo "  autoconsent.js: $(wc -c < "${CONTENT_BLOCKER_BUILD_DIR}/autoconsent.js") bytes"

echo "--- Assembling adblock runtime resources ---"
"${SCRIPT_DIR}/adblock-engine/target/release/builder" --resources \
    "${CONTENT_BLOCKER_BUILD_DIR}/adblock-resources.json" \
    "${CONTENT_BLOCKER_FETCH_DIR}/ubo-scriptlets.txt" \
    "${CONTENT_BLOCKER_FETCH_DIR}/adblock-resources.txt"
