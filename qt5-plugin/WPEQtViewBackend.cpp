/*
 * Copyright (C) 2018, 2019, 2021 Igalia S.L
 * Copyright (C) 2018, 2019 Zodiac Inflight Innovations
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public
 * License along with this library; if not, write to the
 * Free Software Foundation, Inc., 51 Franklin St, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 */

#include "config.h"
#include "WPEQtViewBackend.h"

#include "WPEQtView.h"
#include "WPEWaylandSubsurface.h"
#include <QGuiApplication>
#include <QMetaObject>
#include <cstdlib>
#include <cstring>
#include <QOpenGLFunctions>
#include <QQuickWindow>
#include <QtGlobal>
#include <cstdio>
#include <ctime>

static PFNGLEGLIMAGETARGETTEXTURE2DOESPROC imageTargetTexture2DOES;

// ATLANTIC_FRAME_TRACE=1: emit CLOCK_MONOTONIC-stamped markers at each stage of
// the WebProcess->Qt frame handoff so freeze-then-jump stalls can be localized
// (production vs handoff vs present). Comparable to the WebProcess-side markers
// (same clock). Zero cost when unset. See scripts/devtools frame-trace analysis.
static double atlTraceNowMs()
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1.0e6;
}
static bool atlFrameTrace()
{
    static const bool on = [] {
        const char* e = getenv("ATLANTIC_FRAME_TRACE");
        return e && e[0] && e[0] != '0';
    }();
    return on;
}
#define ATL_FTRACE(stage) do { if (atlFrameTrace()) fprintf(stderr, "[ftrace] ui " stage " t=%.1f\n", atlTraceNowMs()); } while (0)

std::unique_ptr<WPEQtViewBackend> WPEQtViewBackend::create(const QSizeF& size, QPointer<QOpenGLContext> context, EGLDisplay eglDisplay, QPointer<WPEQtView> view)
{
    if (!context || !view)
        return nullptr;

    if (eglDisplay == EGL_NO_DISPLAY)
        return nullptr;

    eglInitialize(eglDisplay, nullptr, nullptr);

    if (!eglBindAPI(EGL_OPENGL_ES_API) || !wpe_fdo_initialize_for_egl_display(eglDisplay))
        return nullptr;

    static const EGLint configAttributes[13] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RED_SIZE, 1,
        EGL_GREEN_SIZE, 1,
        EGL_BLUE_SIZE, 1,
        EGL_ALPHA_SIZE, 1,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_NONE
    };

    EGLint count = 0;
    if (!eglGetConfigs(eglDisplay, nullptr, 0, &count) || count < 1)
        return nullptr;

    EGLConfig eglConfig;
    EGLint matched = 0;
    EGLContext eglContext = nullptr;
    if (eglChooseConfig(eglDisplay, configAttributes, &eglConfig, 1, &matched) && !!matched) {
        static const EGLint contextAttributes[3] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
        eglContext = eglCreateContext(eglDisplay, eglConfig, nullptr, contextAttributes);
    }

    if (!eglContext)
        return nullptr;

    return std::make_unique<WPEQtViewBackend>(size, eglDisplay, eglContext, context, view);
}

WPEQtViewBackend::WPEQtViewBackend(const QSizeF& size, EGLDisplay display, EGLContext eglContext, QPointer<QOpenGLContext> context, QPointer<WPEQtView> view)
    : m_eglDisplay(display)
    , m_eglContext(eglContext)
    , m_view(view)
    , m_size(size)
{
    wpe_loader_init("libWPEBackend-fdo-1.0.so.1");

    imageTargetTexture2DOES = reinterpret_cast<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(eglGetProcAddress("glEGLImageTargetTexture2DOES"));

    // NOTE: this GLES program is not used to draw the web texture (that path is
    // zero-copy). It is kept because compiling/linking it at backend creation
    // primes shared GL state that the Qt scene-graph ShaderEffect chrome blur
    // depends on on the single-command-queue Adreno/hybris stack — removing it
    // made the toolbar's gl_FragCoord wallpaper blur render flat.
    static const char* vertexShaderSource =
        "attribute vec2 pos;\n"
        "attribute vec2 texture;\n"
        "varying vec2 v_texture;\n"
        "void main() {\n"
        "  v_texture = texture;\n"
        "  gl_Position = vec4(pos, 0, 1);\n"
        "}\n";
    static const char* fragmentShaderSource =
        "precision mediump float;\n"
        "uniform sampler2D u_texture;\n"
        "varying vec2 v_texture;\n"
        "void main() {\n"
        "  gl_FragColor = texture2D(u_texture, v_texture);\n"
        "}\n";

    QOpenGLFunctions* glFunctions = context->functions();
    GLuint vertexShader = glFunctions->glCreateShader(GL_VERTEX_SHADER);
    glFunctions->glShaderSource(vertexShader, 1, &vertexShaderSource, nullptr);
    glFunctions->glCompileShader(vertexShader);

    GLuint fragmentShader = glFunctions->glCreateShader(GL_FRAGMENT_SHADER);
    glFunctions->glShaderSource(fragmentShader, 1, &fragmentShaderSource, nullptr);
    glFunctions->glCompileShader(fragmentShader);

    m_program = glFunctions->glCreateProgram();
    glFunctions->glAttachShader(m_program, vertexShader);
    glFunctions->glAttachShader(m_program, fragmentShader);

    glFunctions->glBindAttribLocation(m_program, 0, "pos");
    glFunctions->glBindAttribLocation(m_program, 1, "texture");

    glFunctions->glLinkProgram(m_program);
    m_textureUniform = glFunctions->glGetUniformLocation(m_program, "u_texture");

    static struct wpe_view_backend_exportable_fdo_egl_client exportableClient = {
        // export_egl_image
        nullptr,
        [](void* data, struct wpe_fdo_egl_exported_image* image)
        {
            static_cast<WPEQtViewBackend*>(data)->displayImage(image);
        },
        // padding
        nullptr, nullptr, nullptr
    };

    m_exportable = wpe_view_backend_exportable_fdo_egl_create(&exportableClient, this, m_size.width(), m_size.height());

    wpe_view_backend_add_activity_state(backend(), wpe_view_activity_state_visible | wpe_view_activity_state_focused | wpe_view_activity_state_in_window);

    // Register the libwpe fullscreen handler.  Without it,
    // wpe_view_backend_platform_set_fullscreen() returns false, which makes
    // WebKit's PageClientImpl::enterFullScreen() immediately call
    // requestExitFullScreen() — DOM fullscreen enters and reverts within
    // ~100 ms (video fullscreen "exits after a second").  The handler accepts
    // the transition and forwards it to the embedding WPEQtView.
    wpe_view_backend_set_fullscreen_handler(backend(), [](void* data, bool enable) -> bool {
        return static_cast<WPEQtViewBackend*>(data)->handleFullscreenChanged(enable);
    }, this);

    m_surface.setFormat(context->format());
    m_surface.create();
}

WPEQtViewBackend::~WPEQtViewBackend()
{
    if (m_exportable && m_pendingImage)
        wpe_view_backend_exportable_fdo_egl_dispatch_release_exported_image(m_exportable, m_pendingImage);
    if (m_exportable && m_committedImage)
        wpe_view_backend_exportable_fdo_egl_dispatch_release_exported_image(m_exportable, m_committedImage);
    m_pendingImage = nullptr;
    m_committedImage = nullptr;
    wpe_view_backend_exportable_fdo_destroy(m_exportable);
    eglDestroyContext(m_eglDisplay, m_eglContext);
}

bool WPEQtViewBackend::handleFullscreenChanged(bool enable)
{
    if (!m_view)
        return false;

    // Forward to the embedding view; the browser UI switches the window state
    // (and injects the JS-side cleanup on leave).  Returning true completes
    // the libwpe handshake so WebKit keeps the DOM fullscreen state.
    m_view->notifyFullscreenRequest(enable);
    return true;
}

void WPEQtViewBackend::resize(const QSizeF& newSize)
{
    if (!newSize.isValid())
        return;

    m_size = newSize;
    wpe_view_backend_dispatch_set_size(backend(), m_size.width(), m_size.height());
}

GLuint WPEQtViewBackend::texture(QOpenGLContext* context)
{
    if ((!m_pendingImage && !m_committedImage) || !hasValidSurface())
        return 0;
    ATL_FTRACE("paint");
    auto* image = m_pendingImage ? m_pendingImage : m_committedImage;

    context->makeCurrent(&m_surface);

    QOpenGLFunctions* glFunctions = context->functions();
    if (!m_textureId) {
        glFunctions->glGenTextures(1, &m_textureId);
        glFunctions->glBindTexture(GL_TEXTURE_2D, m_textureId);
        glFunctions->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glFunctions->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glFunctions->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glFunctions->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glFunctions->glBindTexture(GL_TEXTURE_2D, 0);
    }

    // Bind the WPE-exported frame as an EGLImage directly into m_textureId
    // (zero-copy) and hand that texture straight to Qt. updatePaintNode() wraps
    // m_textureId in a QSGSimpleTextureNode and Qt's scene graph composites the
    // EGLImage itself — so the previous per-frame glClear + full-screen textured
    // quad draw here rendered into a discarded framebuffer and was pure waste:
    // a full-screen clear + full-screen blit every frame on the single-command-
    // queue Adreno 610 (which is why the red clear was never visible). The
    // glTexImage2D(...nullptr) allocation was likewise orphaned immediately by
    // glEGLImageTargetTexture2DOES, which defines the texture's storage. Removed.
    // Producer/consumer sync is handled by the wpe-fdo export/frame-complete
    // handshake (see didRenderFrame), not by this draw.
    glFunctions->glActiveTexture(GL_TEXTURE0);
    glFunctions->glBindTexture(GL_TEXTURE_2D, m_textureId);
    imageTargetTexture2DOES(GL_TEXTURE_2D, wpe_fdo_egl_exported_image_get_egl_image(image));
    glFunctions->glBindTexture(GL_TEXTURE_2D, 0);

    m_frameUpdateRequested = m_pendingImage;

    return m_textureId;
}

// ATLANTIC_EAGER_FRAME_COMPLETE=1: acknowledge each exported web frame the
// moment it arrives (displayImage) instead of after Qt has actually rendered a
// scene-graph frame that samples it (didRenderFrame). The stock handshake makes
// the WebProcess compositor lock-step with Qt's render loop: when the QML scene
// renders slowly under load, composites stall in InProgress waiting for the
// frame-complete and scrolling visibly freezes (device-measured on franceinfo:
// compositor 0.2-3fps during scroll, 26fps at rest). With eager acks the
// WebProcess composites at its own rate, Qt samples the newest frame whenever
// it renders, and intermediate frames are simply dropped; buffer reuse is still
// backpressured by the (Qt-paced) release_exported_image below.
static bool eagerFrameComplete()
{
    static const bool on = [] {
        const char* env = getenv("ATLANTIC_EAGER_FRAME_COMPLETE");
        return env && env[0] && strcmp(env, "0");
    }();
    return on;
}

// ATLANTIC_PIPELINED_FRAME_ACK (default 0 = stock): bounded frame pipelining.
// The stock handshake serializes composite -> export -> Qt render -> ack ->
// next composite, so every web frame costs (at least) two display frames — the
// measured ~28fps ceiling on the 60Hz panel. Eager mode (above) removed the
// serialization but with NO bound: the WebProcess could export frames faster
// than Qt consumed them, flooding the UI wayland link (lipstick "Broken pipe"
// fatal on build 495-500). This mode acks with a single credit instead:
// - a frame arriving with the credit available is acked immediately (the
//   WebProcess starts compositing frame N+1 while Qt renders frame N);
// - a frame arriving without it holds its ack until the next Qt frame that
//   samples a web frame (didRenderFrame) — so production is hard-bounded to
//   Qt's own render rate plus the single in-flight frame, and a stalled Qt
//   loop degrades to exactly the stock lock-step instead of a flood.
// Frames that arrive while an unsampled one is pending replace it (the old
// image is released; Qt always samples the newest).
// Ships default OFF: device A/B (build 511, franceinfo + example.com CSS
// animation, rAF-rate) measured identical ~56fps in both modes — the stock
// round trip already fits within one vsync on the Xperia 10 II, so the
// serialization it removes was not a real bottleneck there. Kept for
// experiments on configurations with a slower UI render loop.
static bool pipelinedFrameAck()
{
    static const bool on = [] {
        const char* env = getenv("ATLANTIC_PIPELINED_FRAME_ACK");
        return env && env[0] && strcmp(env, "0");
    }();
    return on;
}

void WPEQtViewBackend::didRenderFrame()
{
    if (!m_frameUpdateRequested || !m_exportable)
        return;

    ATL_FTRACE("ack");

    m_frameUpdateRequested = false;
    // In eager mode the frame-complete was already dispatched in displayImage().
    if (eagerFrameComplete()) {
        // nothing to ack here
    } else if (pipelinedFrameAck()) {
        // Pipelined: pay the owed ack, or replenish the credit (cap 1).
        if (m_ackOwed) {
            m_ackOwed = false;
            wpe_view_backend_exportable_fdo_dispatch_frame_complete(m_exportable);
        } else
            m_ackCredit = true;
    } else
        wpe_view_backend_exportable_fdo_dispatch_frame_complete(m_exportable);
    if (m_committedImage)
        wpe_view_backend_exportable_fdo_egl_dispatch_release_exported_image(m_exportable, m_committedImage);
    m_committedImage = m_pendingImage;
    m_pendingImage = nullptr;
}

void WPEQtViewBackend::displayImage(struct wpe_fdo_egl_exported_image* image)
{
    ATL_FTRACE("recv");
    // Direct-composite path: render straight into the wl_subsurface and run the
    // frame-complete handshake here, decoupled from Qt's render loop. This
    // bypasses the QSG texture-node re-composite of the web content and avoids
    // forcing a full Qt window frame per web frame. Runs on the GUI thread.
    if (m_subsurface) {
        m_subsurface->present(image, /*flipY*/ true);
        if (m_exportable) {
            wpe_view_backend_exportable_fdo_dispatch_frame_complete(m_exportable);
            // Release the previously displayed image (a frame old, GPU no longer
            // sampling it) rather than the one we just drew from.
            if (m_committedImage)
                wpe_view_backend_exportable_fdo_egl_dispatch_release_exported_image(m_exportable, m_committedImage);
        }
        m_committedImage = image;
        return;
    }

    if (m_pendingImage && m_exportable)
        wpe_view_backend_exportable_fdo_egl_dispatch_release_exported_image(m_exportable, m_pendingImage);

    m_pendingImage = image;
    // Eager ack: let the WebProcess compositor start its next frame immediately
    // rather than after Qt's next scene-graph render (see eagerFrameComplete()).
    if (eagerFrameComplete() && m_exportable)
        wpe_view_backend_exportable_fdo_dispatch_frame_complete(m_exportable);
    else if (pipelinedFrameAck() && m_exportable) {
        // Pipelined ack (see pipelinedFrameAck()): ack now if the credit is
        // available, otherwise owe it to the next didRenderFrame.
        if (m_ackCredit) {
            m_ackCredit = false;
            wpe_view_backend_exportable_fdo_dispatch_frame_complete(m_exportable);
        } else
            m_ackOwed = true;
    }
    if (m_view) {
        m_view->triggerUpdate();
        // QQuickItem::update() from triggerUpdate() is not sufficient on hybris
        // EGL: the QSGRenderThread stalls after eglSwapBuffers waiting for
        // QQuickWindow::update() before processing another frame. Without this,
        // subsequent WPE frames are silently dropped until user interaction
        // wakes the Qt render loop externally.
        if (QQuickWindow* w = m_view->window())
            QMetaObject::invokeMethod(w, "update", Qt::QueuedConnection);
        return;
    }

    if (m_exportable)
        wpe_view_backend_exportable_fdo_egl_dispatch_release_exported_image(m_exportable, m_pendingImage);
    m_pendingImage = nullptr;
}

uint32_t WPEQtViewBackend::modifiers() const
{
    uint32_t mask = m_keyboardModifiers;
    if (m_mouseModifiers)
        mask |= m_mouseModifiers;
    return mask;
}

void WPEQtViewBackend::dispatchHoverEnterEvent(QHoverEvent*)
{
    m_hovering = true;
    m_mouseModifiers = 0;
}

void WPEQtViewBackend::dispatchHoverLeaveEvent(QHoverEvent*)
{
    m_hovering = false;
}

void WPEQtViewBackend::dispatchHoverMoveEvent(QHoverEvent* event)
{
    if (!m_hovering)
        return;

    uint32_t state = !!m_mousePressedButton;
    struct wpe_input_pointer_event wpeEvent = { wpe_input_pointer_event_type_motion,
        static_cast<uint32_t>(event->timestamp()),
        event->pos().x(), event->pos().y(),
        m_mousePressedButton, state, modifiers() };
    wpe_view_backend_dispatch_pointer_event(backend(), &wpeEvent);
}

void WPEQtViewBackend::dispatchMousePressEvent(QMouseEvent* event)
{
    uint32_t button = 0;
    uint32_t modifier = 0;
    switch (event->button()) {
    case Qt::LeftButton:
        button = 1;
        modifier = wpe_input_pointer_modifier_button1;
        break;
    case Qt::RightButton:
        button = 2;
        modifier = wpe_input_pointer_modifier_button2;
        break;
    default:
        break;
    }
    m_mousePressedButton = button;
    uint32_t state = 1;
    m_mouseModifiers |= modifier;
    struct wpe_input_pointer_event wpeEvent = { wpe_input_pointer_event_type_button,
        static_cast<uint32_t>(event->timestamp()),
        event->x(), event->y(), button, state, modifiers() };
    wpe_view_backend_dispatch_pointer_event(backend(), &wpeEvent);
}

void WPEQtViewBackend::dispatchMouseReleaseEvent(QMouseEvent* event)
{
    uint32_t button = 0;
    uint32_t modifier = 0;
    switch (event->button()) {
    case Qt::LeftButton:
        button = 1;
        modifier = wpe_input_pointer_modifier_button1;
        break;
    case Qt::RightButton:
        button = 2;
        modifier = wpe_input_pointer_modifier_button2;
        break;
    default:
        break;
    }
    m_mousePressedButton = 0;
    uint32_t state = 0;
    m_mouseModifiers &= ~modifier;
    struct wpe_input_pointer_event wpeEvent = { wpe_input_pointer_event_type_button,
        static_cast<uint32_t>(event->timestamp()),
        event->x(), event->y(), button, state, modifiers() };
    wpe_view_backend_dispatch_pointer_event(backend(), &wpeEvent);
}

#if (QT_VERSION >= QT_VERSION_CHECK(5, 14, 0))
#define QWHEEL_POSITION position()
#else
#define QWHEEL_POSITION posF()
#endif

void WPEQtViewBackend::dispatchWheelEvent(QWheelEvent* event)
{
    QPoint delta = event->angleDelta();
    QPoint numDegrees = delta / 8;
    struct wpe_input_axis_2d_event wpeEvent = {};  // zero both axes + base; only one axis is set below
    if (delta.y() == event->QWHEEL_POSITION.y())
        wpeEvent.x_axis = numDegrees.x();
    else
        wpeEvent.y_axis = numDegrees.y();
    wpeEvent.base.type = static_cast<wpe_input_axis_event_type>(wpe_input_axis_event_type_mask_2d | wpe_input_axis_event_type_motion_smooth);
    wpeEvent.base.x = event->QWHEEL_POSITION.x();
    wpeEvent.base.y = event->QWHEEL_POSITION.y();
    wpe_view_backend_dispatch_axis_event(backend(), &wpeEvent.base);
}

// Map a QKeyEvent to an XKB keysym when the event carries no native one.
// Software-keyboard (Maliit) and synthesized events have nativeVirtualKey()==0,
// and the old fallback passed the Qt keycode to
// wpe_input_xkb_context_get_key_code — which expects a HARDWARE keycode, so
// every such key (Enter included) dissolved into keysym 0 and WebKit never saw
// it. Special keys get their XKB_KEY_* values; printable characters use the
// standard XKB Unicode rule (Latin-1 maps directly, others are 0x01000000|cp).
static uint32_t keysymForQtKey(const QKeyEvent* event)
{
    switch (event->key()) {
    case Qt::Key_Return:
    case Qt::Key_Enter:     return 0xff0d; // XKB_KEY_Return
    case Qt::Key_Backspace: return 0xff08; // XKB_KEY_BackSpace
    case Qt::Key_Tab:       return 0xff09; // XKB_KEY_Tab
    case Qt::Key_Backtab:   return 0xfe20; // XKB_KEY_ISO_Left_Tab
    case Qt::Key_Escape:    return 0xff1b; // XKB_KEY_Escape
    case Qt::Key_Delete:    return 0xffff; // XKB_KEY_Delete
    case Qt::Key_Insert:    return 0xff63; // XKB_KEY_Insert
    case Qt::Key_Left:      return 0xff51; // XKB_KEY_Left
    case Qt::Key_Up:        return 0xff52; // XKB_KEY_Up
    case Qt::Key_Right:     return 0xff53; // XKB_KEY_Right
    case Qt::Key_Down:      return 0xff54; // XKB_KEY_Down
    case Qt::Key_PageUp:    return 0xff55; // XKB_KEY_Page_Up
    case Qt::Key_PageDown:  return 0xff56; // XKB_KEY_Page_Down
    case Qt::Key_Home:      return 0xff50; // XKB_KEY_Home
    case Qt::Key_End:       return 0xff57; // XKB_KEY_End
    default:
        break;
    }
    const QString text = event->text();
    if (!text.isEmpty()) {
        const uint32_t cp = text.at(0).isHighSurrogate() && text.size() > 1
            ? QChar::surrogateToUcs4(text.at(0), text.at(1))
            : text.at(0).unicode();
        if (cp >= 0x20 && cp < 0x100)
            return cp;
        if (cp >= 0x100)
            return 0x01000000 | cp;
    }
    return 0;
}

void WPEQtViewBackend::dispatchKeyEvent(QKeyEvent* event, bool state)
{
    uint32_t keysym = event->nativeVirtualKey();
    if (!keysym)
        keysym = keysymForQtKey(event);
    if (!keysym)
        keysym = wpe_input_xkb_context_get_key_code(wpe_input_xkb_context_get_default(), event->key(), state);

    uint32_t modifiers = 0;
    Qt::KeyboardModifiers qtModifiers = event->modifiers();
    if (!qtModifiers)
        qtModifiers = QGuiApplication::keyboardModifiers();

    if (qtModifiers & Qt::ShiftModifier)
        modifiers |= wpe_input_keyboard_modifier_shift;

    if (qtModifiers & Qt::ControlModifier)
        modifiers |= wpe_input_keyboard_modifier_control;
    if (qtModifiers & Qt::MetaModifier)
        modifiers |= wpe_input_keyboard_modifier_meta;
    if (qtModifiers & Qt::AltModifier)
        modifiers |= wpe_input_keyboard_modifier_alt;

    struct wpe_input_keyboard_event wpeEvent = { static_cast<uint32_t>(event->timestamp()),
        keysym, event->nativeScanCode(), state, modifiers };
    wpe_view_backend_dispatch_keyboard_event(backend(), &wpeEvent);
}

void WPEQtViewBackend::dispatchTouchEvent(QTouchEvent* event)
{
    wpe_input_touch_event_type eventType;
    switch (event->type()) {
    case QEvent::TouchBegin:
        eventType = wpe_input_touch_event_type_down;
        break;
    case QEvent::TouchUpdate:
        eventType = wpe_input_touch_event_type_motion;
        break;
    case QEvent::TouchEnd:
        eventType = wpe_input_touch_event_type_up;
        break;
    default:
        eventType = wpe_input_touch_event_type_null;
        break;
    }

    // No touch points means g_new0(..., 0) returns NULL; dispatching would then
    // read rawEvents[0].id off a null pointer. Nothing to deliver, so bail out.
    if (event->touchPoints().isEmpty())
        return;

    int i = 0;
    struct wpe_input_touch_event_raw* rawEvents = g_new0(wpe_input_touch_event_raw, event->touchPoints().length());
    for (auto& point : event->touchPoints()) {
        rawEvents[i] = { eventType, static_cast<uint32_t>(event->timestamp()),
            point.id(), static_cast<int32_t>(point.pos().x()), static_cast<int32_t>(point.pos().y()) };
        i++;
    }

    struct wpe_input_touch_event wpeEvent = { rawEvents, static_cast<uint64_t>(i), eventType,
        static_cast<int32_t>(rawEvents[0].id),
        static_cast<uint32_t>(event->timestamp()), modifiers() };
    wpe_view_backend_dispatch_touch_event(backend(), &wpeEvent);
    g_free(rawEvents);
}
