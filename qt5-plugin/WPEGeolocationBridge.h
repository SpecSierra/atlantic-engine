/*
 * Copyright (C) 2026 Atlantic Browser contributors
 *
 * SPDX-License-Identifier: MPL-2.0
 */

#pragma once

#include <QGeoPositionInfo>
#include <QObject>
#include <wpe/webkit.h>

class QGeoPositionInfoSource;

// Bridges WebKitGeolocationManager to Qt Positioning (which SFOS backs with
// its geoclue-0.x/hybris GPS stack). WebKit's built-in provider only speaks
// GeoClue2, which Sailfish OS does not ship — when the "start" signal is
// handled here, WebKit skips that provider entirely and takes positions from
// webkit_geolocation_manager_update_position().
class WPEGeolocationBridge final : public QObject {
    Q_OBJECT

public:
    // Attach the bridge to a web context's geolocation manager. Safe to call
    // once per context; subsequent calls for the same context are no-ops.
    static void ensure(WebKitWebContext*);

private:
    explicit WPEGeolocationBridge(WebKitGeolocationManager*);

    void start();
    void stop();
    void handlePositionUpdated(const QGeoPositionInfo&);

    WebKitGeolocationManager* m_manager { nullptr };
    QGeoPositionInfoSource* m_source { nullptr };
};
