# WebExtensions support

> **Status: IMPLEMENTED, not yet device-verified.** Landed in
> `atlantic-browser/apps/wpe/WebExtension*` plus `qml/pages/ExtensionsPage.qml`.
> Nothing in the engine repo changed — this is entirely UI-process work on top of
> APIs WPE WebKit 2.52 already exposes. `cookies`, `history`, `bookmarks` and
> `downloads` landed later than the rest and are the least exercised part
> (§3d, §3e).

**Date:** 2026-08-27

---

## 1. What ships

Atlantic loads unpacked WebExtensions and `.zip` / `.xpi` packages, MV2 and the
practical subset of MV3, from
`~/.local/share/org.sailfishos/browser/extensions/<id>/`. Settings → Extensions
lists them, toggles them, removes them and installs new ones from a file.

| Piece | Where |
|---|---|
| Manifest model, match patterns, `_locales` | `WebExtension.h/.cpp` |
| Registry, scheme handler, content-script install, API dispatch, list model | `WebExtensionManager.h/.cpp` |
| Background context (JSC) | `WebExtensionBackground.h/.cpp` |
| `browser.*` / `chrome.*` shim + background polyfills (JS) | `WebExtensionScripts.h` |
| Tab APIs | `WPEWebContainer` implements `WebExtensionHost` |
| `cookies` | `WebExtensionCookies.cpp` over the default session's `WebKitCookieManager` |
| `history`, `bookmarks` | `WebExtensionBrowsingData.cpp` over `DBManager` and the live `DeclarativeBookmarkModel` |
| `downloads` | `WebExtensionDownloads.cpp` over `DownloadManager`'s per-download records |
| UI | `apps/browser/qml/pages/ExtensionsPage.qml` |
| AMO search and install | `WebExtensionStore.h/.cpp`, `qml/pages/ExtensionStorePage.qml` |

## 2. Why it looks like this

### Content scripts are WebKit user scripts

`webkit_user_script_new_for_world()` takes an allow list and a block list of
**URL patterns**, and WebCore's `UserContentURLPattern` is the same
`scheme://host/path` syntax Chrome calls a match pattern. So `content_scripts`
maps across almost unchanged — the only translation needed is `<all_urls>`,
which WebKit does not know, expanded to `http://*/*` + `https://*/*`
(`expandPatterns()`).

Each extension gets its own script world, `atlantic-ext-<sanitized id>`, so page
JS can neither read the extension's state nor forge messages on its channel.
That is the same isolation the password-autofill bridge already relies on
(`WPEWebPage::kLoginScriptWorld`).

`run_at: document_idle` has no WebKit equivalent and is mapped to
document-end, which is what the other WebKit ports do.

### The background context is a hidden web view (with a JSC fallback)

**This reverses the original decision below, and the reversal was earned on the
device.** Background scripts first ran in a bare `JSCContext`. That is enough for
service-worker-shaped extensions — the smoke-test extension round-trips content
script to background and back under it — and it is not enough for the many
Firefox extensions whose background is an MV3 *event page*: a real document with
DOM, `localStorage`, `Blob`, `Worker`, `XMLHttpRequest` and IndexedDB.
LanguageTool is one, reaching for `document` 52 times.

How that failure looked, which is worth knowing because none of it says "no
DOM": the background script ran to completion, registered its listener, received
`CHECK_TEXT` with the right text, returned a promise — and that promise never
settled. No exception, no rejection, no network call, and a recording Proxy
showed it touching no DOM global at all during the check. It had simply settled
into a permanent not-ready state during initialisation, and every check queued
behind it in silence.

So a background page now gets a genuine `WebKitWebView` that is never displayed,
built on a **non-EGL** `wpe_view_backend_exportable_fdo` whose exported frames
are released and acknowledged immediately. WebKit believes it has a compositor
and lays out and paints as usual; the pixels go nowhere. Every frame must be
acked or painting stops after the first one and anything gated on rendering
stalls — the same trap in a different costume.

`background.scripts` extensions get a synthesised
`_generated_background_page.html` from the scheme handler, exactly as Chrome and
Firefox do. The page runs the same API shim as any extension page, posting over
`window.webkit.messageHandlers`, so the manager's routing did not change: a null
page still means "the background context".

Cost: a WebProcess per background page. That is the price of running an
extension the way it was written. The JSC host stays as the fallback for when an
offscreen backend cannot be created, and its polyfills below still apply there.

### Why it was JavaScriptCore first

The obvious design — an offscreen `WebKitWebView` loading a generated background
page — needs a real `wpe_view_backend`, which on this platform means a working
FDO backend and a compositor surface for a view nobody will ever see. An MV3
service worker has no DOM anyway, and neither do most MV2 background scripts in
practice.

So background scripts run in a plain `JSCContext` in the UI process
(`jsc_context_new()`, from the JSC GLib API that `libWPEWebKit-2.0` already
exports). The environment they actually depend on is polyfilled onto the same
bridge the API shim uses: `setTimeout`/`setInterval` (QTimer), `console`,
`fetch`/`XMLHttpRequest` (QNetworkAccessManager), `atob`/`btoa`.

Consequence: a `background.page` HTML file has its `<script src>` list extracted
and run; **inline `<script>` bodies are not executed**, and the extension is
warned about in the log when it has any.

### One bridge for everything

JS never calls C++ directly. Content scripts post
`{seq, api, args}` on `window.webkit.messageHandlers.atlExt_<id>`; the background
context calls the single native `__atlNative(json)`. The UI process answers by
evaluating `__atlExtBridge.dispatch(...)` — in the right script world for a page,
or in the JSC context for the background.

Everything above that layer (promise-vs-callback duality, `Event` objects, ports,
storage areas, `i18n` substitution, `alarms`) is implemented in the JS shim, so
the C++ side only ever sees flat API calls. That is why `WebExtensionScripts.h`
is the biggest file in the set and `dispatchApiCall()` is a flat if-chain.

### Extension pages get the shim in their *own* world

A popup or options page is a normal tab on `atlantic-extension://<id>/…`. It
needs `browser.*` in the page's own world, not an isolated one, so each extension
registers a second handler (`atlExtPage_<id>`, default world) with an allow list
of just its own origin. `runtime.sendMessage` therefore reaches background +
extension pages, and `tabs.sendMessage` reaches content scripts — the same split
Chrome has.

### Scheme security traits

`atlantic-extension` is registered **secure** and **CORS-enabled**, and
deliberately *not* `local` or `no_access`: both would strip the origin that
extension pages need for storage and for fetching their own resources. The
handler enforces two things the scheme registration cannot: a path-traversal
guard (resolved path must stay under the extension directory) and
`web_accessible_resources` for requests that do not come from a page of the same
extension.

One deliberate hole: a popup or options page opens as an ordinary tab, and at
the moment of that top-level navigation the requesting view still reports the
*previous* page's URL — the handler cannot tell it from a web page fetching the
same file. The declared popup and options pages are therefore always served, so
a hostile page could iframe one. Extensions that keep secrets in a popup are
mis-designed anyway, but this is the trade we took rather than making every
popup require a `web_accessible_resources` entry.

## 2b. Where extensions come from

The store is a **search over addons.mozilla.org** and nothing else. Nothing is
mirrored and nothing is recommended: there is no shipped list, and `install()`
has no verdict gate. Packages come from AMO's public v5 read API — no key, no
account.

**A curated catalog used to ship** (`data/extension-catalog.json`, a list of AMO
slugs with reviewed verdicts and hand-written notes) and was removed: a
recommendation nobody had run on the device is a promise the project could not
keep, and it made the first screen of the store an endorsement rather than a
search box. The rot guard it needed is gone with it; what remains is a test over
the *rule*, not over a list (`tests/test_extension_store.py`).

**Verdicts are derived, not guessed.** AMO reports each add-on's declared
permissions *before* download, so `WebExtensionStore::verdictFor()` classifies
every search result against two tables:

- **broken**: `webRequest`, `webRequestBlocking`, `declarativeNetRequest`,
  `proxy`, `dns` — the add-on's whole point is something we do not do.
- **partial**: `webNavigation`, `management`, `idle`, `browsingData`, … — it
  loses a feature, not its purpose. `contextMenus`, `scripting`, `cookies`,
  `history`, `bookmarks` and `downloads` have been taken *out* of this table as
  they landed; the table is the one the store reads, so it has to track what is
  actually implemented.

**Only a bad verdict is shown.** "Works" and "Unknown" print nothing at all: the
verdict is derived from declared permissions, not from anybody running the
add-on, so a green label would be a promise the page cannot make. A row either
warns or is silent.

That derivation is also the sobering finding: the popular end of the extension
ecosystem is built on `webRequest`. uBlock Origin, Tampermonkey, Violentmonkey,
Stylus, To Google Translate and Search by Image all come out **broken** — which
the user now sees on the row before installing, rather than in a catalog entry.

Integrity: AMO publishes `current_version.file.hash` as `sha256:<hex>`, checked
before the package is handed to `WebExtensionManager::install()`. A mismatch
refuses the install. The one path without that check is the deliberate escape
hatch — pasting a direct `.xpi` URL — and the UI says so in the dialog.

Verified against the live API while building this: `name`/`summary` come back as
`{"en-US": …}` objects even with `lang=` set, and `current_version.file` is
singular in v5 (older responses use `files[]`).

**AMO packages need their own extractor — `QZipReader` cannot read them.** This
cost a device round trip. Mozilla's signing pipeline repacks add-ons as
*streamed* zips: general-purpose flag bit 3 is set on every entry, so each local
file header carries `crc = 0`, `compressed size = 0`, `uncompressed size = 0`,
with the real values in a data descriptor after the data and in the central
directory. Qt 5.6's `QZipReader` takes its sizes from the local header, so it
reports the right entry count, extracts exactly one file and then fails the
archive — surfacing as "darkreader.xpi is not a readable extension archive".

The check that missed it was mine: I confirmed the format with Python's
`zipfile`, which reads the central directory and therefore sails through. **A
format check has to be run with the reader that will actually do the reading.**
`WebExtensionArchive` takes everything from the central directory, which is
correct for streamed and ordinary zips alike, and rebases every offset on the
delta between where the central directory claims to be and where it is — which
also makes a `Cr24`-prefixed `.crx` work, so the `*.crx` file filter is no
longer a claim we cannot back.

Measured after the fix, running the real extractor over real packages: Dark
Reader 93 files / 3.1 MB, uBlock Origin 659 files / 15.6 MB, a `.crx`-prefixed
copy, and a `../../../../etc/pwned` archive refused outright. The old path on
the same Dark Reader package: `isReadable=1`, `entries=93`, `extractAll=0`, one
file written.

## 3. What is deliberately not supported

These are inert rather than absent: calling a method rejects with a clear
message, and `addListener` on their events is accepted silently. Extensions
routinely register `webRequest` listeners at top level, and throwing there kills
the whole background script instead of degrading one feature.

| API | Why |
|---|---|
| `webRequest`, `declarativeNetRequest` | Network blocking lives in the Rust adblock WebProcess extension (`web-extension/`), which sees every subresource. The UI process does not, and there is no supported way to hand a per-request veto to extension JS across that boundary. Re-opening this means designing an IPC path from the WebProcess extension into the UI process on the hot request path — measure before believing it is affordable. |
| `proxy`, `idle` | Not wired to anything, and neither has an Atlantic subsystem to wire to. (`cookies`, `history`, `bookmarks` and `downloads` used to be in this row — see §3d and §3e.) |
| `management` beyond `getSelf` | An extension may ask about itself; enumerating or disabling others is deliberately not offered. |
| MV3 service-worker lifecycle | No worker, no `onInstalled` update reasons, no event-driven wake. `runtime.onStartup` fires on every launch. |
| Anchored action popups | Popups open as an ordinary tab. |

Each of these that an installed extension asks for is surfaced as a per-extension
warning in Settings → Extensions, so a degraded extension is visibly degraded
rather than mysteriously broken.

## 3b. contextMenus and scripting

Both landed after the first pass and are no longer inert.

**`scripting`** (and the MV2 `tabs.executeScript` / `insertCSS` / `removeCSS`)
rides the world-scoped evaluation that was already there:
`webkit_web_view_evaluate_javascript()` takes a world name, so an injection runs
in the extension's own isolated world by default and in the page's when the
caller asks for `world: "MAIN"`. A function passed to `executeScript` cannot
cross the bridge, so the shim sends `func.toString()` and the page side
re-creates it — which is also why, exactly as in a real browser, such a function
must not close over anything. Results come back through
`jsc_value_to_json()`. `registerContentScripts` stores into the entry and is
replayed by `installIntoPage()`, so dynamically registered scripts behave like
manifest ones on the next load.

Two traps in that wiring, both caught before they shipped: an extension whose
*only* injection route is `registerContentScripts` was being skipped entirely,
because `installIntoPage()` bailed out when the manifest declared no content
scripts; and the shim's allow-list was built from manifest matches alone, so
`browser.*` would have been undefined in a dynamically registered script.

**`contextMenus`** needed a surface as well as an API — Atlantic has no menu bar,
and the only long-press UI was the image panel. The `contextmenu` DOM event was
already the dependable long-press signal (the JS touch timer gets pre-empted by
the compositor), so the existing bridge script now reports link URL, editable
state and selection alongside the image URL, and `ImageActionPanel` became the
general long-press panel: built-in actions plus whatever items match. Item
matching follows the API — `contexts`, `documentUrlPatterns`, `targetUrlPatterns`,
`%s` substitution from the selection — and an extension only gets to offer items
where it has host access anyway. `onClicked` goes to the background context
only, as in Chrome.

Not covered: submenus are flattened (`parentId` is recorded and reported in
`info`, but the panel is one level), and `onShown`/`onHidden` stay inert.

## 3c. Later additions

- **`runtime.onInstalled`** now fires. The registry records each extension's
  version, so a first sighting reports `install` and a version change reports
  `update` with `previousVersion`. Both are emitted only after every background
  context is up and its listeners registered, then the registry is written so
  the same event is not replayed next launch. `onStartup` moved out of
  `WebExtensionBackground::start()` to the manager for that ordering — leaving
  it in place would have fired it twice.
- **`webNavigation`** rides the load-changed states already connected on each
  view: `onBeforeNavigate`, `onCommitted`, `onCompleted`. Main frame only, and
  the frame-scoped calls answer for frame 0 — WebKit gives us no per-subframe
  signal here, and inventing frame ids would be worse than reporting none.
  Delivered only to extensions with host access or the `webNavigation`
  permission.
- **`management.getSelf`**; the rest of that namespace stays refused on purpose.
- **`notifications.create`** actually shows something. It had been resolving
  with an id and emitting `notificationRequested` into thin air — nothing was
  connected. `BrowserPage.qml` now publishes a Nemo notification.

The last one is worth generalising into a habit: a signal with no consumer is
indistinguishable, from the extension's side, from an API that silently does
nothing. `action.setBadgeText` is still in that state — the state is stored, but
there is no toolbar surface to draw a badge on.

## 3d. cookies, history and bookmarks

All three are implemented, each against the browser's own subsystem rather than
a store of its own. Permission gating follows the real browsers: `cookies` needs
the `cookies` permission *and* host access to the cookie's URL; `history` and
`bookmarks` are covered by their permission alone.

**`cookies`** (`WebExtensionCookies.cpp`) sits on the default network session's
`WebKitCookieManager`. `get`/`getAll` come from
`webkit_cookie_manager_get_cookies` (a URL was given) or `get_all_cookies` (it
was not), and the results are filtered twice: by the caller's `details`, and by
host access — a cookie the extension may not see is dropped from the list rather
than failing the call. `set` builds a `SoupCookie`; `remove` reads the cookie
first so it can hand back what it deleted, as the API promises.

Three things are worth knowing before touching it:

- **One store.** Private tabs run on an ephemeral session, and it is not
  exposed: `getAllCookieStores` reports `"0"` only, and any other `storeId` is
  an error rather than a silent read of the wrong jar.
- **`onChanged` is not the browser's.** WebKit emits no cookie-change signal, so
  the event fires for mutations that went through this API and never for a
  cookie a page set. An extension that watches for third-party cookies being
  written will see nothing.
- **`add_cookie`/`delete_cookie` copy into a `WebCore::Cookie` before they
  return**, so the `SoupCookie` is ours to free straight after the call; the
  async callback must not touch it.

**`history`** goes through `DBManager`. The existing `getHistory()` was no use:
it hard-limits to 20 rows, drops `visited_count`, keeps only a `QDate`, and
answers on a **broadcast** signal that the history page also consumes, so
replies could not be told apart. `DBWorker::searchHistory()` was added instead —
tagged with a request id, ranged, with a caller-chosen limit, returning
`lastVisitTime` in ms and `visitCount` — plus `deleteHistoryRange()`.

The shape that does not survive: Atlantic stores **one row per URL**, not one
row per visit. `getVisits()` therefore reports a single visit (the last one)
with the real count alongside, instead of inventing timestamps for the visits in
between. `onVisited` is fired from the load-finished handler in `WPEWebPage`,
which is when the visit is actually recorded — and never for a private tab,
which records nothing.

**`bookmarks`** writes through the live `DeclarativeBookmarkModel`, not through
`BookmarkManager::save()`. Saving the file directly would have been simpler and
wrong: the QML model holds its own copy of the list and saves over it on the
next change, so an extension's bookmark would vanish at the next edit.
`DeclarativeBookmarkModel::primaryInstance()` (first model created wins) is how
the host reaches it.

Bookmarks are a flat list, so the tree is synthesised: a root with one folder
(`toolbar_____`) holding everything. `create` refuses to make folders rather
than quietly making a bookmark instead, `move` is unsupported, and ids are
opaque `atl-bm-N` strings that stay stable for the session. There are no
creation timestamps in the store, so `dateAdded` is 0 and `getRecent` answers in
list order — honest, and not what a real bookmark store would say.

## 3e. downloads

`DownloadManager` already drives every transfer, but nothing could ask it what
had been downloaded: its bookkeeping is keyed by transfer id and dropped on
completion, and the transfer engine owns the UI, not a queryable list. So it
gained a `Record` per download — url, path, mime, state, bytes, start/end time —
maintained in the handlers that already exist (`prepareDownload`,
`confirmDownload`, `updateDownload`, `finalizeDownload`) and published through
three signals. `WebExtensionDownloads.cpp` is a reader of that.

`download()` starts a transfer nothing on a page asked for, via
`webkit_network_session_download_uri()` on the default session, which raises
`download-started` and therefore lands in the same handlers as any other
download. The one difference is the destination: a page download prompts, and an
API caller has nobody to answer the prompt, so `startDownload()` records the
intended name in `m_autoDestination` *before* `decide-destination` can fire and
`prepareDownload()` settles the path itself when it sees it. `saveAs: true` opts
back into the prompt.

Limits, all deliberate:

- **`filename` must be a bare name.** A path with a `/` in it is refused — the
  API only promises a name below the download directory, and this is the one
  call where an extension could otherwise choose where to write.
- **No custom `headers` or POST body.** The session builds the request, not us;
  the call is refused rather than silently sending a plain GET.
- **`pause`/`resume` do not exist** in WebKit's download API, so they reject
  instead of lying; `paused` is always false and `canResume` always false.
- **`open`, `show`, `showDefaultFolder`, `getFileIcon`** have nothing to hand a
  file to on this platform yet.
- **Records are per-session.** The download/transfer mappings were never
  persistent (there is a standing TODO about it), so `search()` answers about
  this run of the browser. Persisting them would be the same work as making
  restartable transfers work, and belongs with that.
- **`erase` refuses a running download**, since dropping the record would leave
  a live transfer nothing can be matched back to.
- `onChanged` reports a delta of state/error/filename/exists/totalBytes/endTime.
  Progress is not in it — it moves on every network chunk, and Chrome leaves it
  out too.

## 4. Things that bit, worth not rediscovering

- **`signals`.** Any header that pulls in GLib after Qt has to be wrapped in
  `#pragma push_macro("signals") / #undef signals / pop_macro` — gio's
  `GDBusSignalInfo **signals` collides with Qt's keyword. The repo already had a
  `gio/gdbusintrospection.h` shim for this; the new headers carry the guard
  inline so they are usable from anywhere.
- **Qt 5.6.3, not 5.15.** No `QString::chopped`, no `qAsConst`, and
  `QNetworkAccessManager::sendCustomRequest` has no `QByteArray` overload — it
  needs a `QIODevice` that outlives the call.
- **The upstream WebExtensions API is present but hollow.** WPE 2.52 installs
  `WebKitWebExtension.h` and `WebKitWebExtensionMatchPattern.h`, and the symbols
  are in `libWPEWebKit-2.0.so` — but `ENABLE_WK_WEB_EXTENSIONS` defaults OFF and
  the `#else` branch compiles every entry point as `return nullptr`. Measure the
  symbol sizes before believing it: ours are 8 and 12 bytes, and there are zero
  `WebExtensionMatchPattern` implementation symbols in the library. Even with
  the flag on, `UIProcess/Extensions/API/glib` and `API/wpe` are empty
  directories — there is no controller API, so the extension engine itself is
  not reachable from this port and the browser has to be it.
- **`QByteArray + gchar*` is ambiguous**, and one of the candidates is pointer
  arithmetic. `QByteArray("[") + json + "]"` compiles with a warning and could
  have silently produced garbage; build it with explicit `append()` calls.
- **`QVector<T>::erase` instantiates a `memmove` branch** over any `T`, tripping
  `-Wclass-memaccess` for structs holding QStrings even though the branch is
  never taken. `QList` is the cheap way out for small registries.
- **Extension ids appear in URLs and in GObject signal details.** They are
  derived once (gecko id if declared, else a slug plus a hash of the *name* so
  the id survives version bumps) and sanitized to `[a-z0-9._-]`; world names and
  handler names sanitize further, to `[A-Za-z0-9_]`.
- **The sandbox path must exist before it is added.**
  `addSandboxPathIfExists()` silently skips a missing directory, so
  `registerUriScheme()` creates the extensions directory — it runs earlier in
  `configureSandboxPaths()` than the sandbox additions do.
- **One handler name may only be registered once per user-content manager**,
  which is why content scripts and extension pages use different names rather
  than the same name in two worlds.

## 5. Not yet verified on device

Nothing here has run on the Xperia yet. The first pass should be, in order:

1. An extension with content scripts only (CSS + JS, `document_start` and
   `document_end`) — proves the world, the match patterns and the shim.
2. `storage.local` round-trip from a content script, then read it back from the
   background context — proves the bridge in both directions.
3. `runtime.sendMessage` content → background with a `sendResponse`, and
   `tabs.sendMessage` the other way — proves the pending-message bookkeeping,
   including the "no receiver" and "receiver declined to answer" paths.
4. A popup page that calls `browser.tabs.query({active: true})` — proves the
   main-world handler and the tab APIs.
5. Install and remove a `.zip`, then restart — proves the registry.

`atlantic-browser/tests/sample-extension/` is a smoke-test extension that
exercises all five in one go; its README says what each observable proves.
`node atlantic-browser/tests/webextension-shim.test.js` covers the JS shim and
the background preamble on the host (56 assertions, no device needed).
`python3 atlantic-browser/tests/test_extension_store.py` checks the verdict
rule; with `ATLANTIC_STORE_ONLINE=1` it re-derives uBlock Origin's verdict from
AMO's current permissions, the canary for the tables drifting from the
ecosystem. It parses those tables out of `WebExtensionStore.cpp` rather than
copying them, so the test cannot drift from the shipped rule either.

`cookies`, `history`, `bookmarks` and `downloads` need their own pass — nothing about them
has run on the device:

9. From a background page with `cookies` + a host permission: `getAll` for that
   host, `set` a cookie, read it back with `get`, `remove` it, and check that
   `onChanged` fired twice. Then `getAll` with no `url` and confirm hosts the
   extension has no permission for are absent from the list.
10. With `history`: browse two pages, then `search({text})` and check the visit
    counts and `lastVisitTime`; `deleteUrl` one of them and confirm it leaves
    the history page too. Browse in a private tab and confirm no `onVisited`.
11. With `bookmarks`: `create`, then check the bookmark appears in the UI
    *without* a restart (that is the whole reason it writes through the model),
    `update` it, `remove` it.
12. With `downloads`: `download({url})` and confirm the file lands in the
    download folder with **no Save As prompt**, that the transfer shows in the
    Sailfish transfer UI as usual, and that `onCreated` then `onChanged` to
    `complete` arrive. Then `search({})` for it, `removeFile`, and `erase`.
    Separately: a page-initiated download must still prompt.

Store-specific device checks, on top of the five above:

6. Open Settings → Extensions → Get extensions: the page should open on the
   search box with no list, and offline a search should fail with a message
   rather than an empty page that looks broken.
7. Search for an add-on that comes out `broken` (uBlock Origin) — it must warn
   and still install; then one with a clean verdict, which must say nothing
   about compatibility at all.
8. Paste a direct `.xpi` URL, which should install with the unverified-package
   warning.
