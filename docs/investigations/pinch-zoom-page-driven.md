> **Status: SHIPPED, device-verified build 617** — Pages handle pinch (fixes maps); the browser gesture is the fallback. WebCore drops batched multi-touch, so the qt5 plugin serializes one touch per transition.

# Pinch-to-zoom broken on map pages, 2026-07-26

## CONFIRMED
- **Root cause: the UI process consumes every 2-finger gesture; the page receives
  ZERO touch events during a pinch.** Proof: diagnostic page
  (`/home/defaultuser/touchtest.html`, logs `e.touches.length` on every
  touchstart/move) reported `max concurrent: 0` after a scripted pinch
  (`pinch.py`, new 2-slot evdev tool), while a 1-finger swipe reported `max: 1`.
  Mechanism: `WPEWebPage::touchEvent` (WPEWebPage.cpp:3407-3449) — on
  `activePoints >= 2` it synthesizes a TouchEnd toward WebKit, applies a CSS
  `transform:scale()` on `documentElement`, `event->accept()`s, and on gesture
  end commits `webkit_web_view_set_zoom_level()`.
- **Committed page zoom ignores `user-scalable=no`.** The diagnostic page
  declares it; after the pinch the page rendered at ~3x page zoom (screenshot).
- **End-to-end repro on Google Maps (build 616, single instance, fresh
  screenshots each step):** pinch-out on the map did not change the map zoom
  level (same tiles, same labels) — instead the whole page (search box, chips,
  map canvas) rendered ~3x page-zoomed with blurry magnified tiles.
  Screenshots: scratchpad `maps-dismissed.png` (before) / `maps-after-pinch.png`.
- Engine CAN deliver multi-touch to pages: `WPEWebViewLegacy.cpp:331`
  `page.handleTouchEvent(nullptr, touchEvent)` forwards the full point list;
  the TouchGestureController only consumes a single fallback point, and only
  acts on unhandled (non-preventDefaulted) sequences via the ack path.

## RULED OUT
- Touch delivery broken in general — 1-finger touchstart/move reach the page
  (diagnostic `max: 1`; scrolling works everywhere).
- Google-Maps-specific (UA quirk etc.) — generic diagnostic page shows the same
  zero-delivery, so it is site-independent.

## CONFIRMED (fix round, all device-verified on locally-built lib+plugin)
- **Second root cause: WebCore drops batched multi-touch downs.** The qt5 plugin
  sent one wpe event per QTouchEvent with every point typed by the event-level
  type; WebEventFactory marks any point whose id != event->id Stationary, and
  EventHandler::handleTouchEvent (EventHandler.cpp:5427) treats a touchstart
  mixing Pressed + never-announced Stationary points as non-fresh -> the whole
  event is dropped (diagnostic page: max touches stayed 0 even with correct
  per-point types). Fix: serialize per libwpe contract - one wpe down/up per
  point transition, single motion per move batch (WPEQtViewBackend.cpp).
- **JS-ack hybrid works.** kPinchBridge (capture-phase, passive) posts a
  consumed/declined verdict per 2-finger sequence: consumed if the page
  preventDefault'd OR the target's touch-action chain blocks pinch-zoom
  (Google Maps: touch-action:none on body - defaultPrevented alone raced the
  200 ms grace and double-zoomed); declined from the first unprevented
  touchmove so browser pinch engages fast. WPEWebPage state machine:
  Pending -> PageDriven (verdict/sticky hint) or Browser (declined/grace).
  ATLANTIC_PINCH_FORWARD=0 kill-switch, ATLANTIC_PINCH_ACK_MS grace.
- **Synthetic TouchEnd must release-all.** When browser pinch takes over it
  synthesizes a TouchEnd whose points still read Moved; the serialized
  dispatcher initially only released Released-state points -> phantom fingers
  stuck down -> spurious text-selection toolbar on the plain-page test. Fixed:
  TouchEnd releases every announced point.
- Device-verified matrix: diagnostic page 2-finger delivery (max=2, scale
  3.50, no browser zoom on consuming page); Google Maps pinch zooms the map
  ~3 levels with normal-size chrome (fresh screenshot pair, md5-distinct);
  plain page browser-pinch fallback commits page zoom, no selection toolbar;
  single-finger scroll + tap->click unregressed.

## RULED OUT (fix round)
- Per-point event typing alone fixing delivery - WebEventFactory ignores
  point.type for non-main ids; only per-transition serialization works.
- UIProcess/WebPageProxy dropping multi-touch - dispatch traced to
  page.handleTouchEvent with both points; loss was WebProcess-side.

## OPEN
- 616-era binaries on device replaced by locally-built lib/plugin (backups in
  /home/defaultuser/*.bak-616); CI build from the committed sources should
  supersede via zypper up.
- Browser-mode grace window forwards ~200 ms of touches to non-consuming pages
  before the synthetic TouchEnd; a heavy unhandled page could scroll slightly
  during that window (not observed in tests).
- Committed page zoom still persists across navigations (pre-existing
  behavior, untouched).

## CI build 617 verification (2026-07-26)
- CI run 30219974288 green; device updated via zypper to
  atlantic-browser/wpewebkit2-qt5 617.1 (replaces hand-deployed binaries).
- Diagnostic page on 617: max=2 touches, monotonic pinch scale 3.50, no
  browser zoom on consuming page. OSM/Leaflet: pinch zooms in, centered.
- Google Maps zoomed OUT on two 617 runs — NOT a regression: pinch.py put
  both finger-downs in one evdev report, and a simultaneous 2-finger contact
  is Google Maps' "two-finger tap" = deliberate zoom-out. With a 50 ms
  stagger between downs (pinch.py fixed), Maps zooms in correctly.
  Instrument trap of the same family as the render --scroll ones.

## Browser pinch switched to viewport zoom, 2026-08-17 (issue #5)

**Reported:** "pinch to zoom should zoom viewport, not browser content" — the
fallback gesture behaved unlike every other mobile browser.

**Confirmed cause (code, not a new investigation):** the fallback pinch previewed
with a CSS `transform:scale()` on `documentElement` and, on finger lift,
committed into `webkit_web_view_set_zoom_level()` — i.e. `setPageZoomFactor()`,
*content* zoom. The layout viewport is re-resolved at the new factor, so the page
relayouts and text reflows; it never becomes pannable, it just becomes a
differently laid-out page. Magnifying the visual viewport is a different WebCore
factor entirely (`Page::setPageScaleFactor`), reachable from the UI process via
`WebPageProxy::scalePageInViewCoordinates()`, and **no WPE public API exposes
it** (`webkit_web_view_set_zoom_level()` divides by a `pageScale` that is
hardwired to 1.0 under `PLATFORM(WPE)`; only GTK wires it up).

**Fix, two repos:**
- engine `patches/webkit/webkit-wpe-page-scale-api.patch` — exports
  `wpe_sfos_set_page_scale(view, scale, centerX, centerY)` and
  `wpe_sfos_get_page_scale(view)` from `API/glib/WebKitWebView.cpp`, following
  the `wpe_sfos_set_dark_mode()` convention.
- browser `WPEWebPage::touchEvent` — the `PinchMode::Browser` fallback previews
  the gesture with the existing GPU-composited CSS transform and, on finger
  lift, commits **page scale** instead of page zoom. Range [1.0, 5.0]: below
  1.0 viewport zoom only shrinks the page away from the viewport edges, so
  there is nothing useful there (content zoom kept its 0.5 floor).
  `ATLANTIC_PINCH_VIEWPORT=0` restores the old content-zoom gesture.

### Two defects the static review caught before any device time
1. **Live per-frame page scale is unaffordable on this port.** The first draft
   drove the scale on every touchmove (16 ms throttle). Page scale is
   *undelegated* here — `usesDelegatedPageScaling()` is true only for
   `RemoteLayerTreeDrawingArea` (Cocoa) — so each change runs
   `Page::setPageScaleFactor`'s non-delegated arm: `resolveStyle(Rebuild)` for
   the whole document, `invalidateRect(infiniteRect)`, a layout, *and* a
   contents-scale change that makes `CoordinatedBackingStoreProxy::
   createOrDestroyTiles` drop and re-create **every tile**. Now applied once,
   on lift, with the CSS transform as the free preview.
2. **`scalePageInViewCoordinates()` does not anchor the point you pass it.** It
   sets the new scroll position to `(scrollPosition - origin) * ratio`, which
   anchors the *view origin*. Pinning the pinch centroid needs
   `(scrollPosition + center) * ratio - center`. Passing the raw centroid was
   off by thousands of pixels on a normal zoom-in (S=540, C=1260, r=3 → 6300 px)
   — the page would have shot away from the fingers. The two forms agree when
   `origin = center * (1/ratio - 1)`, independent of the scroll position, so the
   patch passes that and the scroll offset never has to be mirrored into the UI
   process. Verified numerically against WebKit's formula over a spread of
   scroll/centroid/ratio cases.

### Established from source, so not open questions any more
- **No reflow.** `ScrollView::layoutSize()` and `RenderView::viewWidth()` come
  from the view's frame rect and never divide by page scale, so the ICB — and
  therefore line breaking — is untouched. Only
  `clientLogicalWidthForFixedPosition()` divides by `frameScaleFactor()`, which
  is the correct behaviour for `position:fixed`.
- **It re-rasters, it does not upscale.** `Page::setPageScaleFactor` →
  `LocalFrame::deviceOrPageScaleFactorChanged` →
  `RenderLayerCompositor::deviceOrPageScaleFactorChanged` →
  `GraphicsLayerCoordinated::deviceOrPageScaleFactorChanged` notes
  `Change::ContentsScale`, and the commit sets
  `m_platformLayer->setContentsScale(pageScaleFactor * deviceScaleFactor *
  rootRelativeScale)` (GraphicsLayerCoordinated.cpp:1132). Tiles are repainted
  at the zoomed scale.
- **It is pannable.** `FrameView::visibleContentScaleFactor()` returns 1 unless
  scaling is delegated, so contents coordinates stay device coordinates, while
  `RenderView::documentRect()` maps the document through the RenderView
  transform — `adjustViewSize()` therefore grows `contentsSize` with the scale
  and the ordinary scroll path can reach the new extents.
- Hit-testing is scale-aware (`RenderLayer::hitTest` scales the layout viewport
  rect by `frameScaleFactor()`), which is exactly what the CSS-transform
  attempt could not offer.
- `VisualViewportEnabled` and `VisualViewportAPIEnabled` both default true for
  WebKit, so `window.visualViewport.scale` reads back the committed page scale —
  the instrument to verify all of this on device.

Page zoom is untouched by the gesture now, which also decouples pinch from the
3.0 device-scale page zoom (`m_defaultZoomLevel`) it used to multiply into — the
`minimumPinchZoomLevel()`/`maximumPinchZoomLevel()` clamps only bind in the
legacy mode. `WebPageProxy` resets the page scale factor to 1 on every
main-frame commit, so a new page starts at 1:1 without the browser tracking it.

### PRIOR ART — the dead end this is NOT
A persistent UI-side CSS transform was already tried and abandoned. Browser
`dd84ce77`/`87f7055d` (2026-05-20) left `transform:scale()` on `documentElement`
after the gesture ("CSS transform persists - no WebKit zoom commit, no layout
shift"): it magnified without reflowing and looked like viewport zoom.
`c3ea77b8` (2026-05-23, "Fix page scrolling after pinch gesture") replaced it
with the page-zoom commit precisely because the transform is invisible to
WebKit - scroll extents and hit-testing stayed unscaled. **Do not restore it.**
The page-scale factor is the difference: the scrolling coordinator and hit
testing are scale-aware by construction, which is the gap CSS could not close.

### NOT YET VERIFIED — needs a device build
The mechanism is now established from source (above); what is left needs
hardware:
1. Does the commit-on-lift land smoothly — how long does the style rebuild +
   relayout + full tile re-raster actually take on the device, and is the
   handover from the CSS preview to the committed scale visible as a flash?
2. Does one-finger scroll pan the magnified page in practice? The source says
   the extents grow; APZ and our scrolling patches are the risk. This is the
   exact failure that killed the CSS-transform attempt above — if it fails here
   too the answer is a scrolling-coordinator fix, not a return to UI-side
   transforms.
3. Does the preview transform-origin track the fingers on a *second* pinch
   (already zoomed and scrolled)? The origin is resolved in-page from
   `visualViewport.pageLeft/scale`, which should handle it, but it is the
   fiddliest coordinate hop in the change.
4. `user-scalable=no` pages: still overridden (as before, and as other mobile
   browsers do).
5. Interaction with the tile/low-res scroll patches, which now see a contents
   scale that is not the device scale.
