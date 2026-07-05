/*
 * Copyright (C) 2026 Atlantic Browser contributors
 *
 * SPDX-License-Identifier: MPL-2.0
 */

#include "WPEGeolocationBridge.h"

#include <QDebug>
#include <QGeoPositionInfoSource>
#include <QSet>

void WPEGeolocationBridge::ensure(WebKitWebContext* context)
{
    static QSet<WebKitWebContext*> bridgedContexts;
    if (!context || bridgedContexts.contains(context))
        return;
    bridgedContexts.insert(context);

    auto* manager = webkit_web_context_get_geolocation_manager(context);
    // Lifetime: the bridge lives as long as the manager (owned by the
    // context, which for the browser lives until process exit).
    auto* bridge = new WPEGeolocationBridge(manager);
    g_object_set_data_full(G_OBJECT(manager), "wpe-qt-geolocation-bridge", bridge,
        [](gpointer data) { delete static_cast<WPEGeolocationBridge*>(data); });
}

WPEGeolocationBridge::WPEGeolocationBridge(WebKitGeolocationManager* manager)
    : m_manager(manager)
{
    g_signal_connect_swapped(manager, "start",
        G_CALLBACK(+[](WPEGeolocationBridge* bridge) { bridge->start(); }), this);
    g_signal_connect_swapped(manager, "stop",
        G_CALLBACK(+[](WPEGeolocationBridge* bridge) { bridge->stop(); }), this);
}

void WPEGeolocationBridge::start()
{
    if (!m_source) {
        m_source = QGeoPositionInfoSource::createDefaultSource(this);
        if (!m_source) {
            qWarning() << "[WPE-GEO] no Qt position source available";
            webkit_geolocation_manager_failed(m_manager, "No position source available");
            return;
        }
        qDebug() << "[WPE-GEO] using position source" << m_source->sourceName();
        connect(m_source, &QGeoPositionInfoSource::positionUpdated,
                this, &WPEGeolocationBridge::handlePositionUpdated);
        connect(m_source, static_cast<void (QGeoPositionInfoSource::*)(QGeoPositionInfoSource::Error)>(&QGeoPositionInfoSource::error),
                this, [this](QGeoPositionInfoSource::Error error) {
                    qWarning() << "[WPE-GEO] position source error" << error;
                    webkit_geolocation_manager_failed(m_manager, "Position source error");
                });
    }

    m_source->setPreferredPositioningMethods(
        webkit_geolocation_manager_get_enable_high_accuracy(m_manager)
            ? QGeoPositionInfoSource::AllPositioningMethods
            : QGeoPositionInfoSource::NonSatellitePositioningMethods);
    m_source->startUpdates();

    // Seed with the last known position so pages get a fast (if stale) fix
    // while the GPS warms up.
    QGeoPositionInfo lastKnown = m_source->lastKnownPosition();
    if (lastKnown.isValid())
        handlePositionUpdated(lastKnown);
}

void WPEGeolocationBridge::stop()
{
    if (m_source)
        m_source->stopUpdates();
}

void WPEGeolocationBridge::handlePositionUpdated(const QGeoPositionInfo& info)
{
    const QGeoCoordinate coordinate = info.coordinate();
    if (!coordinate.isValid())
        return;

    double accuracy = info.hasAttribute(QGeoPositionInfo::HorizontalAccuracy)
        ? info.attribute(QGeoPositionInfo::HorizontalAccuracy) : 1000;
    WebKitGeolocationPosition* position = webkit_geolocation_position_new(
        coordinate.latitude(), coordinate.longitude(), accuracy);

    if (info.timestamp().isValid())
        webkit_geolocation_position_set_timestamp(position, info.timestamp().toTime_t());
    if (coordinate.type() == QGeoCoordinate::Coordinate3D) {
        webkit_geolocation_position_set_altitude(position, coordinate.altitude());
        if (info.hasAttribute(QGeoPositionInfo::VerticalAccuracy))
            webkit_geolocation_position_set_altitude_accuracy(position, info.attribute(QGeoPositionInfo::VerticalAccuracy));
    }
    if (info.hasAttribute(QGeoPositionInfo::GroundSpeed))
        webkit_geolocation_position_set_speed(position, info.attribute(QGeoPositionInfo::GroundSpeed));
    if (info.hasAttribute(QGeoPositionInfo::Direction))
        webkit_geolocation_position_set_heading(position, info.attribute(QGeoPositionInfo::Direction));

    webkit_geolocation_manager_update_position(m_manager, position);
    webkit_geolocation_position_free(position);
}
