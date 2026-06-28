/*
 * WPEWaylandSubsurface — see header. Renders WPE web frames into a wl_subsurface
 * presented directly by the system compositor, bypassing Qt's scene-graph
 * re-composite of the web content. GUI-thread only.
 */

#include "WPEWaylandSubsurface.h"

#include <cstdlib>
#include <cstring>

#include <QByteArray>
#include <QGuiApplication>
#include <QQuickWindow>
#include <QWindow>
#include <qpa/qplatformnativeinterface.h>

// System EGL/GLES headers (not epoxy) to match WPEQtViewBackend and wpe/fdo-egl.h
// and avoid epoxy redefinition conflicts.
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>

#include <wayland-client.h>
#include <wayland-egl.h>

#include <wpe/fdo-egl.h>

static PFNGLEGLIMAGETARGETTEXTURE2DOESPROC s_imageTargetTexture2DOES = nullptr;

bool WPEWaylandSubsurface::enabled()
{
    static const bool on = [] {
        const char* env = getenv("ATLANTIC_DIRECT_COMPOSITE");
        return env && env[0] && strcmp(env, "0");
    }();
    return on;
}

static QWindow* s_shellWindow = nullptr;
static void* s_chromeSurface = nullptr;
void WPEWaylandSubsurface::setShellWindow(QWindow* shell) { s_shellWindow = shell; }
QWindow* WPEWaylandSubsurface::shellWindow() { return s_shellWindow; }
void WPEWaylandSubsurface::setChromeSurface(void* s) { s_chromeSurface = s; }
void* WPEWaylandSubsurface::chromeSurface() { return s_chromeSurface; }

WPEWaylandSubsurface::WPEWaylandSubsurface() = default;

WPEWaylandSubsurface::~WPEWaylandSubsurface()
{
    destroy();
}

static void registryGlobal(void* data, struct wl_registry* registry, uint32_t name, const char* interface, uint32_t)
{
    auto* self = static_cast<WPEWaylandSubsurface*>(data);
    self->onRegistryGlobal(registry, name, interface);
}
static void registryGlobalRemove(void*, struct wl_registry*, uint32_t) { }

void WPEWaylandSubsurface::onRegistryGlobal(struct wl_registry* registry, uint32_t name, const char* interface)
{
    if (!strcmp(interface, "wl_compositor"))
        m_compositor = static_cast<wl_compositor*>(wl_registry_bind(registry, name, &wl_compositor_interface, 1));
    else if (!strcmp(interface, "wl_subcompositor"))
        m_subcompositor = static_cast<wl_subcompositor*>(wl_registry_bind(registry, name, &wl_subcompositor_interface, 1));
}

bool WPEWaylandSubsurface::bindGlobals()
{
    // Use a private event queue for the registry roundtrip so we don't disturb
    // Qt's default-queue dispatch on the shared wl_display.
    struct wl_event_queue* queue = wl_display_create_queue(m_display);
    if (!queue)
        return false;

    struct wl_registry* registry = wl_display_get_registry(m_display);
    wl_proxy_set_queue(reinterpret_cast<wl_proxy*>(registry), queue);

    static const struct wl_registry_listener listener = { registryGlobal, registryGlobalRemove };
    wl_registry_add_listener(registry, &listener, this);
    wl_display_roundtrip_queue(m_display, queue);

    // Move the bound globals back to the default queue before tearing down our
    // private one (so any later events on them are dispatched by Qt's loop).
    if (m_compositor)
        wl_proxy_set_queue(reinterpret_cast<wl_proxy*>(m_compositor), nullptr);
    if (m_subcompositor)
        wl_proxy_set_queue(reinterpret_cast<wl_proxy*>(m_subcompositor), nullptr);

    wl_registry_destroy(registry);
    wl_event_queue_destroy(queue);

    return m_compositor && m_subcompositor;
}

bool WPEWaylandSubsurface::setupEgl()
{
    m_eglDisplay = eglGetDisplay(reinterpret_cast<EGLNativeDisplayType>(m_display));
    if (m_eglDisplay == EGL_NO_DISPLAY)
        return false;
    eglInitialize(m_eglDisplay, nullptr, nullptr); // refcounted; Qt already inited it
    eglBindAPI(EGL_OPENGL_ES_API);

    const EGLint configAttribs[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_NONE
    };
    EGLConfig config = nullptr;
    EGLint numConfigs = 0;
    if (!eglChooseConfig(m_eglDisplay, configAttribs, &config, 1, &numConfigs) || numConfigs < 1)
        return false;
    m_eglConfig = config;

    const EGLint ctxAttribs[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    m_eglContext = eglCreateContext(m_eglDisplay, config, EGL_NO_CONTEXT, ctxAttribs);
    if (m_eglContext == EGL_NO_CONTEXT)
        return false;

    // Initial size is fixed up by the first setGeometry()/present(); use 1x1 so
    // the wl_egl_window is valid before geometry is known.
    int w = m_geometry.width() > 0 ? m_geometry.width() : 1;
    int h = m_geometry.height() > 0 ? m_geometry.height() : 1;
    m_eglWindow = wl_egl_window_create(m_surface, w, h);
    if (!m_eglWindow)
        return false;

    m_eglSurface = eglCreateWindowSurface(m_eglDisplay, config,
        reinterpret_cast<EGLNativeWindowType>(m_eglWindow), nullptr);
    if (m_eglSurface == EGL_NO_SURFACE)
        return false;

    if (!eglMakeCurrent(m_eglDisplay, m_eglSurface, m_eglSurface, m_eglContext))
        return false;
    eglSwapInterval(m_eglDisplay, 0); // throttling comes from the compositor frame callbacks

    if (!s_imageTargetTexture2DOES) {
        s_imageTargetTexture2DOES = reinterpret_cast<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(
            eglGetProcAddress("glEGLImageTargetTexture2DOES"));
    }
    if (!s_imageTargetTexture2DOES)
        return false;

    static const char* vs =
        "attribute vec2 pos;\n"
        "attribute vec2 texcoord;\n"
        "varying vec2 v_tex;\n"
        "void main(){ v_tex = texcoord; gl_Position = vec4(pos, 0.0, 1.0); }\n";
    static const char* fs =
        "precision mediump float;\n"
        "uniform sampler2D u_tex;\n"
        "varying vec2 v_tex;\n"
        "void main(){ gl_FragColor = texture2D(u_tex, v_tex); }\n";

    GLuint v = glCreateShader(GL_VERTEX_SHADER);
    glShaderSource(v, 1, &vs, nullptr); glCompileShader(v);
    GLuint f = glCreateShader(GL_FRAGMENT_SHADER);
    glShaderSource(f, 1, &fs, nullptr); glCompileShader(f);
    m_program = glCreateProgram();
    glAttachShader(m_program, v); glAttachShader(m_program, f);
    glBindAttribLocation(m_program, 0, "pos");
    glBindAttribLocation(m_program, 1, "texcoord");
    glLinkProgram(m_program);
    m_textureUniform = glGetUniformLocation(m_program, "u_tex");

    glGenTextures(1, &m_texture);
    glBindTexture(GL_TEXTURE_2D, m_texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glBindTexture(GL_TEXTURE_2D, 0);

    return true;
}

bool WPEWaylandSubsurface::ensureCreated(QQuickWindow* window)
{
    if (m_valid)
        return true;
    if (m_attempted || !window)
        return m_valid;
    m_attempted = true;
    qWarning("[WPE-DIRECT-COMPOSITE] ensureCreated: enter");

    QPlatformNativeInterface* ni = QGuiApplication::platformNativeInterface();
    if (!ni)
        return false;

    m_display = static_cast<wl_display*>(ni->nativeResourceForIntegration(QByteArrayLiteral("display")));
    if (!m_display)
        m_display = static_cast<wl_display*>(ni->nativeResourceForIntegration(QByteArrayLiteral("wl_display")));

    // In layered mode the WPEView lives in an offscreen render-control window (no
    // wl_surface), so parent the web subsurface to the on-screen SHELL window instead.
    QWindow* parentWindow = s_shellWindow ? s_shellWindow : static_cast<QWindow*>(window);
    m_parentSurface = static_cast<wl_surface*>(ni->nativeResourceForWindow(QByteArrayLiteral("surface"), parentWindow));
    if (!m_display || !m_parentSurface) {
        qWarning("[WPE-DIRECT-COMPOSITE] no wayland display/surface; falling back to QSG path");
        return false;
    }

    if (!bindGlobals()) {
        qWarning("[WPE-DIRECT-COMPOSITE] compositor lacks wl_subcompositor; falling back to QSG path");
        return false;
    }

    qWarning("[WPE-DIRECT-COMPOSITE] ensureCreated: globals bound");
    m_surface = wl_compositor_create_surface(m_compositor);
    m_subsurface = wl_subcompositor_get_subsurface(m_subcompositor, m_surface, m_parentSurface);
    if (!m_surface || !m_subsurface)
        return false;

    // The web content surface is output-only: give it an empty input region so the
    // compositor routes all touches/pointer events to the chrome (parent) surface
    // instead of to this surface (which has no input handling). Without this the
    // on-top web surface swallows every touch and the chrome becomes dead.
    if (struct wl_region* empty = wl_compositor_create_region(m_compositor)) {
        wl_surface_set_input_region(m_surface, empty);
        wl_region_destroy(empty);
    }

    // Desync so web frames commit independently of the Qt window's frames.
    wl_subsurface_set_desync(m_subsurface);
    // Layered mode: place the web BELOW the chrome subsurface (a sibling under the same
    // shell parent) so the offscreen-rendered chrome composites on top. Legacy mode:
    // place below the parent's own content.
    if (s_chromeSurface)
        wl_subsurface_place_below(m_subsurface, static_cast<wl_surface*>(s_chromeSurface));
    else
        wl_subsurface_place_below(m_subsurface, m_parentSurface);
    if (m_geometry.width() > 0)
        wl_subsurface_set_position(m_subsurface, m_geometry.x(), m_geometry.y());

    qWarning("[WPE-DIRECT-COMPOSITE] ensureCreated: subsurface created, setting up EGL");
    if (!setupEgl()) {
        qWarning("[WPE-DIRECT-COMPOSITE] EGL subsurface setup failed; falling back to QSG path");
        destroy();
        return false;
    }
    qWarning("[WPE-DIRECT-COMPOSITE] ensureCreated: EGL ready, committing parent");

    // place_below/set_position are double-buffered on the PARENT surface and only
    // take effect on its next commit. Qt commits the window surface from the
    // QSGRenderThread, so relying on it is racy (and the render loop may go idle
    // once the web item paints nothing) — the stacking then never latches and the
    // web surface stays on top of the chrome. Commit the parent ourselves to apply
    // the pending sub-surface state deterministically. No buffer is attached, so
    // this only flushes sub-surface placement and does not disturb Qt's own frame.
    commitParent();

    m_appliedGeometry = m_geometry;
    m_valid = true;
    qWarning("[WPE-DIRECT-COMPOSITE] active: web content on dedicated wl_subsurface (below chrome layer)");
    return true;
}

void WPEWaylandSubsurface::commitParent()
{
    if (!m_parentSurface)
        return;
    wl_surface_commit(m_parentSurface);
    if (m_display)
        wl_display_flush(m_display);
}

void WPEWaylandSubsurface::setGeometry(const QRect& devicePixelRect)
{
    m_geometry = devicePixelRect;
    if (!m_valid || devicePixelRect == m_appliedGeometry)
        return;

    if (m_eglWindow && devicePixelRect.width() > 0 && devicePixelRect.height() > 0)
        wl_egl_window_resize(m_eglWindow, devicePixelRect.width(), devicePixelRect.height(), 0, 0);
    m_appliedGeometry = devicePixelRect;
    // Apply via applyPosition() so a geometry change while hidden keeps the surface
    // off-screen. set_position is double-buffered on the parent and only applies on
    // its next commit — commit it ourselves so the move latches even if Qt's render
    // loop is idle (the web item paints nothing in direct-composite mode).
    applyPosition();
    commitParent();
}

// Large vertical offset (device pixels) used to push the web surface fully
// off-screen when hidden — bigger than any panel, so it never peeks.
static constexpr int kOffscreenOffset = 100000;

void WPEWaylandSubsurface::applyPosition()
{
    if (!m_subsurface)
        return;
    const int y = m_appliedGeometry.y() + (m_hidden ? kOffscreenOffset : 0);
    wl_subsurface_set_position(m_subsurface, m_appliedGeometry.x(), y);
}

void WPEWaylandSubsurface::setVisible(bool visible)
{
    if (!m_valid || m_hidden == !visible)
        return;
    m_hidden = !visible;

    // lipstick can't stack the web surface behind the chrome, so to "hide" it we
    // move it fully off-screen; the last buffer stays attached, so showing again is
    // instant (no blank, no forced re-render). present() short-circuits while hidden.
    applyPosition();
    commitParent();
}

void WPEWaylandSubsurface::present(struct wpe_fdo_egl_exported_image* image, bool flipY)
{
    if (!m_valid || !image || m_hidden)
        return;

    if (!eglMakeCurrent(m_eglDisplay, m_eglSurface, m_eglSurface, m_eglContext))
        return;

    const int w = m_appliedGeometry.width() > 0 ? m_appliedGeometry.width() : 1;
    const int h = m_appliedGeometry.height() > 0 ? m_appliedGeometry.height() : 1;
    glViewport(0, 0, w, h);

    glBindTexture(GL_TEXTURE_2D, m_texture);
    s_imageTargetTexture2DOES(GL_TEXTURE_2D,
        static_cast<GLeglImageOES>(wpe_fdo_egl_exported_image_get_egl_image(image)));

    glUseProgram(m_program);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, m_texture);
    glUniform1i(m_textureUniform, 0);

    // Fullscreen triangle strip. v0=BL v1=BR v2=TL v3=TR in clip space.
    const float t0 = flipY ? 1.0f : 0.0f;
    const float t1 = flipY ? 0.0f : 1.0f;
    const GLfloat verts[] = {
        //  pos        texcoord
        -1.0f, -1.0f,  0.0f, t0,
         1.0f, -1.0f,  1.0f, t0,
        -1.0f,  1.0f,  0.0f, t1,
         1.0f,  1.0f,  1.0f, t1,
    };
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), verts);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), verts + 2);
    glEnableVertexAttribArray(0);
    glEnableVertexAttribArray(1);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

    eglSwapBuffers(m_eglDisplay, m_eglSurface); // commits the subsurface
}

void WPEWaylandSubsurface::destroy()
{
    if (m_eglDisplay) {
        eglMakeCurrent(m_eglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (m_texture) glDeleteTextures(1, &m_texture);
        if (m_program) glDeleteProgram(m_program);
        if (m_eglSurface) eglDestroySurface(m_eglDisplay, m_eglSurface);
        if (m_eglContext) eglDestroyContext(m_eglDisplay, m_eglContext);
    }
    if (m_eglWindow) wl_egl_window_destroy(m_eglWindow);
    if (m_subsurface) wl_subsurface_destroy(m_subsurface);
    if (m_surface) wl_surface_destroy(m_surface);
    if (m_subcompositor) wl_subcompositor_destroy(m_subcompositor);
    if (m_compositor) wl_compositor_destroy(m_compositor);

    m_texture = 0; m_program = 0;
    m_eglSurface = nullptr; m_eglContext = nullptr; m_eglWindow = nullptr;
    m_subsurface = nullptr; m_surface = nullptr;
    m_subcompositor = nullptr; m_compositor = nullptr;
    m_valid = false;
}
