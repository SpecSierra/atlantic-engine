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
#include "WPEQtView.h"

#include "WPEClipboardBridge.h"
#include "WPEGeolocationBridge.h"
#include "WPEQtViewBackend.h"
#include "WPEQtViewLoadRequest.h"
#include "WPEQtViewLoadRequestPrivate.h"
#include "WPEWaylandSubsurface.h"
#include "WPEChromeOverlay.h"
#include <QDebug>
#include <QGuiApplication>
#include <QQuickWindow>
#include <QSGSimpleTextureNode>
#include <QScreen>
#include <QtGlobal>
#include <QtPlatformHeaders/QEGLNativeContext>
#include <qpa/qplatformnativeinterface.h>

/*!
  \qmltype WPEView
  \inqmlmodule org.wpewebkit.qtwpe
  \brief A component for displaying web content.

  WPEView is a component for displaying web content which is implemented using native
  APIs on the platforms where this is available, thus it does not necessarily require
  including a full web browser stack as part of the application.

  WPEView provides an API compatible with Qt's QtWebView component. However
  WPEView is limited to Linux platforms supporting EGL KHR extensions. WPEView
  was successfully tested with the EGLFS and Wayland-EGL QPAs.
*/
WPEQtView::WPEQtView(QQuickItem* parent)
    : QQuickItem(parent)
{
    connect(this, &QQuickItem::windowChanged, this, &WPEQtView::configureWindow);
    setFlag(ItemHasContents, true);
    setAcceptedMouseButtons(Qt::AllButtons);
    setAcceptHoverEvents(true);
#if QT_VERSION >= QT_VERSION_CHECK(5, 10, 0)
    setAcceptTouchEvents(true);
#endif
}

WPEQtView::~WPEQtView()
{
    delete m_chromeOverlay;
    delete m_subsurface;
    if (m_webView) {
        g_signal_handlers_disconnect_by_func(m_webView, reinterpret_cast<gpointer>(notifyUrlChangedCallback), this);
        g_signal_handlers_disconnect_by_func(m_webView, reinterpret_cast<gpointer>(notifyTitleChangedCallback), this);
        g_signal_handlers_disconnect_by_func(m_webView, reinterpret_cast<gpointer>(notifyLoadChangedCallback), this);
        g_signal_handlers_disconnect_by_func(m_webView, reinterpret_cast<gpointer>(notifyLoadFailedCallback), this);
        g_signal_handlers_disconnect_by_func(m_webView, reinterpret_cast<gpointer>(notifyLoadProgressCallback), this);
        if (WebKitBackForwardList* list = webkit_web_view_get_back_forward_list(m_webView))
            g_signal_handlers_disconnect_by_func(list, reinterpret_cast<gpointer>(notifyBackForwardChangedCallback), this);
        g_object_unref(m_webView);
    }
}

void WPEQtView::geometryChanged(const QRectF& newGeometry, const QRectF&)
{
    m_size = newGeometry.size();
    if (m_backend)
        m_backend->resize(newGeometry.size());
    updateSubsurfaceGeometry();
}

void WPEQtView::setWebContentSurfaceVisible(bool visible)
{
    if (m_subsurface)
        m_subsurface->setVisible(visible);
}

void* WPEQtView::webContentSurface() const
{
    return m_subsurface ? m_subsurface->webContentSurface() : nullptr;
}

void WPEQtView::maybeCreateChromeOverlay()
{
    if (m_chromeOverlay || m_chromeOverlayAttempted || !WPEChromeOverlay::testEnabled())
        return;
    if (!m_subsurface || !m_subsurface->isValid() || !window())
        return;
    m_chromeOverlayAttempted = true;

    // Defer out of the QML-construction / scene-graph call stack: creating a second
    // QtQuick scene (QQuickRenderControl) re-entrantly during web-view construction is
    // unsafe. Run it on the next event-loop turn instead.
    qWarning("[WPE-DC-OVERLAY] scheduling overlay creation");
    QMetaObject::invokeMethod(this, "createChromeOverlayNow", Qt::QueuedConnection);
}

void WPEQtView::createChromeOverlayNow()
{
    if (m_chromeOverlay || !m_subsurface || !m_subsurface->isValid() || !window())
        return;
    qWarning("[WPE-DC-OVERLAY] creating overlay now");

    QPlatformNativeInterface* ni = QGuiApplication::platformNativeInterface();
    if (!ni)
        return;
    auto* display = static_cast<wl_display*>(ni->nativeResourceForIntegration(QByteArrayLiteral("display")));
    if (!display)
        display = static_cast<wl_display*>(ni->nativeResourceForIntegration(QByteArrayLiteral("wl_display")));
    auto* parentSurface = static_cast<wl_surface*>(ni->nativeResourceForWindow(QByteArrayLiteral("surface"), window()));
    auto* webSurface = static_cast<wl_surface*>(m_subsurface->webContentSurface());
    if (!display || !parentSurface)
        return;

    const qreal dpr = window()->effectiveDevicePixelRatio();
    QSize sz(qRound(m_size.width() * dpr), qRound(m_size.height() * dpr));
    if (sz.isEmpty())
        sz = window()->size() * dpr;
    if (sz.isEmpty())
        return;

    m_chromeOverlay = new WPEChromeOverlay();
    if (!m_chromeOverlay->create(display, parentSurface, sz)) {
        delete m_chromeOverlay;
        m_chromeOverlay = nullptr;
        return;
    }
    // Test path: the web subsurface was created before the overlay, so assert chrome
    // above it explicitly.
    if (webSurface)
        m_chromeOverlay->setWebSurface(webSurface);
}

void WPEQtView::updateSubsurfaceGeometry()
{
    if (!m_subsurface || !window())
        return;
    const qreal dpr = window()->effectiveDevicePixelRatio();
    const QRectF sceneRect = mapRectToScene(QRectF(QPointF(0, 0), m_size));
    m_subsurface->setGeometry(QRect(qRound(sceneRect.x() * dpr), qRound(sceneRect.y() * dpr),
                                    qRound(sceneRect.width() * dpr), qRound(sceneRect.height() * dpr)));
    // M1: create the overlay once a real size is known (covers the case where geometry
    // wasn't set yet at createWebView time). Resize handling is a later milestone.
    maybeCreateChromeOverlay();
    // set_position is applied on the parent surface's next commit; nudge Qt to
    // render a frame so the new position takes effect promptly.
    if (QQuickWindow* w = window())
        QMetaObject::invokeMethod(w, "update", Qt::QueuedConnection);
}

void WPEQtView::configureWindow()
{
    auto* win = window();
    if (!win)
        return;

    win->setSurfaceType(QWindow::OpenGLSurface);
    connect(win, &QQuickWindow::frameSwapped, this, [this]() {
        if (m_backend)
            m_backend->didRenderFrame();
    }, Qt::UniqueConnection);

    if (win->isSceneGraphInitialized())
        createWebView();
    else
        connect(win, &QQuickWindow::sceneGraphInitialized, this, &WPEQtView::createWebView);
}

void WPEQtView::createWebView()
{
    if (m_backend)
        return;

    auto display = static_cast<EGLDisplay>(QGuiApplication::platformNativeInterface()->nativeResourceForIntegration("egldisplay"));
    auto* context = window()->openglContext();
    std::unique_ptr<WPEQtViewBackend> backend = WPEQtViewBackend::create(m_size, context, display, QPointer<WPEQtView>(this));
    if (!backend) {
        qFatal("WPEQtView::createWebView(): EGL initialization failed");
        return;
    }

    m_backend = backend.get();

    // Direct-composite: present web frames into a dedicated wl_subsurface instead
    // of a QSG texture node, so the system compositor presents them directly
    // (no Qt scene-graph re-composite of web content). Falls back to the QSG path
    // if unavailable. Must be wired before the first exported frame.
    if (WPEWaylandSubsurface::enabled() && !m_subsurface) {
        m_subsurface = new WPEWaylandSubsurface();
        if (m_subsurface->ensureCreated(window())) {
            updateSubsurfaceGeometry();
            m_backend->setSubsurface(m_subsurface);
            maybeCreateChromeOverlay();
        } else {
            delete m_subsurface;
            m_subsurface = nullptr; // QSG path
        }
    }

    // enable-encrypted-media: EME v3 API (compiled in via ENABLE_ENCRYPTED_MEDIA).
    // WPE defaults the runtime pref off (UnifiedWebPreferences: WPE=false), so it
    // must be turned on explicitly. Without a Thunder/OpenCDM backend this only
    // provides the software ClearKey key system — no Widevine/PlayReady — but it
    // makes navigator.requestMediaKeySystemAccess exist so players can feature-
    // detect EME and degrade gracefully instead of hard-failing.
    auto* settings = webkit_settings_new_with_settings("enable-developer-extras", TRUE,
        "enable-webgl", TRUE, "enable-mediasource", TRUE,
        "enable-encrypted-media", TRUE, nullptr);
    // backend.release() may only be consumed once, so build the view backend value
    // up front and reuse it across the private/persistent construction branches.
    WebKitWebViewBackend* viewBackend = webkit_web_view_backend_new(
        m_backend->backend(),
        [](gpointer data) { delete static_cast<WPEQtViewBackend*>(data); },
        backend.release());
    if (m_privateBrowsing) {
        // Private tabs run against the shared ephemeral session: nothing (cookies,
        // cache, localStorage/IndexedDB, disk cache) is written to the persistent
        // profile. "network-session" is construct-only, hence set here at creation.
        m_webView = WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW,
            "backend", viewBackend,
            "settings", settings,
            "network-session", WPEQtView::privateSession(),
            nullptr));
    } else {
        m_webView = WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW,
            "backend", viewBackend,
            "settings", settings, nullptr));
    }
    g_clear_object(&settings);

    g_signal_connect_swapped(m_webView, "notify::uri", G_CALLBACK(notifyUrlChangedCallback), this);
    g_signal_connect_swapped(m_webView, "notify::title", G_CALLBACK(notifyTitleChangedCallback), this);
    g_signal_connect_swapped(m_webView, "notify::estimated-load-progress", G_CALLBACK(notifyLoadProgressCallback), this);
    g_signal_connect(m_webView, "load-changed", G_CALLBACK(notifyLoadChangedCallback), this);
    g_signal_connect(m_webView, "load-failed", G_CALLBACK(notifyLoadFailedCallback), this);

    // canGoBack/canGoForward used to be notified by loadingChanged only. A
    // same-document navigation (SPA pushState) emits no load change, so the
    // QML bindings went stale and the toolbar kept showing the home glyph
    // while several routes deep. The back-forward list's own "changed" signal
    // fires for those too, so drive the properties off it.
    if (WebKitBackForwardList* list = webkit_web_view_get_back_forward_list(m_webView))
        g_signal_connect_swapped(list, "changed", G_CALLBACK(notifyBackForwardChangedCallback), this);

    // Allow device-enumeration requests (harmless metadata). Camera/mic and
    // geolocation are deliberately NOT handled here: the embedder (browser)
    // connects its own permission-request handler and prompts the user.
    g_signal_connect(m_webView, "permission-request",
        G_CALLBACK(+[](WebKitWebView*, WebKitPermissionRequest* request, gpointer) -> gboolean {
            if (WEBKIT_IS_DEVICE_INFO_PERMISSION_REQUEST(request)) {
                webkit_permission_request_allow(request);
                return TRUE;
            }
            return FALSE;
        }), nullptr);

    // Route web-page clipboard writes (navigator.clipboard.writeText /
    // execCommand copy) to the SFOS system clipboard. Process-global and
    // idempotent, so it is safe to call from every view's init.
    WPEClipboardBridge::ensure();

    // Spellcheck (compiled in via enchant + bundled hunspell backend).
    if (WebKitWebContext* webContext = webkit_web_view_get_context(m_webView)) {
        webkit_web_context_set_spell_checking_enabled(webContext, TRUE);
        const gchar* spellLanguages[] = { "en_US", nullptr };
        webkit_web_context_set_spell_checking_languages(webContext, spellLanguages);

        // Geolocation: feed positions from Qt Positioning (SFOS GPS stack);
        // WebKit's own provider needs GeoClue2, which SFOS doesn't ship.
        WPEGeolocationBridge::ensure(webContext);
    }

    if (m_pendingDeviceScaleFactor != 1.0)
        webkit_web_view_set_zoom_level(m_webView, m_pendingDeviceScaleFactor);

    if (!m_pendingUserAgent.isEmpty()) {
        webkit_settings_set_user_agent(webkit_web_view_get_settings(m_webView),
                                       m_pendingUserAgent.toUtf8().constData());
    }

    if (!m_url.isEmpty())
        webkit_web_view_load_uri(m_webView, m_url.toString().toUtf8().constData());
    else if (!m_html.isEmpty())
        webkit_web_view_load_html(m_webView, m_html.toUtf8().constData(), m_baseUrl.toString().toUtf8().constData());

    // WPE ships the hidden-page throttling preferences off (Cocoa and GTK
    // default them on). Without them a hidden page still fires DOM timers at
    // full rate, so a timer-heavy background tab keeps burning CPU even after
    // the activity state drops the visible flag. Note: the feature API strips
    // the "Enabled" suffix from preference keys, so the identifiers are
    // "HiddenPageDOMTimerThrottling", not "...ThrottlingEnabled".
    if (WebKitSettings* attachedSettings = webkit_web_view_get_settings(m_webView)) {
        WebKitFeatureList* features = webkit_settings_get_all_features();
        const gsize featureCount = webkit_feature_list_get_length(features);
        for (gsize i = 0; i < featureCount; ++i) {
            WebKitFeature* feature = webkit_feature_list_get(features, i);
            const char* identifier = webkit_feature_get_identifier(feature);
            if (!g_strcmp0(identifier, "HiddenPageDOMTimerThrottling")
                || !g_strcmp0(identifier, "HiddenPageCSSAnimationSuspension")
                // WebRTC: compiled in (GstWebRTC) but the runtime prefs default off.
                || !g_strcmp0(identifier, "PeerConnection")
                || !g_strcmp0(identifier, "MediaDevices")
                // HTML5 form input types. WPE defaults every one of these runtime
                // prefs OFF (unlike GTK/Cocoa/iOS), so <input type=date|month|week|
                // time|datetime-local|color> silently degrade to type=text. There
                // is no dedicated enable-* GObject property for them, so flip them
                // here through the feature list (identifiers are the pref names with
                // the trailing "Enabled" stripped). This restores API/type presence
                // for feature detection; the date/time fields render as editable
                // component fields and color as a swatch (no native calendar/color
                // picker chrome on this port).
                || !g_strcmp0(identifier, "InputTypeDate")
                || !g_strcmp0(identifier, "InputTypeDateTimeLocal")
                || !g_strcmp0(identifier, "InputTypeMonth")
                || !g_strcmp0(identifier, "InputTypeWeek")
                || !g_strcmp0(identifier, "InputTypeTime")
                || !g_strcmp0(identifier, "InputTypeColor")) {
                webkit_settings_set_feature_enabled(attachedSettings, feature, TRUE);
                qDebug() << "[WPE-FEAT]" << identifier << "set, readback="
                         << webkit_settings_get_feature_enabled(attachedSettings, feature);
            }
        }
        webkit_feature_list_unref(features);
    }

    // The backend constructor starts with visible+focused+in_window; reconcile
    // with the visibility requested before the view existed (background tabs
    // are created hidden).
    applyWebKitVisibility();

    Q_EMIT webViewCreated();
}

void WPEQtView::setWebKitVisible(bool visible)
{
    if (m_webKitVisible == visible)
        return;
    m_webKitVisible = visible;
    applyWebKitVisibility();
}

void WPEQtView::applyWebKitVisibility()
{
    if (!m_backend)
        return;

    // in_window stays set for the lifetime of the view; only visible+focused
    // track tab/app foreground state. Dropping them flips
    // document.visibilityState to "hidden" and document.hasFocus() to false,
    // which suspends rAF and lets WebKit align DOM timers.
    const uint32_t flags = wpe_view_activity_state_visible | wpe_view_activity_state_focused;
    if (m_webKitVisible)
        wpe_view_backend_add_activity_state(m_backend->backend(), flags);
    else
        wpe_view_backend_remove_activity_state(m_backend->backend(), flags);

    // Direct-composite multi-tab: a tab's web subsurface must only show when it is the
    // visible (active, foreground) tab — otherwise every live tab composites at once and
    // they overlap. Move inactive tabs' web surface off-screen, and publish the visible
    // tab as the active web surface so the chrome overlay places_above the right one.
    if (m_subsurface) {
        m_subsurface->setVisible(m_webKitVisible);
        if (m_webKitVisible)
            WPEWaylandSubsurface::setActiveWebSurface(m_subsurface->webContentSurface());
    }
}

void WPEQtView::notifyUrlChangedCallback(WPEQtView* view)
{
    Q_EMIT view->urlChanged();
}

void WPEQtView::notifyBackForwardChangedCallback(WPEQtView* view)
{
    Q_EMIT view->backForwardChanged();
}

void WPEQtView::notifyTitleChangedCallback(WPEQtView* view)
{
    Q_EMIT view->titleChanged();
}

void WPEQtView::notifyLoadProgressCallback(WPEQtView* view)
{
    Q_EMIT view->loadProgressChanged();
}

void WPEQtView::notifyLoadChangedCallback(WebKitWebView*, WebKitLoadEvent event, WPEQtView* view)
{
    bool statusSet = false;
    WPEQtView::LoadStatus loadStatus;
    switch (event) {
    case WEBKIT_LOAD_STARTED:
        loadStatus = WPEQtView::LoadStatus::LoadStartedStatus;
        statusSet = true;
        break;
    case WEBKIT_LOAD_FINISHED:
        loadStatus = WPEQtView::LoadStatus::LoadSucceededStatus;
        statusSet = !view->errorOccured();
        view->setErrorOccured(false);
        break;
    default:
        break;
    }

    if (statusSet) {
        WPEQtViewLoadRequestPrivate loadRequestPrivate(view->url(), loadStatus, "");
        std::unique_ptr<WPEQtViewLoadRequest> loadRequest = std::make_unique<WPEQtViewLoadRequest>(loadRequestPrivate);
        Q_EMIT view->loadingChanged(loadRequest.get());
        // Keep the old notification too: canGoBack/canGoForward moved off
        // loadingChanged, and a load start/finish can change them before the
        // back-forward list itself reports a change.
        Q_EMIT view->backForwardChanged();
    }
}

void WPEQtView::notifyLoadFailedCallback(WebKitWebView*, WebKitLoadEvent, const gchar* failingURI, GError* error, WPEQtView* view)
{
    view->setErrorOccured(true);

    WPEQtView::LoadStatus loadStatus;
    if (g_error_matches(error, WEBKIT_NETWORK_ERROR, WEBKIT_NETWORK_ERROR_CANCELLED))
        loadStatus = WPEQtView::LoadStatus::LoadStoppedStatus;
    else
        loadStatus = WPEQtView::LoadStatus::LoadFailedStatus;

    WPEQtViewLoadRequestPrivate loadRequestPrivate(QUrl(QString(failingURI)), loadStatus, error->message);
    std::unique_ptr<WPEQtViewLoadRequest> loadRequest = std::make_unique<WPEQtViewLoadRequest>(loadRequestPrivate);
    Q_EMIT view->loadingChanged(loadRequest.get());
}

QSGNode* WPEQtView::updatePaintNode(QSGNode* node, UpdatePaintNodeData*)
{
    if (!m_webView || !m_backend)
        return node;

    // Direct-composite: web content is presented on the wl_subsurface, so this
    // item contributes nothing to the Qt scene — leaving a transparent hole the
    // subsurface (placed below the window surface) shows through. Drop any old node.
    if (m_subsurface && m_subsurface->isValid()) {
        delete node;
        return nullptr;
    }

    auto* textureNode = static_cast<QSGSimpleTextureNode*>(node);
    if (!textureNode) {
        textureNode = new QSGSimpleTextureNode();
        textureNode->setOwnsTexture(true);
    }

    GLuint textureId = m_backend->texture(window()->openglContext());
    if (!textureId)
        return node;

    // WEBKIT_ANCHOR_STALE_FRAME (default ON; set =0 to disable): between a resize
    // and the arrival of the first frame at the new size, the exported image
    // still holds the OLD size's content. The plain path wraps it as a texture
    // of the *new* m_size and STRETCHES it across boundingRect(), distorting the
    // whole frame until
    // WebKit repaints (~hundreds of ms on a heavy page) — very visible on every
    // toolbar toggle now that the viewport inset resizes frequently.
    //
    // When enabled, draw the frame at its TRUE aspect (uniform scale by width,
    // which a vertical inset does not change), top-anchored, and DO NOT clip it
    // to the item. In steady state frameSize maps exactly onto the item, so the
    // rect is boundingRect() — byte-identical to the plain path (and, crucially,
    // position:fixed bottom content is never clipped). Mid-resize the frame is
    // drawn at its native size instead of being stretched: on shrink (bar
    // appearing) the surplus height overflows below the item, where the toolbar
    // overlay covers it; on grow (bar hiding) the item's bottom strip is briefly
    // unfilled (page background) until the new-size frame arrives. No squash
    // either way. An earlier revision clamped the height to the item and clipped
    // via setSourceRect — that hid the floating bottom content the inset exists
    // to reveal, so the clamp was removed.
    static const bool anchorStaleFrame = [] {
        // Default ON: absent env -> enabled; only an explicit "0" disables it.
        return qgetenv("WEBKIT_ANCHOR_STALE_FRAME") != "0";
    }();
    // WEBKIT_FRAME_DEBUG=1: log item-vs-frame geometry on change so the actual
    // resize behavior can be read off the device instead of guessed at.
    static const bool frameDebug = [] {
        const QByteArray e = qgetenv("WEBKIT_FRAME_DEBUG");
        return !e.isEmpty() && e != "0";
    }();

    const QSize frameSize = anchorStaleFrame ? m_backend->currentImageSize() : QSize();
    const QSize textureSize = frameSize.isEmpty() ? m_size.toSize() : frameSize;
    QSGTexture *texture = textureNode->texture();
    if (!texture || texture->textureSize() != textureSize) {
#if (QT_VERSION >= QT_VERSION_CHECK(5, 15, 0))
        texture = window()->createTextureFromNativeObject(QQuickWindow::NativeObjectTexture, &textureId, 0, textureSize, QQuickWindow::TextureHasAlphaChannel);
#else
        texture = window()->createTextureFromId(textureId, textureSize, QQuickWindow::TextureHasAlphaChannel);
#endif
        textureNode->setTexture(texture);
    }

    const QRectF item = boundingRect();
    if (frameDebug) {
        const QSize realFrame = m_backend->currentImageSize();
        static QSize lastItem, lastFrame;
        const QSize itemSz = item.size().toSize();
        if (itemSz != lastItem || realFrame != lastFrame) {
            lastItem = itemSz; lastFrame = realFrame;
            qWarning("[FRAME-DBG] item=%dx%d frame=%dx%d m_size=%dx%d",
                     itemSz.width(), itemSz.height(), realFrame.width(), realFrame.height(),
                     m_size.toSize().width(), m_size.toSize().height());
        }
    }

    if (frameSize.isEmpty() || item.width() <= 0.0 || frameSize.width() <= 0) {
        // Plain path: stretch the frame to fill the item (original behavior).
        textureNode->setRect(item);
    } else {
        // True aspect, top-anchored, no clip (see block comment above).
        const qreal scale = item.width() / qreal(frameSize.width());
        const qreal drawnH = frameSize.height() * scale;
        textureNode->setRect(QRectF(0.0, 0.0, item.width(), drawnH));
    }
    return textureNode;
}

QUrl WPEQtView::url() const
{
    if (!m_webView)
        return m_url;

    const gchar* uri = webkit_web_view_get_uri(m_webView);
    return uri ? QUrl(QString(uri)) : m_url;
}

/*!
  \qmlproperty url WPEView::url

  The URL of currently loaded web page. Changing this will trigger
  loading new content.

  The URL is used as-is. URLs that originate from user input should
  be parsed with QUrl::fromUserInput().

  \note The WPEView does not support loading content through the Qt Resource system.
*/
void WPEQtView::setUrl(const QUrl& url)
{
    if (url == m_url)
        return;

    m_errorOccured = false;
    m_url = url;
    if (m_webView)
        webkit_web_view_load_uri(m_webView, m_url.toString().toUtf8().constData());
}

/*!
  \qmlproperty int WPEView::loadProgress
  \readonly

  The current load progress of the web content, represented as
  an integer between 0 and 100.
*/
int WPEQtView::loadProgress() const
{
    if (!m_webView)
        return 0;

    return webkit_web_view_get_estimated_load_progress(m_webView) * 100;
}

/*!
  \qmlproperty string WPEView::title
  \readonly

  The title of the currently loaded web page.
*/
QString WPEQtView::title() const
{
    if (!m_webView)
        return "";

    return webkit_web_view_get_title(m_webView);
}

/*!
  \qmlproperty bool WPEView::canGoBack
  \readonly

  Holds \c true if it's currently possible to navigate back in the web history.
*/
bool WPEQtView::canGoBack() const
{
    if (!m_webView)
        return false;

    return webkit_web_view_can_go_back(m_webView);
}

/*!
  \qmlproperty bool WPEView::loading
  \readonly

  Holds \c true if the WPEView is currently in the process of loading
  new content, \c false otherwise.

  \sa loadingChanged()
*/

/*!
  \qmlsignal WPEView::loadingChanged(WPEViewLoadRequest loadRequest)

  This signal is emitted when the state of loading the web content changes.
  By handling this signal it's possible, for example, to react to page load
  errors.

  The \a loadRequest parameter holds the \e url and \e status of the request,
  as well as an \e errorString containing an error message for a failed
  request.

  \sa WPEViewLoadRequest
*/
bool WPEQtView::isLoading() const
{
    if (!m_webView)
        return false;

    return webkit_web_view_is_loading(m_webView);
}

/*!
  \qmlproperty bool WPEView::canGoForward
  \readonly

  Holds \c true if it's currently possible to navigate forward in the web history.
*/
bool WPEQtView::canGoForward() const
{
    if (!m_webView)
        return false;

    return webkit_web_view_can_go_forward(m_webView);
}

/*!
  \qmlmethod void WPEView::goBack()

  Navigates back in the web history.
*/
// Strict history navigation: step to the immediately adjacent back/forward item
// instead of letting WebKit skip entries.
//
// webkit_web_view_go_back() lands on
// WebBackForwardList::goBackItemSkippingItemsWithoutUserGesture(), which walks
// over every item flagged wasCreatedByJSWithoutUserInteraction. A single press
// then collapses a whole run of SPA pushState routes down to the previous
// *document*: on forum.sailfishos.org, home -> topic A -> topic B goes straight
// back to home, skipping topic A. Frameworks that push their routes from a
// runloop/promise continuation (Ember, and anything else that leaves the tap's
// gesture scope) lose the user-interaction attribution the skip logic keys on.
//
// webkit_web_view_go_to_back_forward_list_item() routes to
// WebPageProxy::goToBackForwardItem() directly and does no skipping, so taking
// the adjacent item explicitly gives a strict one-step back.
//
// Off by default: the upstream skipping is what defeats history-trapping pages,
// so this is opt-in until measured on device. ATLANTIC_STRICT_HISTORY_NAV=1.
static bool strictHistoryNavigationEnabled()
{
    static const bool enabled = qgetenv("ATLANTIC_STRICT_HISTORY_NAV").toInt() == 1;
    return enabled;
}

void WPEQtView::goBack()
{
    if (!m_webView)
        return;

    if (strictHistoryNavigationEnabled()) {
        WebKitBackForwardList* list = webkit_web_view_get_back_forward_list(m_webView);
        if (WebKitBackForwardListItem* item = list ? webkit_back_forward_list_get_back_item(list) : nullptr) {
            webkit_web_view_go_to_back_forward_list_item(m_webView, item);
            return;
        }
    }

    webkit_web_view_go_back(m_webView);
}

/*!
  \qmlmethod void WPEView::goForward()

  Navigates forward in the web history.
*/
void WPEQtView::goForward()
{
    if (!m_webView)
        return;

    if (strictHistoryNavigationEnabled()) {
        WebKitBackForwardList* list = webkit_web_view_get_back_forward_list(m_webView);
        if (WebKitBackForwardListItem* item = list ? webkit_back_forward_list_get_forward_item(list) : nullptr) {
            webkit_web_view_go_to_back_forward_list_item(m_webView, item);
            return;
        }
    }

    webkit_web_view_go_forward(m_webView);
}

/*!
  \qmlmethod void WPEView::reload()

  Reloads the current \l url.
*/
void WPEQtView::reload()
{
    if (m_webView)
        webkit_web_view_reload(m_webView);
}

/*!
  \qmlmethod void WPEView::stop()

  Stops loading the current \l url.
*/
void WPEQtView::stop()
{
    if (m_webView)
        webkit_web_view_stop_loading(m_webView);
}

/*!
  \qmlmethod void WPEView::loadHtml(string html, url baseUrl)

  Loads the specified \a html content to the web view.

  This method offers a lower-level alternative to the \l url property,
  which references HTML pages via URL.

  External objects such as stylesheets or images referenced in the HTML
  document should be located relative to \a baseUrl. For example, if \a html
  is retrieved from \c http://www.example.com/documents/overview.html, which
  is the base URL, then an image referenced with the relative url, \c diagram.png,
  should be at \c{http://www.example.com/documents/diagram.png}.

  \note The WPEView does not support loading content through the Qt Resource system.

  \sa url
*/
void WPEQtView::loadHtml(const QString& html, const QUrl& baseUrl)
{
    m_html = html;
    m_baseUrl = baseUrl;
    m_errorOccured = false;

    if (m_webView)
        webkit_web_view_load_html(m_webView, html.toUtf8().constData(), baseUrl.toString().toUtf8().constData());
}

struct JavascriptCallbackData {
    JavascriptCallbackData(QJSValue cb, QPointer<WPEQtView> obj)
        : callback(cb)
        , object(obj) { }

    QJSValue callback;
    QPointer<WPEQtView> object;
};

static void jsAsyncReadyCallback(GObject* object, GAsyncResult* result, gpointer userData)
{
    GError* error { nullptr };
    std::unique_ptr<JavascriptCallbackData> data(reinterpret_cast<JavascriptCallbackData*>(userData));
    JSCValue* value = webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(object), result, &error);
    if (!value) {
        qWarning("Error running javascript: %s", error->message);
        g_error_free(error);
        return;
    }

    if (data->object.data()) {
        QQmlEngine* engine = qmlEngine(data->object.data());
        if (!engine) {
            qWarning("No JavaScript engine, unable to handle JavaScript callback!");
            g_object_unref(value);
            return;
        }

        QJSValueList args;
        QVariant variant;
        // FIXME: Handle more value types?
        if (jsc_value_is_string(value)) {
            auto* strValue = jsc_value_to_string(value);
            JSCContext* context = jsc_value_get_context(value);
            JSCException* exception = jsc_context_get_exception(context);
            if (exception) {
                qWarning("Error running javascript: %s", jsc_exception_get_message(exception));
                jsc_context_clear_exception(context);
            } else
                variant.setValue(QString::fromUtf8(strValue));
            g_free(strValue);
        }
        args.append(engine->toScriptValue(variant));
        data->callback.call(args);
    }
    g_object_unref(value);
}

/*!
  \qmlmethod void WPEView::runJavaScript(string script, variant callback)

  Runs the specified JavaScript.
  In case a \a callback function is provided, it will be invoked after the \a script
  finished running.

  \badcode
  runJavaScript("document.title", function(result) { console.log(result); });
  \endcode
*/
void WPEQtView::runJavaScript(const QString& script, const QJSValue& callback)
{
    std::unique_ptr<JavascriptCallbackData> data = std::make_unique<JavascriptCallbackData>(callback, QPointer<WPEQtView>(this));
    auto utf8Script = script.toUtf8();
    webkit_web_view_evaluate_javascript(m_webView, utf8Script.constData(), utf8Script.size(), nullptr, nullptr, nullptr, jsAsyncReadyCallback, data.release());
}

void WPEQtView::mousePressEvent(QMouseEvent* event)
{
    static int n = 0;
    if (n++ < 8) qWarning("[WPE-INPUT] WPEQtView mousePress (%g,%g)", event->localPos().x(), event->localPos().y());
    forceActiveFocus();
    if (m_backend)
        m_backend->dispatchMousePressEvent(event);
}

void WPEQtView::mouseReleaseEvent(QMouseEvent* event)
{
    if (m_backend)
        m_backend->dispatchMouseReleaseEvent(event);
}

void WPEQtView::hoverEnterEvent(QHoverEvent* event)
{
    if (m_backend)
        m_backend->dispatchHoverEnterEvent(event);
}

void WPEQtView::hoverLeaveEvent(QHoverEvent* event)
{
    if (m_backend)
        m_backend->dispatchHoverLeaveEvent(event);
}

void WPEQtView::hoverMoveEvent(QHoverEvent* event)
{
    if (m_backend)
        m_backend->dispatchHoverMoveEvent(event);
}

void WPEQtView::wheelEvent(QWheelEvent* event)
{
    if (m_backend)
        m_backend->dispatchWheelEvent(event);
}

void WPEQtView::keyPressEvent(QKeyEvent* event)
{
    if (m_backend)
        m_backend->dispatchKeyEvent(event, true);
}

void WPEQtView::keyReleaseEvent(QKeyEvent* event)
{
    if (m_backend)
        m_backend->dispatchKeyEvent(event, false);
}

void WPEQtView::touchEvent(QTouchEvent* event)
{
    if (m_backend)
        m_backend->dispatchTouchEvent(event);
}

WebKitWebView* WPEQtView::webView() const
{
    return m_webView;
}

WebKitNetworkSession* WPEQtView::privateSession()
{
    // One ephemeral session shared by every private view, created on first use.
    // Ephemeral => the NetworkProcess keeps cookies/cache/storage in memory only
    // and discards them when the session is destroyed (process exit). Never freed
    // here: it outlives individual private views, which hold their own ref.
    static WebKitNetworkSession* s_session = nullptr;
    if (!s_session)
        s_session = webkit_network_session_new_ephemeral();
    return s_session;
}

void WPEQtView::clearPrivateBrowsingData()
{
    WebKitWebsiteDataManager* manager =
        webkit_network_session_get_website_data_manager(privateSession());
    if (manager)
        webkit_website_data_manager_clear(manager, WEBKIT_WEBSITE_DATA_ALL,
                                          0, nullptr, nullptr, nullptr);
}

void WPEQtView::setUserAgent(const QString& userAgent)
{
    // The web view is created lazily (deferred until the scene graph is
    // initialised), so buffer the UA instead of dropping it — otherwise an
    // early caller silently leaves the stock WPE UA in place and sites serve
    // the wrong variant for the whole session.
    m_pendingUserAgent = userAgent;
    if (!m_webView)
        return;
    WebKitSettings* settings = webkit_web_view_get_settings(m_webView);
    webkit_settings_set_user_agent(settings, userAgent.toUtf8().constData());
}

void WPEQtView::setDeviceScaleFactor(qreal scale)
{
    m_pendingDeviceScaleFactor = scale;
    if (!m_webView)
        return;
    webkit_web_view_set_zoom_level(m_webView, scale);
}
