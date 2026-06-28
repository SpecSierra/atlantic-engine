/*
 * WPEWaylandSubsurface — direct-composite path for the WPE Qt5 view.
 *
 * Instead of importing each WPE-exported EGLImage as a QSGSimpleTextureNode and
 * letting Qt's scene graph re-composite the whole window every web frame (the
 * "double composite"), this renders web content into a dedicated wl_subsurface
 * that the system compositor (lipstick) presents directly. The Qt window only
 * draws the chrome, with a transparent hole where the web content shows through.
 *
 * All operations run on the GUI/main thread: WPEBackend-fdo dispatches the
 * exported-image callback there, so present() is called there too, with this
 * object's own EGL context bound to the subsurface's window surface. Web frames
 * therefore never touch Qt's QSGRenderThread and never force a chrome
 * recomposite — only the subsurface is updated and committed.
 *
 * Gated by ATLANTIC_DIRECT_COMPOSITE=1; when off the legacy QSG texture-node
 * path in WPEQtView is used unchanged.
 */

#pragma once

#include <QRect>

struct wpe_fdo_egl_exported_image;
struct wl_compositor;
struct wl_subcompositor;
struct wl_surface;
struct wl_subsurface;
struct wl_egl_window;
struct wl_display;
class QQuickWindow;
class QWindow;

class WPEWaylandSubsurface {
public:
    // Honoured once at process start.
    static bool enabled();

    // Direct-composite layered mode: the chrome runs in an offscreen render-control
    // window, so the WPEView's own window has no wl_surface. The browser sets the
    // on-screen SHELL window here; the web subsurface parents to it (a sibling below the
    // chrome subsurface) instead of to the WPEView's window. And the chrome subsurface
    // (set by WPEChromeOverlay) is the sibling the web places itself BELOW. Both null in
    // legacy single-window mode (web parents to its own window, place_below parent).
    static void setShellWindow(QWindow* shell);
    static QWindow* shellWindow();
    static void setChromeSurface(void* wlSurface);
    static void* chromeSurface();
    static void* webSurface(); // the web content surface, for the chrome overlay to place_above

    WPEWaylandSubsurface();
    ~WPEWaylandSubsurface();

    // Lazily create the subsurface as a child of the QtQuick window's wl_surface.
    // Returns false (and stays inert) if the platform isn't Wayland, the
    // compositor lacks wl_subcompositor, or EGL setup fails — the caller then
    // falls back to the QSG path. Safe to call repeatedly.
    bool ensureCreated(QQuickWindow* window);

    bool isValid() const { return m_valid; }

    // Position (in device pixels, relative to the parent window surface) and
    // size of the web content region. Applies on the next parent commit.
    void setGeometry(const QRect& devicePixelRect);

    // Render the exported image into the subsurface and commit it. Runs on the
    // GUI thread. flipY matches WPEQtViewBackend's orientation handling.
    void present(struct wpe_fdo_egl_exported_image* image, bool flipY);

    // Show/hide the web surface. lipstick (a QtWayland compositor) always stacks a
    // subsurface above its parent's own content, so the web surface cannot go behind
    // the chrome that is the parent window. Instead we unmap it (attach a null buffer)
    // while the chrome overlay is engaged, so the chrome shows; the next present()
    // re-maps it. Web stays full-screen and directly composited while browsing.
    void setVisible(bool visible);
    bool isHidden() const { return m_hidden; }

    // The web content wl_surface, so an external overlay subsurface (the chrome layer,
    // created browser-side) can place_above it. Returned as void* to keep wayland types
    // out of callers that don't include wayland-client. Null until the subsurface exists.
    void* webContentSurface() const { return m_surface; }

    // Called by the wl_registry listener; public so the C callback can reach it.
    void onRegistryGlobal(struct wl_registry* registry, uint32_t name, const char* interface);

private:
    void destroy();
    bool setupEgl();
    bool bindGlobals();
    // Commit the parent surface to latch double-buffered sub-surface state
    // (placement/position), which otherwise only applies on Qt's next frame.
    void commitParent();
    // Apply the sub-surface position from m_appliedGeometry, pushing it off-screen
    // while m_hidden so the chrome shows through (lipstick can't stack it below).
    void applyPosition();

    bool m_valid { false };
    bool m_attempted { false };
    bool m_hidden { false };

    wl_display* m_display { nullptr };
    wl_surface* m_parentSurface { nullptr };
    wl_compositor* m_compositor { nullptr };
    wl_subcompositor* m_subcompositor { nullptr };
    wl_surface* m_surface { nullptr };
    wl_subsurface* m_subsurface { nullptr };
    wl_egl_window* m_eglWindow { nullptr };

    void* m_eglDisplay { nullptr };   // EGLDisplay
    void* m_eglConfig { nullptr };     // EGLConfig
    void* m_eglContext { nullptr };    // EGLContext
    void* m_eglSurface { nullptr };    // EGLSurface

    unsigned m_program { 0 };
    int m_textureUniform { -1 };
    unsigned m_texture { 0 };

    QRect m_geometry;
    QRect m_appliedGeometry;
};
