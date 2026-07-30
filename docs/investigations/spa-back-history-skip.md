> **Status: SHIPPED, A/B verified build 618** — WebKit skips pushState back/forward items without user-gesture attribution. Fix navigates to the adjacent back/forward list item; gated by `ATLANTIC_STRICT_HISTORY_NAV`, default OFF.

# SPA back button jumps to previous website, 2026-07-26 (build 617)

Symptom (user): in a single-page app, the toolbar back button leaves the site
entirely instead of going back one in-app route.

## CONFIRMED
- Back path is clean and single: ToolBar.qml `onTapped` -> `webView.goBack()` ->
  `WPEWebContainer::goBack()` -> `WPEQtView::goBack()` -> `webkit_web_view_go_back()`.
  `DBWorker::goBack(tabId)` (SQL tab_history) is legacy and NOT on this path.
  No engine patch in `patches/webkit/` touches session history.
- **Mechanism that can skip SPA entries**: `WebPageProxy::goBack()` uses
  `WebBackForwardList::goBackItemSkippingItemsWithoutUserGesture()`
  (WebBackForwardList.cpp:535-592). Any item whose
  `wasCreatedByJSWithoutUserInteraction()` is true is walked over, so a whole run
  of pushState entries collapses to the previous *document* in one press.
  This is upstream WebKit anti-history-trapping behaviour, not an Atlantic bug.
- Reproduced exactly that way on device: pushState issued from `atldbg eval`
  (no user gesture) -> one back press went `?step=two` -> page1.html, skipping 2
  same-document entries, while `history.back()` from JS moved 1 step correctly.
- **Not reproducible with genuine touch input on 617.** With taps via tap.py the
  toolbar back walks the SPA history one step at a time. All variants keep the
  gesture attribution: sync onclick, microtask, setTimeout 0/500/1200/3000/6000 ms,
  and after a fetch. Sequences verified: `?step=three -> ?step=two -> spa.html ->
  page1.html`, and `?fetchfail -> ?t500 -> ?t0 -> ?micro -> ?sync -> ""`.
  Test pages: scratchpad spa.html / spa2.html / spa3.html.
- Fix path exists without an engine patch, if needed:
  `webkit_web_view_go_to_back_forward_list_item()` -> `WebPageProxy::goToBackForwardItem()`
  does NOT skip (WebKitWebView.cpp:4000). So `WPEQtView::goBack()` could go to
  `webkit_back_forward_list_get_back_item()` explicitly for a strict one-step back.

## RULED OUT
- SQL/tab-model history driving back (code path unused).
- Multiple invocation of goBack per press (a single press moves exactly one step
  when entries are gesture-flagged).
- Engine patch interference with session history (no such patch).
- Gesture-token expiry on this port as the trigger (6 s delayed push still counts
  as user-initiated).

## OPEN
- Need the actual site/app where the user sees it: the surviving hypothesis is
  that that site's route changes are genuinely not gesture-attributed (pushes from
  timers/observers/redirects, or a router that pushes after a non-gesture event),
  which upstream WebKit then skips by design.
- Cheapest next experiment: load that site, tap through 2-3 in-app routes, press
  back once, and read `location.href` before/after via `atldbg eval`. If it skips,
  decide whether to make the toolbar back strict (one item, no skipping) - a
  qt5-plugin-only change, defaulted OFF behind an env flag per repo rules.

## CONFIRMED (2026-07-26, forum.sailfishos.org, build 617)
- **Bug reproduced with real touch input.** Tab history: `/` (real load) ->
  topic A `/t/release-notes-pispala-5-1-0-11/29751` (pushState) -> topic B
  `/t/no-ringback-tone-when-calling-with-volte/12361` (pushState), `history.length=3`.
  ONE toolbar back press from topic B landed on `/`, skipping topic A.
  `window.__mark` survived the press => same-document BF navigation, not a reload,
  so it is `goBack()` skipping items, not `loadPage(homePage)`.
- Matches `itemSkippingBackForwardItemsAddedByJSWithoutUserGesture` exactly: skipping
  engages only when the *current* item is flagged, then walks back over flagged items
  and stops at the first unflagged one — here the real `/` load. One-level-deep back
  (topic A -> `/`) looks correct only because the destination coincides.
- Flag is set in FrameLoader.cpp:1322 when
  `!document->hasRecentUserInteractionForNavigationFromJS()`, i.e. no gesture being
  processed AND no window activation within 10 s (Document.cpp:9732).
  Discourse's Ember router pushes therefore land unflagged-by-gesture; my synthetic
  pages did not, which is why they passed.
- Second, cosmetic bug found: the toolbar back icon shows the **home glyph** while
  several pushState routes deep. `WPEQtView::canGoBack` is `NOTIFY loadingChanged`
  (WPEQtView.h:41) and same-document navigations emit no load change, so the QML
  binding never re-evaluates. The tap handler re-reads the property fresh, so the
  *action* is still back — only the icon lies.

## RULED OUT (updated)
- `loadPage(WebUtils.homePage)` as the mechanism (marker survives the press).
- Gesture-token expiry as the trigger for synthetic pages (10 s sticky activation
  window covers even a 6 s delayed push).

## OPEN
- Residual uncertainty: "items present but skipped" vs "topic A never added to the
  UI-process list". Code path matches the former; the fix below discriminates —
  if going to the explicit back item lands on topic A, items were present.
- Proposed fix (needs approval): `WPEQtView::goBack()`/`goForward()` use
  `webkit_back_forward_list_get_back_item()` +
  `webkit_web_view_go_to_back_forward_list_item()`, which routes to
  `WebPageProxy::goToBackForwardItem()` with no skipping (WebKitWebView.cpp:4000).
  qt5-plugin only, no engine patch. Behind an env flag, default OFF, then 617 A/B.
  Trade-off: re-exposes the history-trapping that upstream skipping defeats.
- Also fix `canGoBack`/`canGoForward` notification so the icon stops showing home
  mid-SPA (drive it off the back-forward list's changed signal, or re-emit on
  same-document url change).

## IMPLEMENTED (2026-07-26, not yet built or device-verified)
- engine `77708fe` (qt5-plugin): `goBack()`/`goForward()` take the adjacent item via
  `webkit_back_forward_list_get_back_item()` + `webkit_web_view_go_to_back_forward_list_item()`
  when `ATLANTIC_STRICT_HISTORY_NAV=1` (default OFF); `canGoBack`/`canGoForward`
  moved to a new `backForwardChanged` NOTIFY driven by the back-forward list's
  "changed" signal + load changes; handler disconnected in the destructor.
- browser `0ac9ccda`: `WPEWebContainer` re-emits canGoBack/ForwardChanged on
  `WPEQtView::backForwardChanged`.
- API existence verified against the installed 2.52.5 headers and the
  `WebKitBackForwardList` "changed" signal in the CI source tree. NOT compiled:
  no local build tree, builds are CI-only, and both commits are unpushed.
- Verification plan once built: same forum flow (`/` -> topic A -> topic B), one
  back press. Flag OFF must still land on `/` (reproduces), flag ON must land on
  topic A. That also settles the OPEN "skipped vs never added" question: if ON
  still lands on `/`, topic A was never in the UI-process list.

## VERIFIED ON DEVICE (2026-07-26, build 618 = engine 77708fe + browser 0ac9ccda)
Installed by side-loading the CI RPMs (`rpm -Uvh` from
`/opt/github-runner/builds/30223131130-1/wpe-sfos-rpms`); the device could not
`zypper ref` because its wifi was behind a FortiGate TLS interceptor at the time.
`rpm -q` confirmed 618.1 for atlantic-browser, wpewebkit2, wpewebkit2-qt5.

Same flow both arms: forum home -> tap topic A -> tap its category link
(`/c/blog/31`), all three entries in one document (`history.length=3`), then one
toolbar back press. Tap targets computed from live `getBoundingClientRect()`
rather than fixed pixels, since the front page reflows between runs.

| Arm | ATLANTIC_STRICT_HISTORY_NAV | back from /c/blog/31 lands on | marker |
|-----|-----------------------------|-------------------------------|--------|
| A   | unset (default)             | `/` — topic A skipped (BUG)   | ALIVE  |
| B   | `1`                         | topic A (CORRECT)             | ALIVE  |

- Marker ALIVE in both arms = same-document BF navigation, not a reload.
- Arm B walks the rest correctly too: a further back press goes topic A -> `/`.
- **Settles the OPEN question**: the intermediate item WAS in the UI-process list
  and was being skipped, not missing. Skip theory confirmed.
- Icon fix confirmed: one pushState route deep the toolbar now renders the back
  arrow (screenshot `scratchpad/toolbar.png`); on 617 it showed the home glyph.
- Deterministic behavioural test, so n=1 per arm; no spread/noise-floor applies.

## STILL OPEN
- Default is still OFF. Flipping it is a product call: it makes SPA back match
  user expectation (and Chrome), at the cost of re-exposing the history-trapping
  that upstream's skipping defeats. Safari behaves like the OFF arm.
- Unrelated minor annoyance seen repeatedly: after the toolbar auto-hides, the
  first tap on the revealed back button is swallowed (a second tap works). Not
  investigated.

---
