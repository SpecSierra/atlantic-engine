/*
 * WPEChromeOverlay — renders a QtQuick scene into a wl_subsurface placed ABOVE the
 * web content subsurface, so the UI can sit over the directly-composited web on
 * lipstick.
 *
 * Why this exists: lipstick pins a Silica ApplicationWindow to the base app layer,
 * so a web subsurface always floats above any on-screen Qt UI window (device-proven).
 * The only surfaces that float above the web are ones the compositor draws directly:
 * raw subsurfaces (proven via place_above) and plain windows. So the chrome is
 * rendered OFFSCREEN via QQuickRenderControl (a QQuickWindow with no OS window → never
 * registers with lipstick → never base-layer-pinned) and presented to a dedicated
 * wl_subsurface placed above the web surface.
 *
 * Rendering: QQuickRenderControl::render() needs a QOpenGLContext current on a QSurface,
 * so it cannot draw straight into a raw wl_egl_window surface. We render the scene into
 * a Qt FBO (context current on a QOffscreenSurface), then blit that FBO texture into the
 * subsurface's own EGL window surface using the SAME EGLContext (Qt's, borrowed via its
 * native handle) — no cross-context texture sharing (avoids the hybris EGL fence/share
 * gap). GUI-thread only.
 *
 * M1 scope: renders a self-contained test scene (no browser QML context) to validate the
 * render-control → subsurface-above-web pipeline on the hybris/Adreno stack. Gated by
 * ATLANTIC_DC_OVERLAY_TEST. Later milestones host the real browser.qml scene + input/IME.
 */

#pragma once

#include <QSize>
#include <cstdint>

struct wl_registry;
struct wl_compositor;
struct wl_subcompositor;
struct wl_surface;
struct wl_subsurface;
struct wl_egl_window;
struct wl_display;
class QQuickRenderControl;
class QQuickWindow;
class QQmlEngine;
class QQmlComponent;
class QQuickItem;
class QOffscreenSurface;
class QOpenGLContext;
class QOpenGLFramebufferObject;

class Q_DECL_EXPORT WPEChromeOverlay {
public:
    static bool testEnabled(); // ATLANTIC_DC_OVERLAY_TEST

    // The real-mode overlay that hosts browser.qml, so the browser (Browser ctor) can
    // find it and load the UI scene into it. Set by the runtime after create(); null in
    // legacy/test mode (then the UI loads into the on-screen view as usual).
    static WPEChromeOverlay* primary();
    static void setPrimary(WPEChromeOverlay*);

    WPEChromeOverlay();
    ~WPEChromeOverlay();

    // Create the chrome overlay subsurface as a child of parentSurface (the on-screen
    // shell window's wl_surface), sized sizeDevicePx, on the shared wl_display. Sets up
    // the offscreen render-control QQuickWindow + EGL + blit. Does NOT load QML content
    // unless ATLANTIC_DC_OVERLAY_TEST is set (then it loads a self-test scene); in real
    // mode the browser loads browser.qml into quickWindow() and calls contentReady().
    // Returns false and stays inert on failure.
    bool create(wl_display* display, wl_surface* parentSurface, const QSize& sizeDevicePx);

    bool isValid() const { return m_valid; }

    // Accessors so the browser can host browser.qml in the overlay's scene.
    QQuickWindow* quickWindow() const { return m_quickWindow; }
    QQmlEngine* qmlEngine() const { return m_qmlEngine; }
    void* surface() const { return m_surface; }   // chrome wl_surface (for web place_below)

    // Call after parenting content into quickWindow()->contentItem(): sizes the root and
    // starts rendering. Place the chrome above the web once the web subsurface exists.
    void contentReady();
    void setWebSurface(void* wlWebSurface); // re-assert place_above(web) as a backup

private:
    void destroy();
    bool setupEgl();
    bool setupScene();
    bool ensureFbo();
    void renderFrame();      // polish/sync/render scene → FBO → blit to subsurface
    void scheduleRender();   // queue a renderFrame() on the GUI thread

    bool m_valid { false };

    wl_display* m_display { nullptr };
    wl_surface* m_parentSurface { nullptr };
    wl_compositor* m_compositor { nullptr };
    wl_subcompositor* m_subcompositor { nullptr };
    wl_surface* m_surface { nullptr };
    wl_subsurface* m_subsurface { nullptr };
    wl_egl_window* m_eglWindow { nullptr };

    void* m_eglDisplay { nullptr };
    void* m_eglConfig { nullptr };
    void* m_eglContext { nullptr };  // borrowed from Qt's QOpenGLContext native handle
    void* m_eglSurface { nullptr };

    QSize m_size;

    QQuickRenderControl* m_renderControl { nullptr };
    QQuickWindow* m_quickWindow { nullptr };
    QQmlEngine* m_qmlEngine { nullptr };
    QQmlComponent* m_qmlComponent { nullptr };
    QQuickItem* m_rootItem { nullptr };
    QOffscreenSurface* m_offscreenSurface { nullptr };
    QOpenGLContext* m_glContext { nullptr };
    QOpenGLFramebufferObject* m_fbo { nullptr };

    unsigned m_blitProgram { 0 };
    int m_blitTexUniform { -1 };

    void onRegistryGlobal(wl_registry* registry, uint32_t name, const char* interface);
    bool bindGlobals();
    friend void chromeRegistryGlobal(void*, wl_registry*, uint32_t, const char*, uint32_t);
};
