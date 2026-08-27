# WebExtensions support

> **Status: IMPLEMENTED, not yet device-verified.** Landed in
> `atlantic-browser/apps/wpe/WebExtension*` plus `qml/pages/ExtensionsPage.qml`.
> Nothing in the engine repo changed — this is entirely UI-process work on top of
> APIs WPE WebKit 2.52 already exposes.

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
| UI | `apps/browser/qml/pages/ExtensionsPage.qml` |

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

### The background context is JavaScriptCore, not a hidden web view

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

## 3. What is deliberately not supported

These are inert rather than absent: calling a method rejects with a clear
message, and `addListener` on their events is accepted silently. Extensions
routinely register `webRequest` listeners at top level, and throwing there kills
the whole background script instead of degrading one feature.

| API | Why |
|---|---|
| `webRequest`, `declarativeNetRequest` | Network blocking lives in the Rust adblock WebProcess extension (`web-extension/`), which sees every subresource. The UI process does not, and there is no supported way to hand a per-request veto to extension JS across that boundary. Re-opening this means designing an IPC path from the WebProcess extension into the UI process on the hot request path — measure before believing it is affordable. |
| `webNavigation` | Would need per-frame navigation signals we do not surface. |
| `cookies`, `downloads`, `history`, `bookmarks`, `management`, `proxy`, `idle` | Not wired to the corresponding Atlantic subsystems yet; each is a self-contained follow-up. |
| `contextMenus` / `menus` | No extension-populated context menu in the UI. |
| `scripting`, `tabs.executeScript`, `tabs.insertCSS` | Dynamic injection needs a user-script add/remove path per call; static `content_scripts` cover the common case. |
| MV3 service-worker lifecycle | No worker, no `onInstalled` update reasons, no event-driven wake. `runtime.onStartup` fires on every launch. |
| Anchored action popups | Popups open as an ordinary tab. |

Each of these that an installed extension asks for is surfaced as a per-extension
warning in Settings → Extensions, so a degraded extension is visibly degraded
rather than mysteriously broken.

## 4. Things that bit, worth not rediscovering

- **`signals`.** Any header that pulls in GLib after Qt has to be wrapped in
  `#pragma push_macro("signals") / #undef signals / pop_macro` — gio's
  `GDBusSignalInfo **signals` collides with Qt's keyword. The repo already had a
  `gio/gdbusintrospection.h` shim for this; the new headers carry the guard
  inline so they are usable from anywhere.
- **Qt 5.6.3, not 5.15.** No `QString::chopped`, no `qAsConst`, and
  `QNetworkAccessManager::sendCustomRequest` has no `QByteArray` overload — it
  needs a `QIODevice` that outlives the call.
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
the background preamble on the host (32 assertions, no device needed).
