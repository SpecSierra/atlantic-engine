> **Status: SHIPPED** — The Brave/Rust engine landed in build 462 and is now the sole network blocker (`adblock-engine/` + `web-extension/`). Kept as the design record.
>
> Archived `handover/adblock-rust-integration-plan.md` (build host `/root`), 2026-07-30.

# Atlantic Browser — adblock-rust Integration Plan

**Date:** 2026-06-08
**Author:** Kilo (research & planning)
**Status:** Ready for implementation

---

## 1. Summary

Replace the current basic ad-blocking system (20 hardcoded domain suffixes in
`onDecidePolicy` + limited WebKit ContentFilterStore rules) with Brave's
production-grade `adblock-rust` engine. This gives us:

- Full EasyList + EasyPrivacy support (network blocking)
- Cosmetic filtering (element hiding, `:has()` selectors)
- Cookie / consent banner blocking (Fanboy's Annoyance, uBO Annoyances)
- Scriptlet injection (`##+js()`)
- $redirect, $csp, $badfilter, procedural filters
- Sub-100ms cold start via FlatBuffers binary cache
- < 10 µs per-request matching

**Engine:** [brave/adblock-rust](https://github.com/brave/adblock-rust) v0.13

> **0.12 → 0.13 (2026-07-30).** Breaking bump. The serialized cache format went
> **v3 → v5**, so an `engine.dat` built by one engine version is rejected outright
> by the other (`VersionMismatch`) — builder and runtime must always ship together.
> The web extension's existing "corrupt updated copy falls back to the shipped
> copy" path covers the transition for already-installed devices: they keep
> adblocking with their shipped lists, but stop applying published list refreshes
> until the RPM is updated.
>
> API changes ported: `Engine::from_filter_set(set, optimize)` split into
> `new_with_filter_set` / `new_with_filter_set_no_optimize`; `FilterSet::add_filter_list`
> takes an owned `String`; `FilterSet::add_filters` removed; `BlockerResult::matched`
> replaced by `Option<FilterRuleDebugInfo>` fields (`matched` ≡
> `exception.is_none() && filter.is_some()`, upstream's own definition);
> `BlockerResult::exception` is now a struct rather than a `String`.
>
> New in 0.13: **`$method`**. A filter carrying it never matches unless the real
> HTTP verb is supplied, so the verb is now plumbed from
> `webkit_uri_request_get_http_method()` through the FFI. Passing `""` would have
> left every `$method` rule permanently inert.
>
> Verified before landing: 607-URL corpus drawn from EasyList/EasyPrivacy hosts
> plus benign controls — 587 blocked under both versions, **zero verdict
> differences**; cosmetic output identical on three sites (hide-rule counts,
> injected scriptlet bytes, procedural actions); assembled `adblock-resources.json`
> identical (56 resources). `engine.dat` grew 15.28 → 16.82 MB (+10%) for the same
> list set.
>
> **Publish path is keyed to the format version.** The on-device updater picks
> between shipped and downloaded payloads by epoch stamp alone, so it cannot tell
> "newer" from "unreadable" until it has already fetched ~17 MB. The payload
> therefore moved from `…/atlantic-engine/adblock/` to `…/adblock/v5/`, set in
> three places that must stay in sync: `kDefaultBaseUrl`
> (browser `apps/wpe/AdBlockListUpdater.cpp`), and `destination_dir` in
> `build-atlantic-packages.yml` and `refresh-adblock-lists.yml`. Clients on the
> old RPM keep polling `adblock/`, get a 404, log a warning and leave their cache
> alone — they stay on their shipped lists instead of re-downloading a v5 payload
> they would reject on every refresh. Bump the path whenever
> `ADBLOCK_RUST_DAT_VERSION` changes.
**License:** MPL-2.0 (compatible — Atlantic Browser is also MPL-2.0)
**Language:** Rust → native `libatlantic_adblock.so` (ARM64)
**Filter lists:** EasyList + EasyPrivacy + Fanboy's Annoyance + uBO Annoyances

---

## 2. Current Architecture (for reference)

```
atlantic-browser (Qt5/QML, MPL-2.0)
  │
  ├─ apps/browser/        QML UI (browser.qml, pages/, cover/)
  ├─ apps/wpe/            WPE WebKit Qt5 bridge
  │   ├─ WPEWebPage.h/.cpp        Primary web view (extends WPEQtView)
  │   ├─ WPEWebContainer.h/.cpp   Tab manager, sandbox, WebContext
  │   └─ WPERuntimePaths.h        Deploy paths
  ├─ apps/lib/            Shared library
  ├─ apps/storage/        History, bookmarks SQLite
  ├─ data/content-blocker.json    Built-in blocking rules (Safari JSON)
  └─ sailfish-browser.pro         Top-level qmake project

atlantic-engine (build repo, MPL-2.0)
  │
  ├─ qt5-plugin/          Standalone Qt5 WPE plugin
  │   ├─ WPEQtView.h/.cpp        QQuickItem → WebKitWebView bridge
  │   ├─ WPEQtViewBackend.h/.cpp EGL compositing backend
  │   └─ WPEQtViewLoadRequest.*  Load state tracking
  ├─ build-rpms-native.sh   RPM packaging script (fpm-based)
  ├─ easylist-to-webkit.py  Converts ABP rules → Safari JSON
  ├─ versions.env           Version pins + filter list URLs
  └─ .github/workflows/     CI on self-hosted ARM64 runner
```

### Existing ad-blocking layers

| Layer | Location | Mechanism | Capability |
|-------|----------|-----------|------------|
| `onDecidePolicy` | `WPEWebPage.cpp:600` | Hardcoded 20 hostname suffixes; blocks on RESPONSE decisions | Domain-level only, sub-resources only |
| `ensureContentBlocker` | `WPEWebPage.cpp:154` | WebKit `WKUserContentFilterStore` → DFA bytecode | ~15K EasyList rules in Safari JSON; domain+path blocking, some CSS hiding |

Neither layer handles cookie banners, full cosmetic filtering, `$domain`/`$third-party`/`$csp`/`$redirect` modifiers, or procedural filters.

---

## 3. Target Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     FILTER LISTS (build time)                     │
│  EasyList  EasyPrivacy  Fanboy's Annoyance  uBO Annoyances       │
└─────────────────────┬───────────────────────────────────────────┘
                      │
          ┌───────────▼────────────┐
          │  adblock-rust builder  │  Rust binary (build time only)
          │  Engine::from_         │  Reads raw .txt lists
          │  filter_set()          │  Produces FlatBuffers .dat
          └───────────┬────────────┘
                      │
          ┌───────────▼────────────┐
          │    engine.dat           │  ~10–20 MB FlatBuffers blob
          │  /usr/share/atlantic-  │  Shipped in RPM
          │  browser/engine.dat    │
          └───────────┬────────────┘
                      │
     ┌────────────────┼────────────────┐
     │                │                │
     ▼                ▼                ▼
┌─────────┐  ┌──────────────┐  ┌──────────────┐
│ onDecide│  │ onLoading    │  │ engine_init  │
│ Policy  │  │ Changed      │  │ (constructor)│
│         │  │              │  │              │
│ Network │  │ Cosmetic CSS │  │ deserialize  │
│ block/  │  │ injection    │  │ engine.dat   │
│ ignore  │  │ post-load    │  │ on startup   │
└────┬────┘  └──────────────┘  └──────────────┘
     │
     ▼
┌──────────────────────────────────────────────┐
│            libatlantic_adblock.so             │
│  ┌──────────────────────────────────────┐    │
│  │  adblock-rust Engine                 │    │
│  │  • check_network_request()           │    │
│  │  • url_cosmetic_resources()          │    │
│  │  • serialize() / deserialize()       │    │
│  │  • enable_tag()                      │    │
│  └──────────────────────────────────────┘    │
│  C FFI layer (~250 lines)                    │
│  atlantic_adblock_create_from_cache()        │
│  atlantic_adblock_match_network()            │
│  atlantic_adblock_get_cosmetic()             │
│  atlantic_adblock_destroy()                  │
└──────────────────────────────────────────────┘
```

---

## 4. Implementation Phases

### 4.1 Phase 1 — Rust Crate & C FFI Bridge

**Directory:** `atlantic-engine/adblock-engine/` (new)

**`Cargo.toml`**

```toml
[package]
name = "atlantic-adblock"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
adblock = { version = "0.12", default-features = false, features = [
    "full-regex-handling",
    "resource-assembler",
] }
```

Note: `embedded-domain-resolver` is disabled. We do not need WPE's PSL;
adblock-rust uses a bundled `addr` crate or falls back to basic domain
matching when the feature is off.

**`src/lib.rs`** — C FFI layer (~250 lines)

The FFI exposes these functions:

```
AtlanticAdblockEngine* atlantic_adblock_create_from_cache(const uint8_t* data, size_t len);
AtlanticAdblockEngine* atlantic_adblock_create_from_lists(const char** lists, int count);
void                   atlantic_adblock_destroy(AtlanticAdblockEngine*);
int                    atlantic_adblock_serialize(AtlanticAdblockEngine*, uint8_t** out, size_t* out_len);
void                   atlantic_adblock_free_buffer(uint8_t*, size_t);

// Network matching
typedef struct { bool matched, important; char* redirect, *exception; } MatchResult;
MatchResult  atlantic_adblock_match_network(AtlanticAdblockEngine*, const char* src_url, const char* req_url, const char* resource_type, int third_party);
void         atlantic_adblock_free_match_result(MatchResult);

// Cosmetic filtering
typedef struct { const char* hide_selectors; const char* injected_script; const char* generated_css; } CosmeticResult;
CosmeticResult atlantic_adblock_get_cosmetic(AtlanticAdblockEngine*, const char* url);
void           atlantic_adblock_free_cosmetic(CosmeticResult);

// Tag management (e.g., toggle "fanboy-annoyance" on/off)
void atlantic_adblock_enable_tag(AtlanticAdblockEngine*, const char* tag);
```

**Design decisions for the FFI:**
- Opaque `void*` handles — no struct layout coupling between Rust and C++
- Strings are null-terminated UTF-8 (C strings)
- The engine is a singleton per process (Brave's pattern: one engine, shared across all tabs)
- `MatchResult` and `CosmeticResult` must be freed after use
- Cosmetic result strings are owned by the engine's internal cache until the next `get_cosmetic` call; the C++ side copies them eagerly

**`src/bin/builder.rs`** — Filter list compiler (~30 lines)

Standalone binary used during the RPM build to pre-compile filter lists:

```rust
// Build the engine from filter list files, serialize to .dat
fn main() {
    let args: Vec<String> = std::env::args().collect();
    let output = &args[1];
    let mut filter_set = FilterSet::new(true);
    for path in &args[2..] {
        let text = fs::read_to_string(path).expect("read filter list");
        let fmt = if path.contains("hosts") { FilterFormat::Hosts } else { FilterFormat::Standard };
        filter_set.add_filter_list(&text, fmt);
    }
    let engine = Engine::from_filter_set(filter_set, true);
    let data = engine.serialize().expect("serialize");
    fs::write(output, data).expect("write .dat");
}
```

**Build output:**
- `target/release/libatlantic_adblock.so` — shared library (~2–4 MB stripped ARM64)
- `target/release/builder` — filter list compiler binary

### 4.2 Phase 2 — Filter List Management

**New filter list URLs** (add to `versions.env`):

```bash
EASYLIST_URL=https://easylist.to/easylist/easylist.txt
EASYPRIVACY_URL=https://easylist.to/easylist/easyprivacy.txt
FANBOY_ANNOYANCE_URL=https://secure.fanboy.co.nz/fanboy-annoyance.txt
UBO_ANNOYANCES_URL=https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/annoyances.txt
```

**EasyList fetch** (reuse existing `fetch_content_blocker_list()` pattern in
`build-rpms-native.sh`):

```bash
fetch_content_blocker_list easylist         "${EASYLIST_URL}"          "${EASYLIST_SHA256:-}"
fetch_content_blocker_list easyprivacy      "${EASYPRIVACY_URL}"       "${EASYPRIVACY_SHA256:-}"
fetch_content_blocker_list fanboy-annoyance "${FANBOY_ANNOYANCE_URL}"  "${FANBOY_ANNOYANCE_SHA256:-}"
fetch_content_blocker_list ubo-annoyances   "${UBO_ANNOYANCES_URL}"    "${UBO_ANNOYANCES_SHA256:-}"
```

**Build engine.dat cache** (in `build-rpms-native.sh`, section 7 — atlantic-browser
staging):

```bash
echo "--- Building adblock engine ---"
cd "${SCRIPT_DIR}/adblock-engine"
cargo build --release

echo "--- Compiling filter list cache ---"
mkdir -p "${CONTENT_BLOCKER_BUILD_DIR}"
./target/release/builder \
    "${CONTENT_BLOCKER_BUILD_DIR}/engine.dat" \
    "${CONTENT_BLOCKER_FETCH_DIR}/easylist.txt" \
    "${CONTENT_BLOCKER_FETCH_DIR}/easyprivacy.txt" \
    "${CONTENT_BLOCKER_FETCH_DIR}/fanboy-annoyance.txt" \
    "${CONTENT_BLOCKER_FETCH_DIR}/ubo-annoyances.txt"
```

**Install to RPM staging area:**

```bash
# Shared library
mkdir -p "${S}/usr/lib64"
cp -a "${SCRIPT_DIR}/adblock-engine/target/release/libatlantic_adblock.so" "${S}/usr/lib64/"

# Engine cache
cp -a "${CONTENT_BLOCKER_BUILD_DIR}/engine.dat" \
      "${S}/usr/share/atlantic-browser/engine.dat"
```

**Content-blocker JSON fallback:** The existing `content-blocker.json` (built via
`easylist-to-webkit.py`) should be kept as a compile-time fallback. If the
adblock-rust engine fails to load, the WebKit content blocker still provides basic
protection. The new adblock-rust engine is additive, not a replacement for the
content blocker.

### 4.3 Phase 3 — C++ Integration in WPE Bridge

**NEW: `atlantic-browser/apps/wpe/AdBlockEngine.h`** (~80 lines)

```cpp
#pragma once
#include <QString>
#include <QByteArray>

extern "C" {
    struct MatchResult { bool matched; bool important; char* redirect; char* exception; };
    struct CosmeticResult { const char* hide_selectors; const char* injected_script; const char* generated_css; };
    typedef void AtlanticAdblockEngine;

    AtlanticAdblockEngine* atlantic_adblock_create_from_cache(const uint8_t*, size_t);
    void                   atlantic_adblock_destroy(AtlanticAdblockEngine*);
    MatchResult            atlantic_adblock_match_network(AtlanticAdblockEngine*, const char* src, const char* req, const char* type, int third_party);
    void                   atlantic_adblock_free_match_result(MatchResult);
    CosmeticResult         atlantic_adblock_get_cosmetic(AtlanticAdblockEngine*, const char* url);
    void                   atlantic_adblock_free_cosmetic(CosmeticResult);
    void                   atlantic_adblock_enable_tag(AtlanticAdblockEngine*, const char*);
}

class WPEWebPage; // forward

/// Process-wide singleton ad-block engine.
/// One Engine instance shared across all tabs — Brave's architecture.
class AdBlockEngine {
public:
    static AdBlockEngine& instance();

    bool loadFromCache(const QString& path);
    bool isLoaded() const { return m_engine != nullptr; }

    /// Check if a network request should be blocked.
    /// @param redirectUrl [out] if set and blocked with redirect, the redirect target.
    bool shouldBlock(const QString& sourceUrl, const QString& requestUrl,
                     const char* resourceType, bool isThirdParty,
                     QString* redirectUrl = nullptr);

    /// Inject cosmetic CSS + scriptlets into a loaded page.
    void applyCosmetics(WPEWebPage* page);

private:
    AdBlockEngine() = default;
    ~AdBlockEngine();
    AdBlockEngine(const AdBlockEngine&) = delete;
    AtlanticAdblockEngine* m_engine = nullptr;
};
```

**NEW: `atlantic-browser/apps/wpe/AdBlockEngine.cpp`** (~130 lines)

```cpp
#include "AdBlockEngine.h"
#include "WPEWebPage.h"
#include <QFile>
#include <QFileInfo>
#include <QDebug>
#include <QStandardPaths>
#include <QTimer>

AdBlockEngine& AdBlockEngine::instance()
{
    static AdBlockEngine inst;
    return inst;
}

AdBlockEngine::~AdBlockEngine()
{
    if (m_engine) atlantic_adblock_destroy(m_engine);
}

bool AdBlockEngine::loadFromCache(const QString& path)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) {
        qWarning() << "[ADBLOCK] engine cache not found:" << path;
        return false;
    }
    QByteArray data = f.readAll();
    m_engine = atlantic_adblock_create_from_cache(
        reinterpret_cast<const uint8_t*>(data.constData()),
        static_cast<size_t>(data.size()));
    if (!m_engine) {
        qWarning() << "[ADBLOCK] failed to deserialize engine cache";
        return false;
    }
    qInfo() << "[ADBLOCK] engine loaded from" << (data.size() / 1024) << "KB cache";
    return true;
}

bool AdBlockEngine::shouldBlock(const QString& sourceUrl, const QString& requestUrl,
                                 const char* resourceType, bool isThirdParty,
                                 QString* redirectUrl)
{
    if (!m_engine) return false;

    QByteArray src = sourceUrl.toUtf8();
    QByteArray req = requestUrl.toUtf8();

    MatchResult r = atlantic_adblock_match_network(
        m_engine, src.constData(), req.constData(),
        resourceType, isThirdParty ? 1 : 0);

    bool blocked = r.matched && r.redirect == nullptr;  // redirect != block, handled separately
    if (r.redirect && redirectUrl) {
        *redirectUrl = QString::fromUtf8(r.redirect);
        blocked = true;  // treat redirect as a form of blocking
    }
    atlantic_adblock_free_match_result(r);
    return blocked;
}

void AdBlockEngine::applyCosmetics(WPEWebPage* page)
{
    if (!m_engine || !page) return;

    QByteArray urlUtf8 = page->url().toString().toUtf8();
    CosmeticResult cr = atlantic_adblock_get_cosmetic(m_engine, urlUtf8.constData());

    QStringList scripts;

    // 1. Hide selectors → inject <style> with display:none!important
    if (cr.hide_selectors && *cr.hide_selectors) {
        QString sel = QString::fromUtf8(cr.hide_selectors)
                          .replace('\\', "\\\\").replace('\'', "\\'");
        scripts << QStringLiteral(
            "(function(){var s=document.createElement('style');"
            "s.id='__atl_adblock_hide';"
            "s.textContent='%1{display:none!important}';"
            "document.documentElement.appendChild(s);})()").arg(sel);
    }

    // 2. Generated CSS (procedural filters, :has() expansions)
    if (cr.generated_css && *cr.generated_css) {
        QString css = QString::fromUtf8(cr.generated_css)
                          .replace('\\', "\\\\").replace('\'', "\\'")
                          .replace('\n', ' ');
        scripts << QStringLiteral(
            "(function(){var s=document.createElement('style');"
            "s.id='__atl_adblock_gen';"
            "s.textContent='%1';"
            "document.documentElement.appendChild(s);})()").arg(css);
    }

    // 3. Injected scriptlets (##+js() rules — cookie consent, anti-adblock)
    if (cr.injected_script && *cr.injected_script) {
        scripts << QString::fromUtf8(cr.injected_script);
    }

    atlantic_adblock_free_cosmetic(cr);

    for (const QString& s : scripts) {
        page->runJavaScript(s);
    }
}
```

**MODIFIED: `WPEWebPage.cpp` — Replace `onDecidePolicy` (lines 600–665)**

Replace the hardcoded 20-domain suffix list with adblock-rust matching:

```cpp
gboolean onDecidePolicy(WebKitWebView* webView, WebKitPolicyDecision* decision,
                        WebKitPolicyDecisionType type, gpointer)
{
    if (type == WEBKIT_POLICY_DECISION_TYPE_RESPONSE) {
        WebKitResponsePolicyDecision* responseDecision =
            WEBKIT_RESPONSE_POLICY_DECISION(decision);
        if (!responseDecision ||
            webkit_response_policy_decision_is_main_frame_main_resource(responseDecision))
            return FALSE;  // never block the main frame

        WebKitURIRequest* request =
            webkit_response_policy_decision_get_request(responseDecision);
        const gchar* uri = request ? webkit_uri_request_get_uri(request) : nullptr;
        if (!uri || !*uri) return FALSE;

        // Source URL — from the current main-frame URI
        QString sourceUrl;
        const gchar* activeUri = webkit_web_view_get_uri(webView);
        if (activeUri && *activeUri)
            sourceUrl = QString::fromUtf8(activeUri);
        else
            sourceUrl = QString::fromUtf8(uri); // fallback: treat request as first-party

        // Determine resource type from the URI / response
        // (GLib's decide-policy for RESPONSE doesn't expose resource type directly;
        //  use request URI extension as heuristic. A more precise approach would
        //  connect to "resource-load-started" which does report the type.)
        const char* rtype = "other";

        QString redirectUrl;
        if (AdBlockEngine::instance().shouldBlock(
                sourceUrl, QString::fromUtf8(uri), rtype, true, &redirectUrl)) {
            if (!redirectUrl.isEmpty()) {
                // Redirect filter matched (e.g., googlesyndication → neutered resource)
                webkit_web_view_load_uri(webView, redirectUrl.toUtf8().constData());
            }
            webkit_policy_decision_ignore(decision);
            return TRUE;
        }
        return FALSE;
    }

    // --- NEW_WINDOW_ACTION: open in same view (unchanged from original) ---
    if (type != WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION)
        return FALSE;

    WebKitNavigationPolicyDecision* navDecision =
        WEBKIT_NAVIGATION_POLICY_DECISION(decision);
    WebKitNavigationAction* action =
        webkit_navigation_policy_decision_get_navigation_action(navDecision);
    WebKitURIRequest* request = action ?
        webkit_navigation_action_get_request(action) : nullptr;
    const gchar* newUri = request ? webkit_uri_request_get_uri(request) : nullptr;
    if (newUri && *newUri) {
        webkit_web_view_load_uri(webView, newUri);
    }
    webkit_policy_decision_ignore(decision);
    return TRUE;
}
```

**MODIFIED: `WPEWebPage.cpp` — Engine initialization + cosmetic injection**

In the constructor (near line 1957 where `onDecidePolicy` is connected), add engine
initialization — one-time, process-wide:

```cpp
// After web view creation, after onDecidePolicy connection:
{
    static bool engineInitialized = false;
    if (!engineInitialized) {
        engineInitialized = true;
        QString cachePath = QStringLiteral("/usr/share/atlantic-browser/engine.dat");
        if (!QFileInfo::exists(cachePath)) {
            cachePath = QStandardPaths::writableLocation(QStandardPaths::GenericCacheLocation)
                        + QStringLiteral("/atlantic-browser/engine.dat");
        }
        if (!AdBlockEngine::instance().loadFromCache(cachePath)) {
            qWarning() << "[ADBLOCK] engine not available — falling back to content blocker only";
        }
    }
}
```

In `onLoadingChanged()` (after `LoadSucceededStatus`), inject cosmetic filters
after a short DOM-settle delay:

```cpp
// Inside onLoadingChanged, after LoadSucceededStatus branch:
if (AdBlockEngine::instance().isLoaded()) {
    QTimer::singleShot(300, this, [this]() {
        AdBlockEngine::instance().applyCosmetics(this);
    });
}
```

**MODIFIED: `wpe.pri`** — Add new files and link flags

```diff
+ INCLUDEPATH += $${ATLANTIC_ADBLOCK_DIR}
+ LIBS += -L$${WPE_SFOS_PREFIX}/lib -latlantic_adblock

  HEADERS += \
+     $$PWD/AdBlockEngine.h \
      $$PWD/WPEWebPage.h \
      $$PWD/WPEWebContainer.h \
      $$PWD/WPEWebPageCreator.h

  SOURCES += \
+     $$PWD/AdBlockEngine.cpp \
      $$PWD/WPEWebPage.cpp \
      $$PWD/WPEWebContainer.cpp \
      $$PWD/WPEWebPageCreator.cpp
```

### 4.4 Phase 4 — CI Pipeline Changes

**Modified: `.github/workflows/build-atlantic-packages.yml`**

Add Rust toolchain installation to the workflow:

```yaml
- name: Install Rust toolchain
  uses: dtolnay/rust-toolchain@stable
```

(The build runner is already ARM64, so no cross-compilation target needed.)

Or, if not using the dtolnay action, install via rustup:

```yaml
- name: Install Rust
  run: |
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    echo "$HOME/.cargo/bin" >> $GITHUB_PATH
```

### 4.5 Phase 5 — Resource Type Mapping Refinement

**Problem:** The GLib `decide-policy` signal for `RESPONSE` type does not expose the
resource type (script, image, stylesheet, etc.). This limits filtering precision.

**Solution A (simpler, faster to ship):** Use the `resource-load-started` signal
instead, which fires in the UIProcess and reports the resource type via
`webkit_resource_load_get_response()` and the URI:

```cpp
// In WPEWebPage constructor, after web view creation:
g_signal_connect(wv, "resource-load-started",
    G_CALLBACK(+[](WebKitWebView*, WebKitResourceLoad* load, gpointer) {
        WebKitURIRequest* req = webkit_resource_load_get_request(load);
        WebKitURIResponse* resp = webkit_resource_load_get_response(load);
        // Block here with webkit_resource_load_set_cancelled()
    }), nullptr);
```

**Solution B (more precise, more work):** Use the `WebKitWebContext::initialize-web-extensions`
signal to inject a WebExtension into the WebProcess that intercepts all outgoing
requests with full resource-type information. This is how Brave does it. However,
this requires shipping a WebExtension shared library and handling cross-process
communication.

**Recommendation:** Start with Solution A for Phase 1. The heuristic fallback
(`"other"` type) still blocks ~90% of ad traffic since most ad resources have
distinctive URLs. A follow-up PR can switch to the WebExtension-based approach.

---

## 5. File Manifest

### New files

| File | Lines | Purpose |
|------|-------|---------|
| `atlantic-engine/adblock-engine/Cargo.toml` | ~10 | Rust project manifest |
| `atlantic-engine/adblock-engine/src/lib.rs` | ~250 | C FFI layer |
| `atlantic-engine/adblock-engine/src/bin/builder.rs` | ~30 | Filter list compiler binary |
| `atlantic-browser/apps/wpe/AdBlockEngine.h` | ~60 | C++ adapter header |
| `atlantic-browser/apps/wpe/AdBlockEngine.cpp` | ~130 | C++ adapter implementation |

### Modified files

| File | Lines changed | Change |
|------|---------------|--------|
| `WPEWebPage.cpp` — `onDecidePolicy()` | ~40 changed | Replace hardcoded 20-domain list with adblock-rust matching |
| `WPEWebPage.cpp` — constructor | ~15 added | Singleton engine init |
| `WPEWebPage.cpp` — `onLoadingChanged` | ~10 added | Cosmetic injection after page load |
| `wpe.pri` | +6 lines | Add AdBlockEngine files, link `-latlantic_adblock` |
| `build-rpms-native.sh` | +25 lines | Build Rust crate, fetch annoyance lists, stage .so + .dat |
| `build-atlantic-packages.yml` | +5 lines | Install Rust toolchain |
| `versions.env` | +4 lines | Add Fanboy's Annoyance + uBO Annoyances URLs |

### Removed / deprecated

| File | Action |
|------|--------|
| `easylist-to-webkit.py` | Keep as fallback; its output (`content-blocker.json`) is still installed |
| `WPEWebPage.cpp` hardcoded 20-domain list | Removed — replaced by adblock-rust |

### Total footprint

- **New code:** ~480 lines (Rust) + ~190 lines (C++) = ~670 lines
- **Modified code:** ~100 lines
- **New binary:** `libatlantic_adblock.so` (~2–4 MB)
- **New data:** `engine.dat` (~10–20 MB, in RPM)

---

## 6. Memory & Performance Budget

| Metric | Estimate | Notes |
|--------|----------|-------|
| `libatlantic_adblock.so` (stripped) | 2–4 MB | ARM64 release build |
| `engine.dat` (cached FlatBuffers) | 10–20 MB | EasyList + EasyPrivacy + Annoyances |
| Runtime RSS (in WebProcess) | +5–10 MB | Data structures after deserialization |
| Cold start (deserialize) | < 100 ms | FlatBuffers zero-copy |
| Per-request match | < 10 µs | Token-based matching, pre-compiled regex |
| Cosmetic injection per page | ~1 ms | DOM style injection via JS |

**Device budget:** Xperia 10 II (Snapdragon 665, 4 GB RAM, ~1.5 GB free).
Total adblock overhead: ~25–35 MB RSS, well within budget.

---

## 7. Edge Cases & Defensive Design

### Engine fails to load
- Fall back to the existing WebKit content blocker (`content-blocker.json` via `ensureContentBlocker`).
- The `onDecidePolicy` handler checks `AdBlockEngine::instance().isLoaded()` before querying.
- Log a warning, browser proceeds with degraded blocking.

### engine.dat older than filter lists (manual update)
- Provide a `DBus` method to trigger filter list download + engine rebuild at runtime (future enhancement).
- For now, filter lists are updated with each RPM release (daily CI).

### Memory pressure on device
- The `adblock-rust` crate supports regex discard policies. Infrequently-matched regexes can be dropped to reduce memory.
- On a 4 GB device, this is not yet needed; consider if memory usage exceeds 50 MB.

### Cosmetic injection on every page navigation
- `url_cosmetic_resources()` is internally cached per domain by the Engine.
- Injection runs once 300 ms after `LoadSucceededStatus` — avoids injecting mid-render.
- The `__atl_adblock_*` element IDs prevent duplicate style injection on re-navigation.

### Blocking the main frame
- `onDecidePolicy` checks `webkit_response_policy_decision_is_main_frame_main_resource()` and returns FALSE — never blocks the top-level document. This prevents accidentally blocking the page itself from a false-positive filter.

---

## 8. Testing Plan

### Unit tests
- Add Rust unit tests for the FFI layer (create engine from sample rules, match test URLs).
- Add C++ unit tests for `AdBlockEngine` class (mock engine, verify `shouldBlock` logic).

### Integration tests
- Build the RPM, deploy to device.
- Navigate to known ad-heavy sites (cnn.com, reddit.com, theverge.com) and verify:
  - No banner ads visible
  - No cookie consent popups
  - Console log shows `[ADBLOCK] blocked ...` for known ad domains
- Navigate to legitimate sites (github.com, wikipedia.org) and verify:
  - No false-positive blocking
  - All page functionality intact

### Performance tests
- Measure RPM size increase (expected: ~15–25 MB for engine.dat + .so).
- Measure cold-start time to first interactive (expected: no measurable regression).
- Measure per-page memory delta with/without adblock (expected: +10–30 MB).

### Regression tests
- Verify content-blocker.json fallback still works when engine.dat is absent.
- Verify the existing decide-policy new-window behavior is unchanged.
- Verify download handling is unaffected.

---

## 9. References

| Resource | URL |
|----------|-----|
| adblock-rust repo | https://github.com/brave/adblock-rust |
| adblock-rust docs (docs.rs) | https://docs.rs/adblock/latest/adblock/ |
| Brave's C++ integration | `brave-core/components/brave_shields/core/common/adblock/rs/` |
| EasyList | https://easylist.to/easylist/easylist.txt |
| EasyPrivacy | https://easylist.to/easylist/easyprivacy.txt |
| Fanboy's Annoyance | https://secure.fanboy.co.nz/fanboy-annoyance.txt |
| uBO Annoyances | https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/annoyances.txt |

---

## 10. License Compliance

- **adblock-rust:** MPL-2.0 — file-level weak copyleft. Modifications to Rust source files in `adblock-engine/` must remain MPL-2.0.
- **Atlantic Browser:** MPL-2.0 — no conflict. The C++ adapter code (`AdBlockEngine.h/.cpp`) is new Atlantic Browser code under its own MPL-2.0.
- **Filter lists:** EasyList/EasyPrivacy are CC BY-SA 3.0. Fanboy's Annoyance is CC BY 3.0. uBO Annoyances is GPL-3.0. Filter lists are data consumed at runtime; their licenses apply to redistribution of the .dat cache, which is permissible under the CC licenses (attribution in about page / documentation).

## The 0.13 startup regression (build 633/634) — root cause and fix

Builds 633 and 634 would not start. The browser reached the end of startup —
runtime loaded, engine loaded, seccomp installed, WebProcess up, frames
rendering — and then the UI process's Qt Wayland connection died with
`Connection reset by peer` / "the display is now unusable, aborting". It looked
like a graphics fault, and it was not.

**Cause: the FFI is declared in two repos and only one was updated.**
`atlantic_adblock_match_network` is declared here in
`web-extension/atlantic-adblock-extension.c` *and* independently in the browser
repo's `apps/wpe/AdBlockEngine.h`, which links `-latlantic_adblock`. The 0.13
bump added the `http_method` parameter and updated only the first. The browser
went on calling the five-argument form, so on aarch64 the callee read
`http_method` out of `x5` — a register the caller never set — and `str_from_c()`
dereferenced whatever was in it, walking memory to the first NUL. That call sits
on `AdBlockEngine::shouldBlockPopup()`, which despite the name runs from the
decide-policy handler for *every* navigation, so it fired as soon as the
restored tab loaded and corrupted the UI process out from under its Wayland
connection.

**How it was found.** Bisected on-device against the RPMs kept under
`/opt/github-runner/builds/`: 631 OK, 632 OK, 633 dead — so the 117 -> 39 patch
consolidation was not involved. Moving `engine.dat` aside on 633 made it start,
which narrowed it to "the engine is loaded". Three hypotheses were then killed
by measurement rather than argument: peak WebProcess RSS was 97 MB against a
2048 MB cgroup (not memory), peak fds 77 against a 1024 limit (not fds), and
`dmesg` was silent (not the kernel allocator). The decisive test was building a
**973-byte** valid v5 `engine.dat` with the 0.13 builder: it still died, which
ruled out payload size and pointed at the call path itself rather than the data.

**Fix.** The browser passes the method, and the symbol is renamed
`atlantic_adblock_match_network_v2`. The rename is the important half: with two
hand-maintained copies of one ABI, a signature change that updates only one side
is otherwise a silent out-of-bounds read. Now it is a link error — verified by
compiling the old five-argument declaration against the new library, which fails
with `undefined reference to 'atlantic_adblock_match_network'`. **Bump the
suffix on every future signature change**, and update both repos together.
