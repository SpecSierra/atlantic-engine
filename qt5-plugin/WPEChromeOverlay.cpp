/*
 * WPEChromeOverlay — see header. Renders a QtQuick scene into a wl_subsurface placed
 * above the web subsurface. GUI-thread only.
 */

#include "WPEChromeOverlay.h"

#include <cstdlib>
#include <cstring>

#include <QByteArray>
#include <QGuiApplication>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickRenderControl>
#include <QQuickWindow>
#include <QOffscreenSurface>
#include <QOpenGLContext>
#include <QOpenGLFramebufferObject>
#include <QOpenGLFunctions>
#include <QTimer>
#include <QUrl>
#include <QtPlatformHeaders/QEGLNativeContext>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>

#include <wayland-client.h>
#include <wayland-egl.h>

bool WPEChromeOverlay::testEnabled()
{
    static const bool on = [] {
        const char* env = getenv("ATLANTIC_DC_OVERLAY_TEST");
        return env && env[0] && strcmp(env, "0");
    }();
    return on;
}

WPEChromeOverlay::WPEChromeOverlay() = default;

WPEChromeOverlay::~WPEChromeOverlay()
{
    destroy();
}

void chromeRegistryGlobal(void* data, wl_registry* registry, uint32_t name, const char* interface, uint32_t)
{
    static_cast<WPEChromeOverlay*>(data)->onRegistryGlobal(registry, name, interface);
}
static void chromeRegistryGlobalRemove(void*, wl_registry*, uint32_t) { }

void WPEChromeOverlay::onRegistryGlobal(wl_registry* registry, uint32_t name, const char* interface)
{
    if (!strcmp(interface, "wl_compositor"))
        m_compositor = static_cast<wl_compositor*>(wl_registry_bind(registry, name, &wl_compositor_interface, 1));
    else if (!strcmp(interface, "wl_subcompositor"))
        m_subcompositor = static_cast<wl_subcompositor*>(wl_registry_bind(registry, name, &wl_subcompositor_interface, 1));
}

bool WPEChromeOverlay::bindGlobals()
{
    wl_event_queue* queue = wl_display_create_queue(m_display);
    if (!queue)
        return false;
    wl_registry* registry = wl_display_get_registry(m_display);
    wl_proxy_set_queue(reinterpret_cast<wl_proxy*>(registry), queue);
    static const wl_registry_listener listener = { chromeRegistryGlobal, chromeRegistryGlobalRemove };
    wl_registry_add_listener(registry, &listener, this);
    wl_display_roundtrip_queue(m_display, queue);
    if (m_compositor)
        wl_proxy_set_queue(reinterpret_cast<wl_proxy*>(m_compositor), nullptr);
    if (m_subcompositor)
        wl_proxy_set_queue(reinterpret_cast<wl_proxy*>(m_subcompositor), nullptr);
    wl_registry_destroy(registry);
    wl_event_queue_destroy(queue);
    return m_compositor && m_subcompositor;
}

bool WPEChromeOverlay::setupEgl()
{
    // Borrow Qt's EGLContext/EGLDisplay so the FBO texture (rendered by Qt) is valid in
    // the same context we use to blit into the subsurface — no cross-context sharing.
    if (!m_glContext)
        return false;
    QVariant nh = m_glContext->nativeHandle();
    if (!nh.canConvert<QEGLNativeContext>())
        return false;
    QEGLNativeContext eglNh = nh.value<QEGLNativeContext>();
    m_eglContext = eglNh.context();
    m_eglDisplay = eglNh.display();
    if (!m_eglContext || !m_eglDisplay)
        return false;

    const EGLint configAttribs[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_NONE
    };
    EGLConfig config = nullptr;
    EGLint num = 0;
    if (!eglChooseConfig(static_cast<EGLDisplay>(m_eglDisplay), configAttribs, &config, 1, &num) || num < 1)
        return false;
    m_eglConfig = config;

    const int w = m_size.width() > 0 ? m_size.width() : 1;
    const int h = m_size.height() > 0 ? m_size.height() : 1;
    m_eglWindow = wl_egl_window_create(m_surface, w, h);
    if (!m_eglWindow)
        return false;
    m_eglSurface = eglCreateWindowSurface(static_cast<EGLDisplay>(m_eglDisplay), config,
        reinterpret_cast<EGLNativeWindowType>(m_eglWindow), nullptr);
    if (m_eglSurface == EGL_NO_SURFACE)
        return false;
    return true;
}

// Build the offscreen QtQuick scene driven by QQuickRenderControl.
bool WPEChromeOverlay::setupScene()
{
    m_renderControl = new QQuickRenderControl();
    m_quickWindow = new QQuickWindow(m_renderControl);
    m_quickWindow->setColor(Qt::transparent);
    m_quickWindow->setGeometry(0, 0, m_size.width(), m_size.height());

    m_qmlEngine = new QQmlEngine();
    if (!m_qmlEngine->incubationController())
        m_qmlEngine->setIncubationController(m_quickWindow->incubationController());

    // M1 test scene: a semi-transparent magenta bar over the bottom third with a label,
    // plus a translucent tint over the rest, so we can see BOTH that the overlay
    // composites above the web AND that its transparent areas let the web show through.
    static const char* kTestQml =
        "import QtQuick 2.2\n"
        "Item {\n"
        "  Rectangle { anchors.fill: parent; color: '#22008800' }\n"
        "  Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom }\n"
        "    height: parent.height/3; color: '#cc00aaff'\n"
        "    Text { anchors.centerIn: parent; text: 'RENDER-CONTROL OVERLAY';\n"
        "           color: 'white'; font.pixelSize: 44 } }\n"
        "}\n";
    m_qmlComponent = new QQmlComponent(m_qmlEngine);
    m_qmlComponent->setData(kTestQml, QUrl(QStringLiteral("dc-overlay-test.qml")));
    if (m_qmlComponent->isError()) {
        qWarning("[WPE-DC-OVERLAY] QML error: %s",
                 qPrintable(m_qmlComponent->errorString()));
        return false;
    }
    QObject* obj = m_qmlComponent->create();
    m_rootItem = qobject_cast<QQuickItem*>(obj);
    if (!m_rootItem) {
        qWarning("[WPE-DC-OVERLAY] QML root is not a QQuickItem");
        delete obj;
        return false;
    }
    m_rootItem->setParentItem(m_quickWindow->contentItem());
    m_rootItem->setWidth(m_size.width());
    m_rootItem->setHeight(m_size.height());

    // Initialise the render control against Qt's GL context (current on the offscreen
    // surface). QQuickRenderControl::initialize must be called with the context current.
    qWarning("[WPE-DC-OVERLAY] scene: QML root created, initializing render control");
    if (!m_glContext->makeCurrent(m_offscreenSurface)) {
        qWarning("[WPE-DC-OVERLAY] makeCurrent(offscreen) failed");
        return false;
    }
    m_renderControl->initialize(m_glContext);
    m_glContext->doneCurrent();
    qWarning("[WPE-DC-OVERLAY] scene: render control initialized");

    // Re-render whenever the scene changes.
    QObject::connect(m_renderControl, &QQuickRenderControl::renderRequested,
                     m_quickWindow, [this]() { scheduleRender(); });
    QObject::connect(m_renderControl, &QQuickRenderControl::sceneChanged,
                     m_quickWindow, [this]() { scheduleRender(); });
    return true;
}

bool WPEChromeOverlay::ensureFbo()
{
    if (m_fbo && m_fbo->width() == m_size.width() && m_fbo->height() == m_size.height())
        return true;
    delete m_fbo;
    m_fbo = new QOpenGLFramebufferObject(m_size, QOpenGLFramebufferObject::CombinedDepthStencil);
    m_quickWindow->setRenderTarget(m_fbo);
    return m_fbo->isValid();
}

void WPEChromeOverlay::scheduleRender()
{
    QTimer::singleShot(0, [this]() { renderFrame(); });
}

void WPEChromeOverlay::renderFrame()
{
    if (!m_valid)
        return;

    // 1) Render the scene into the Qt FBO (Qt context current on the offscreen surface).
    if (!m_glContext->makeCurrent(m_offscreenSurface))
        return;
    if (!ensureFbo()) {
        m_glContext->doneCurrent();
        return;
    }
    m_renderControl->polishItems();
    m_renderControl->sync();
    m_renderControl->render();
    m_glContext->functions()->glFlush();
    const GLuint texId = m_fbo->texture();
    m_glContext->doneCurrent();

    // 2) Blit the FBO texture into the subsurface's EGL window surface (same EGLContext),
    //    then swap to commit. Premultiplied-alpha blend so transparent scene areas reveal
    //    the web below.
    EGLDisplay dpy = static_cast<EGLDisplay>(m_eglDisplay);
    if (!eglMakeCurrent(dpy, static_cast<EGLSurface>(m_eglSurface),
                        static_cast<EGLSurface>(m_eglSurface), static_cast<EGLContext>(m_eglContext)))
        return;
    glViewport(0, 0, m_size.width(), m_size.height());
    glClearColor(0, 0, 0, 0);
    glClear(GL_COLOR_BUFFER_BIT);
    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

    glUseProgram(m_blitProgram);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, texId);
    glUniform1i(m_blitTexUniform, 0);
    // Fullscreen triangle strip; sample the FBO (origin bottom-left) upright.
    const GLfloat verts[] = {
        -1.f, -1.f, 0.f, 0.f,
         1.f, -1.f, 1.f, 0.f,
        -1.f,  1.f, 0.f, 1.f,
         1.f,  1.f, 1.f, 1.f,
    };
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), verts);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), verts + 2);
    glEnableVertexAttribArray(0);
    glEnableVertexAttribArray(1);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

    eglSwapBuffers(dpy, static_cast<EGLSurface>(m_eglSurface));
}

bool WPEChromeOverlay::create(wl_display* display, wl_surface* parentSurface,
                              wl_surface* webSurface, const QSize& sizeDevicePx)
{
    if (m_valid)
        return true;
    if (!display || !parentSurface || sizeDevicePx.isEmpty())
        return false;
    m_display = display;
    m_parentSurface = parentSurface;
    m_size = sizeDevicePx;
    qWarning("[WPE-DC-OVERLAY] create: enter (%dx%d)", m_size.width(), m_size.height());

    if (!bindGlobals()) {
        qWarning("[WPE-DC-OVERLAY] no wl_subcompositor");
        return false;
    }
    qWarning("[WPE-DC-OVERLAY] step: globals bound");

    m_surface = wl_compositor_create_surface(m_compositor);
    m_subsurface = wl_subcompositor_get_subsurface(m_subcompositor, m_surface, m_parentSurface);
    if (!m_surface || !m_subsurface)
        return false;
    wl_subsurface_set_desync(m_subsurface);
    if (webSurface)
        wl_subsurface_place_above(m_subsurface, webSurface);
    wl_subsurface_set_position(m_subsurface, 0, 0);
    // place_above/set_position are double-buffered on the parent surface; commit it so
    // the placement latches (the parent's own frames come from a separate thread).
    wl_surface_commit(m_parentSurface);
    wl_display_flush(m_display);
    qWarning("[WPE-DC-OVERLAY] step: subsurface created + placed");

    // Qt GL context (creates its own EGLContext via QPA) + offscreen surface for FBO render.
    m_glContext = new QOpenGLContext();
    if (QOpenGLContext* share = QOpenGLContext::globalShareContext())
        m_glContext->setShareContext(share);
    if (!m_glContext->create()) {
        qWarning("[WPE-DC-OVERLAY] QOpenGLContext create failed");
        destroy();
        return false;
    }
    m_offscreenSurface = new QOffscreenSurface();
    m_offscreenSurface->setFormat(m_glContext->format());
    m_offscreenSurface->create();
    qWarning("[WPE-DC-OVERLAY] step: QOpenGLContext + offscreen surface created");

    if (!setupEgl()) {
        qWarning("[WPE-DC-OVERLAY] EGL setup failed");
        destroy();
        return false;
    }
    qWarning("[WPE-DC-OVERLAY] step: EGL surface ready");

    // Blit program (built in the borrowed EGLContext on the subsurface surface).
    if (!eglMakeCurrent(static_cast<EGLDisplay>(m_eglDisplay), static_cast<EGLSurface>(m_eglSurface),
                        static_cast<EGLSurface>(m_eglSurface), static_cast<EGLContext>(m_eglContext))) {
        qWarning("[WPE-DC-OVERLAY] eglMakeCurrent for blit-program failed");
        destroy();
        return false;
    }
    static const char* vs =
        "attribute vec2 pos; attribute vec2 tc; varying vec2 v;\n"
        "void main(){ v = tc; gl_Position = vec4(pos,0.,1.); }\n";
    static const char* fs =
        "precision mediump float; uniform sampler2D t; varying vec2 v;\n"
        "void main(){ gl_FragColor = texture2D(t, v); }\n";
    GLuint vsh = glCreateShader(GL_VERTEX_SHADER); glShaderSource(vsh,1,&vs,nullptr); glCompileShader(vsh);
    GLuint fsh = glCreateShader(GL_FRAGMENT_SHADER); glShaderSource(fsh,1,&fs,nullptr); glCompileShader(fsh);
    m_blitProgram = glCreateProgram();
    glAttachShader(m_blitProgram, vsh); glAttachShader(m_blitProgram, fsh);
    glBindAttribLocation(m_blitProgram, 0, "pos");
    glBindAttribLocation(m_blitProgram, 1, "tc");
    glLinkProgram(m_blitProgram);
    m_blitTexUniform = glGetUniformLocation(m_blitProgram, "t");
    eglMakeCurrent(static_cast<EGLDisplay>(m_eglDisplay), EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    qWarning("[WPE-DC-OVERLAY] step: blit program built");

    if (!setupScene()) {
        qWarning("[WPE-DC-OVERLAY] setupScene failed");
        destroy();
        return false;
    }
    qWarning("[WPE-DC-OVERLAY] step: scene set up");

    m_valid = true;
    qWarning("[WPE-DC-OVERLAY] active: chrome overlay subsurface above web (%dx%d)",
             m_size.width(), m_size.height());
    scheduleRender();
    return true;
}

void WPEChromeOverlay::destroy()
{
    delete m_qmlComponent; m_qmlComponent = nullptr;
    if (m_rootItem) { m_rootItem->deleteLater(); m_rootItem = nullptr; }
    delete m_renderControl; m_renderControl = nullptr;
    delete m_quickWindow; m_quickWindow = nullptr;
    delete m_qmlEngine; m_qmlEngine = nullptr;
    delete m_fbo; m_fbo = nullptr;
    if (m_eglDisplay && m_eglSurface)
        eglDestroySurface(static_cast<EGLDisplay>(m_eglDisplay), static_cast<EGLSurface>(m_eglSurface));
    m_eglSurface = nullptr;
    if (m_eglWindow) wl_egl_window_destroy(m_eglWindow);
    m_eglWindow = nullptr;
    delete m_offscreenSurface; m_offscreenSurface = nullptr;
    delete m_glContext; m_glContext = nullptr; // owns/destroys its EGLContext
    if (m_subsurface) wl_subsurface_destroy(m_subsurface);
    if (m_surface) wl_surface_destroy(m_surface);
    if (m_subcompositor) wl_subcompositor_destroy(m_subcompositor);
    if (m_compositor) wl_compositor_destroy(m_compositor);
    m_subsurface = nullptr; m_surface = nullptr; m_subcompositor = nullptr; m_compositor = nullptr;
    m_valid = false;
}
