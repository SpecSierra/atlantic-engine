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

#pragma once

#include <QQmlEngine>
#include <QQuickItem>
#include <QUrl>
#include <memory>
#include <wpe/webkit.h>

class WPEQtViewBackend;
class WPEQtViewLoadRequest;
class WPEWaylandSubsurface;
class WPEChromeOverlay;

class Q_DECL_EXPORT WPEQtView : public QQuickItem {
    Q_OBJECT
    Q_DISABLE_COPY(WPEQtView)
    Q_PROPERTY(QUrl url READ url WRITE setUrl NOTIFY urlChanged)
    Q_PROPERTY(bool loading READ isLoading NOTIFY loadingChanged)
    Q_PROPERTY(int loadProgress READ loadProgress NOTIFY loadProgressChanged)
    Q_PROPERTY(QString title READ title NOTIFY titleChanged)
    Q_PROPERTY(bool canGoBack READ canGoBack NOTIFY loadingChanged)
    Q_PROPERTY(bool canGoForward READ canGoForward NOTIFY loadingChanged)
    Q_ENUMS(LoadStatus)

public:
    enum LoadStatus {
        LoadStartedStatus,
        LoadStoppedStatus,
        LoadSucceededStatus,
        LoadFailedStatus
    };

    WPEQtView(QQuickItem* parent = nullptr);
    ~WPEQtView();
    QSGNode* updatePaintNode(QSGNode*, UpdatePaintNodeData*) final;

    void triggerUpdate() { QMetaObject::invokeMethod(this, "update"); };

    // Called by WPEQtViewBackend's libwpe fullscreen handler when the page
    // requests entering/leaving fullscreen.  Re-emitted as Qt signals so the
    // embedding UI can switch the window state.
    void notifyFullscreenRequest(bool enter)
    {
        if (enter)
            Q_EMIT enterFullscreenRequested();
        else
            Q_EMIT leaveFullscreenRequested();
    }

    QUrl url() const;
    void setUrl(const QUrl&);
    int loadProgress() const;
    QString title() const;
    bool canGoBack() const;
    bool isLoading() const;
    bool canGoForward() const;

    WebKitWebView* webView() const;

    void setUserAgent(const QString& userAgent);
    void setDeviceScaleFactor(qreal scale);

    // Drives the WPE activity state (visible+focused) so WebKit throttles
    // hidden pages: rAF stops and DOM timers align once the page is no longer
    // the active foreground tab. Safe to call before the backend exists; the
    // pending state is applied when the web view is created.
    void setWebKitVisible(bool visible);
    bool webKitVisible() const { return m_webKitVisible; }

    // Private (incognito) browsing. MUST be set before the web view is created
    // (i.e. before the item is parented into a window), otherwise it is ignored:
    // the web view's network session is construct-only. When true, the view is
    // created against a process-wide ephemeral WebKitNetworkSession, so cookies,
    // cache, localStorage/IndexedDB and disk cache stay in memory only and never
    // touch the persistent profile. All private views share one session (so a
    // link opened in a new private tab keeps its login) — see privateSession().
    void setPrivateBrowsing(bool p) { m_privateBrowsing = p; }
    bool privateBrowsing() const { return m_privateBrowsing; }

    // The shared ephemeral session backing every private view (lazily created).
    static WebKitNetworkSession* privateSession();
    // Drop all in-memory data of the private session (cookies/cache/storage).
    // Call when the last private tab closes so re-entering private mode starts
    // clean within a single browser run.
    static void clearPrivateBrowsingData();

    // Direct-composite: the web content wl_surface (void*), so the browser can create a
    // chrome overlay subsurface place_above it. Null unless the direct-composite
    // subsurface is active. See WPEWaylandSubsurface::webContentSurface.
    void* webContentSurface() const;

public Q_SLOTS:
    // Direct-composite only: show/hide the web content surface. The chrome cannot
    // be stacked above the web surface on lipstick, so the UI hides the web surface
    // while its overlay is engaged and shows it (full-screen) while browsing. No-op
    // on the legacy QSG path (no subsurface). See WPEWaylandSubsurface::setVisible.
    void setWebContentSurfaceVisible(bool visible);
    void goBack();
    void goForward();
    void reload();
    void stop();
    void loadHtml(const QString& html, const QUrl& baseUrl = QUrl());
    void runJavaScript(const QString& script, const QJSValue& callback = QJSValue());

Q_SIGNALS:
    void webViewCreated();
    void urlChanged();
    void titleChanged();
    void loadingChanged(WPEQtViewLoadRequest* loadRequest);
    void loadProgressChanged();
    void scrollPositionChanged(qreal scrollY, qreal scrollHeight, qreal innerHeight);
    void faviconUrlChanged(const QString& url);
    void selectedTextChanged(const QString& text);
    void selectionHandlesChanged(qreal startX, qreal startY, qreal endX, qreal endY);
    void enterFullscreenRequested();
    void leaveFullscreenRequested();

protected:
    bool errorOccured() const { return m_errorOccured; };
    void setErrorOccured(bool errorOccured) { m_errorOccured = errorOccured; };

    void geometryChanged(const QRectF& newGeometry, const QRectF& oldGeometry) override;

    void hoverEnterEvent(QHoverEvent*) override;
    void hoverLeaveEvent(QHoverEvent*) override;
    void hoverMoveEvent(QHoverEvent*) override;

    void mousePressEvent(QMouseEvent*) override;
    void mouseReleaseEvent(QMouseEvent*) override;
    void wheelEvent(QWheelEvent*) override;

    void keyPressEvent(QKeyEvent*) override;
    void keyReleaseEvent(QKeyEvent*) override;

    void touchEvent(QTouchEvent*) override;

private Q_SLOTS:
    void configureWindow();
    void createWebView();
    void createChromeOverlayNow();

private:
    static void notifyUrlChangedCallback(WPEQtView*);
    static void notifyTitleChangedCallback(WPEQtView*);
    static void notifyLoadProgressCallback(WPEQtView*);
    static void notifyLoadChangedCallback(WebKitWebView*, WebKitLoadEvent, WPEQtView*);
    static void notifyLoadFailedCallback(WebKitWebView*, WebKitLoadEvent, const gchar* failingURI, GError*, WPEQtView*);

    WebKitWebView* m_webView { nullptr };
    QUrl m_url;
    QString m_html;
    QUrl m_baseUrl;
    QSizeF m_size;
    void applyWebKitVisibility();

    // Pushes the item's on-screen rect (device pixels) to the direct-composite
    // subsurface, when active.
    void updateSubsurfaceGeometry();

    WPEQtViewBackend* m_backend { nullptr };
    WPEWaylandSubsurface* m_subsurface { nullptr };
    WPEChromeOverlay* m_chromeOverlay { nullptr };
    bool m_chromeOverlayAttempted { false };
    // Create the chrome overlay subsurface (ATLANTIC_DC_OVERLAY_TEST) above the web,
    // once the web subsurface exists. M1 validation hook (defers to createChromeOverlayNow).
    void maybeCreateChromeOverlay();
    bool m_webKitVisible { true };
    bool m_privateBrowsing { false };
    bool m_errorOccured { false };
    qreal m_pendingDeviceScaleFactor { 1.0 };
    QString m_pendingUserAgent;
};
