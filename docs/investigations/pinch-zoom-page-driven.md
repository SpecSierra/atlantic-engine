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
