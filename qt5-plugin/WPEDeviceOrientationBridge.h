/*
 * Copyright (C) 2026 Atlantic Browser contributors
 *
 * SPDX-License-Identifier: MPL-2.0
 */

#pragma once

#include <QObject>
#include <wpe/webkit.h>

class QAccelerometer;
class QGyroscope;
class QRotationSensor;

// Feeds WebKit's DeviceOrientation/DeviceMotion controllers from QtSensors
// (which SFOS backs with sensorfw). WPE has no public API for this — unlike
// geolocation, where WebKitGeolocationManager exists — so the engine patch
// webkit-wpe-device-orientation.patch exports wpe_sfos_device_orientation_changed(),
// wpe_sfos_device_motion_changed() and wpe_sfos_set_device_sensors_callback(),
// and this class drives them.
//
// Sensors only run while WebKit says a page is listening: the callback is
// invoked from the web process as deviceorientation/devicemotion listeners are
// added and removed, so a page that never touches the API costs nothing.
class WPEDeviceOrientationBridge final : public QObject {
    Q_OBJECT

public:
    // Attach to a web view. Safe to call repeatedly for the same view; only the
    // first call does anything.
    static void ensure(WebKitWebView*);

private:
    explicit WPEDeviceOrientationBridge(WebKitWebView*);
    ~WPEDeviceOrientationBridge() override;

    void setNeeded(bool orientationNeeded, bool motionNeeded);
    void handleRotationChanged();
    void handleMotionChanged();

    WebKitWebView* m_webView { nullptr };

    QRotationSensor* m_rotation { nullptr };
    QAccelerometer* m_accelerometer { nullptr };
    QAccelerometer* m_linearAccelerometer { nullptr };
    QGyroscope* m_gyroscope { nullptr };

    bool m_orientationActive { false };
    bool m_motionActive { false };
};
