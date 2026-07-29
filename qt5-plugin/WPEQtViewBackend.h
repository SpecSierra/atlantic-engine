/*
 * Copyright (C) 2018, 2019 Igalia S.L
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

#pragma once

// Use system EGL/GL headers directly (not epoxy) to avoid epoxy GL macro redefinitions
// conflicting with Qt5's QOpenGLFunctions inline methods.
#include <gbm.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <atomic>
#include <memory>

#include <QHoverEvent>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QOffscreenSurface>
#include <QOpenGLContext>
#include <QPointer>
#include <QSet>
#include <QWheelEvent>
#include <wpe/fdo-egl.h>
#include <wpe/fdo.h>

class WPEQtView;
class WPEWaylandSubsurface;

class Q_DECL_EXPORT WPEQtViewBackend {
public:
    static std::unique_ptr<WPEQtViewBackend> create(const QSizeF&, QPointer<QOpenGLContext>, EGLDisplay, QPointer<WPEQtView>);
    WPEQtViewBackend(const QSizeF&, EGLDisplay, EGLContext, QPointer<QOpenGLContext>, QPointer<WPEQtView>);
    virtual ~WPEQtViewBackend();

    void resize(const QSizeF&);

    // ATLANTIC_TRUE_DEVICE_SCALE: express the 3x UI scale as WebKit's device
    // scale factor instead of as page zoom. m_size stays in physical pixels
    // (Qt runs at dpr 1 on SFOS, so an item is 1080x2520); WebKit is given the
    // LOGICAL size (m_size / scale) plus the scale, and renders back into a
    // physical-size buffer. Page zoom is then free to mean user zoom again.
    // Default off -> setDeviceScaleFactor() is never called and every path
    // below is bit-for-bit the old behaviour.
    static bool trueDeviceScaleEnabled();
    void setDeviceScaleFactor(float);
    float deviceScaleFactor() const { return m_deviceScaleFactor; }

    GLuint texture(QOpenGLContext*);
    // Real pixel dimensions of the frame currently bound by texture() (the same
    // pending?:committed image). Empty until the first frame. Used by
    // updatePaintNode to draw a just-resized-but-not-yet-repainted frame at its
    // native size (top-anchored) instead of stretching it into the new rect.
    QSize currentImageSize() const;
    void didRenderFrame();
    void dispatchEarlyAck();
    bool ackOnSample() const;
    bool hasValidSurface() const { return m_surface.isValid(); };

    void dispatchHoverEnterEvent(QHoverEvent*);
    void dispatchHoverLeaveEvent(QHoverEvent*);
    void dispatchHoverMoveEvent(QHoverEvent*);

    void dispatchMousePressEvent(QMouseEvent*);
    void dispatchMouseReleaseEvent(QMouseEvent*);
    void dispatchWheelEvent(QWheelEvent*);

    void dispatchKeyEvent(QKeyEvent*, bool state);

    void dispatchTouchEvent(QTouchEvent*);

    struct wpe_view_backend* backend() const { return wpe_view_backend_exportable_fdo_get_view_backend(m_exportable); };

    bool handleFullscreenChanged(bool enable);

    // Direct-composite path: when set (and ATLANTIC_DIRECT_COMPOSITE=1), exported
    // images are presented to this wl_subsurface from displayImage() on the GUI
    // thread instead of being imported as a QSG texture node. See WPEWaylandSubsurface.
    void setSubsurface(WPEWaylandSubsurface* subsurface) { m_subsurface = subsurface; }

private:
    void displayImage(struct wpe_fdo_egl_exported_image*);
    uint32_t modifiers() const;

    EGLDisplay m_eglDisplay { nullptr };
    EGLContext m_eglContext { nullptr };
    struct wpe_view_backend_exportable_fdo* m_exportable { nullptr };
    struct wpe_fdo_egl_exported_image* m_pendingImage { nullptr };
    struct wpe_fdo_egl_exported_image* m_committedImage { nullptr };
    bool m_frameUpdateRequested { false };
    // Pipelined frame-ack state (ATLANTIC_PIPELINED_FRAME_ACK, see
    // WPEQtViewBackend.cpp): one ack credit, replenished by each Qt frame that
    // sampled a web frame. GUI-thread only (displayImage and the queued
    // frameSwapped->didRenderFrame both run there).
    bool m_ackCredit { true };
    bool m_ackOwed { false };
    // Ack-on-sample state (ATLANTIC_ACK_ON_SAMPLE): armed on the QSG render
    // thread in texture() when a new frame is bound, consumed on the GUI
    // thread (dispatchEarlyAck / didRenderFrame). m_ackedEarly is GUI-only.
    std::atomic<bool> m_earlyAckArmed { false };
    bool m_ackedEarly { false };

    WPEWaylandSubsurface* m_subsurface { nullptr };

    QPointer<WPEQtView> m_view;
    QOffscreenSurface m_surface;
    // Qt delivers input in physical pixels (dpr is 1 on SFOS). When the view is
    // sized in logical units, pointer/touch coordinates must be divided by the
    // same scale or every tap lands 3x off. Identity when the scale is 1.
    int32_t toLogical(qreal v) const
    {
        return static_cast<int32_t>(m_deviceScaleFactor == 1.0
            ? v : qRound(v / m_deviceScaleFactor));
    }

    QSizeF m_size;
    // 1.0 unless ATLANTIC_TRUE_DEVICE_SCALE is on; see trueDeviceScaleEnabled().
    float m_deviceScaleFactor { 1.0 };
    GLuint m_textureId { 0 };
    // Kept to prime GL state for the Qt ShaderEffect chrome blur (see ctor).
    unsigned m_program { 0 };
    unsigned m_textureUniform { 0 };

    bool m_hovering { false };
    // Touch ids already announced to WebKit with a "down" event; see the
    // per-transition serialization in dispatchTouchEvent.
    QSet<int> m_announcedTouchIds;
    uint32_t m_mouseModifiers { 0 };
    uint32_t m_keyboardModifiers { 0 };
    uint32_t m_mousePressedButton { 0 };
};
