> **Status: PARKED** — Direct-composite subsurface path is broken on lipstick (a Silica `ApplicationWindow` is pinned to the base layer, so the web subsurface always floats above the chrome). The Qt scene-graph handoff is what ships. Do not retry without new information about lipstick layering.
>
> Archived `direct-render-overlay-plan.md` (build host `/root`), 2026-07-30.

# Direct-render: chrome on an overlay subsurface (render-control) — PLAN

## Goal
Direct-composite the WPE web frame (remove the Qt-SG double composite) AND show the
Silica chrome ABOVE the live web, on lipstick.

## Why the simple approaches failed (all device-proven, see memory
`direct-composite-subsurface-layering`)
- `wl_subsurface_place_below(parent)` ignored by lipstick → web (subsurface) always
  above its parent window's own content.
- Sibling `place_above` IS honored (magenta bar proof); a plain non-ApplicationWindow
  child window floats above the web (cyan proof); the Maliit keyboard floats above
  (privileged role, not app-settable).
- **A Silica `ApplicationWindow` is pinned by lipstick to the base app layer**, so the
  web subsurface always floats above it. Proven: swapping the chrome child-window's QML
  from `ApplicationWindow`→plain `Item` made it float above; back to `ApplicationWindow`
  trapped it below. So the chrome can't be ANY on-screen Qt window that is/contains a
  Silica ApplicationWindow registered with lipstick.

## Chosen architecture (single window)
- ONE on-screen toplevel `view` = empty + transparent. The app's wl_surface. Web's
  subsurface parent. Stays the lipstick-visible app window.
- WEB: existing `WPEWaylandSubsurface` (engine), child of `view`, bottom.
- CHROME: rendered OFFSCREEN via `QQuickRenderControl` (a QQuickWindow with NO OS window
  → never registers with lipstick → never base-layer-pinned), presented to a NEW
  `wl_subsurface` (child of `view`) `place_above` the web surface.
  - Render straight into the chrome subsurface's own EGLContext/EGLSurface (no
    cross-context texture sharing — QQuickRenderControl renders into the bound default
    framebuffer = the subsurface surface; eglSwapBuffers commits). Avoids hybris EGL
    fence/share issues.
  - browser.qml (Silica ApplicationWindow) is the offscreen scene root — it provides
    Theme/pageStack/orientation; with render-control it has no mapped window so no
    base-layer pinning.

## Input model (M2)
- Web subsurface: empty input region → compositor sends touches to `view`.
- `view` receives all input; forward into the offscreen QQuickWindow (QQuickRenderControl
  delivers events to the scene). The existing WPEWebPage item (in the offscreen scene)
  forwards web-area touches to WPE as today. So one input path: view → offscreen scene →
  (chrome handlers OR WPEWebPage→WPE).

## Milestones
- **M1 [DONE, build 392/393]**: render QtQuick + Silica via QQuickRenderControl → overlay
  subsurface above the live web. Device-proven (test bar + Silica "SILICA OVERLAY OK").
- **M2**: host the REAL browser.qml in the overlay + route input.
- **M3**: IME / Maliit virtual keyboard focus with the render-control window.
- **M4**: resize/orientation, frame-sync + render-only-when-dirty (perf), popups/covers,
  default ATLANTIC_DIRECT_COMPOSITE on in deploy once verified.

## M2 implementation design (the restructure)
browser.qml is ONE Silica scene = chrome + web view. To layer: render the WHOLE scene
offscreen (→ chrome subsurface on top), and re-parent the web view's subsurface to the
on-screen shell (→ below chrome), peeking through the transparent WPEView hole.

Startup flow (main.cpp, direct-composite mode):
1. `view` = on-screen QQuickView shell: transparent, NO browser.qml (empty/minimal), shown
   fullscreen. Its wl_surface is the PARENT of both subsurfaces. Keeps gestures/lifecycle.
2. `DirectComposite::setShellWindow(view)` (new shared context in engine).
3. Create `WPEChromeOverlay` (engine, now browser-instantiable/exported): builds the
   render-control QQuickWindow + EGL + chrome subsurface (child of shell). Real mode = do
   NOT load the test QML. `DirectComposite::setChromeSurface(overlay->surface())`.
4. Runtime loads browser.qml into `overlay->quickWindow()` using `overlay->qmlEngine()`:
   set the 3 context props (WebUtils, Settings, DownloadManager) on its rootContext,
   QQmlComponent-create browser.qml, parent root to quickWindow()->contentItem(), size it.
   (qmlRegisterType registrations are process-global — already done by registerBrowserQmlTypes.)
5. browser.qml's WPEWebPage → WPEWaylandSubsurface::ensureCreated: parent the web subsurface
   to `DirectComposite::shellWindow()` (its own window is the offscreen one with no surface),
   and `place_below(DirectComposite::chromeSurface())` so chrome stays on top.
6. Input: forward shell-window touch/mouse/key into overlay->quickWindow() (the offscreen
   scene); web-area touches flow via the WPEView item → WPE as today.

Stacking note: chrome subsurface created first (startup), web later → web defaults on top,
so the web MUST place_below the chrome surface (step 5), or chrome place_above web once it
exists. Overlay exposes setWebSurface() to (re)assert place_above as a backup.

Engine API to add on WPEChromeOverlay: Q_DECL_EXPORT, accessors quickWindow()/qmlEngine()/
surface(), setWebSurface(), and a "real mode" (skip test QML). New `DirectComposite`
shared context (shell window + chrome surface) read by WPEWaylandSubsurface.

## Key code locations
- Engine subsurface/EGL/wayland: `atlantic-engine/qt5-plugin/WPEWaylandSubsurface.{cpp,h}`
  (mirror its registry/EGL/subsurface setup for the chrome surface; expose web wl_surface
  for place_above).
- Web view item / present: `WPEQtView.cpp`, `WPEQtViewBackend.cpp`.
- Browser startup/windows: `atlantic-browser/apps/browser/main.cpp`.
- Runtime scene load: `apps/lib/browserruntime.cpp`, `apps/core/browser.cpp`
  (`Browser::load` → `view->setSource(browser.qml)`).
- Chrome QML root: `apps/shared/BrowserWindow.qml` (ApplicationWindow), `browser.qml`.

## Build/deploy notes
- Browser must link wayland-client, wayland-egl, EGL, GLESv2 for the chrome subsurface
  (engine qt5-plugin already does — mirror in a .pri).
- Build via CI only (push → engine "Build Atlantic packages"; it clones browser main).
- Device verify by EYE (lipstick saveScreenshot can't capture raw subsurfaces). Launch:
  `ATLANTIC_DIRECT_COMPOSITE=1 setsid /usr/bin/atlantic-browser` then openUrl D-Bus.
- Current uncommitted-in-progress two-window approach (chromeView transient child +
  engine transientParent parenting) is being REPLACED by this; revert to single-window.
