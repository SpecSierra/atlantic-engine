/*
 * Copyright (C) 2026 Atlantic Browser contributors
 *
 * SPDX-License-Identifier: MPL-2.0
 */

#include "WPEDeviceOrientationBridge.h"

#include <QAccelerometer>
#include <QDebug>
#include <QGyroscope>
#include <QRotationSensor>
#include <QSet>
#include <cmath>

// Exported by webkit-wpe-device-orientation.patch. Declared here rather than in
// a header because they are deliberately not part of the installed WPE API.
extern "C" {
void wpe_sfos_set_device_sensors_callback(WebKitWebView*, void (*)(gboolean orientationNeeded, gboolean motionNeeded, gpointer), gpointer);
void wpe_sfos_device_orientation_changed(WebKitWebView*, double alpha, double beta, double gamma, gboolean absolute);
void wpe_sfos_device_motion_changed(WebKitWebView*, double x, double y, double z, double xIncludingGravity, double yIncludingGravity, double zIncludingGravity, double alphaRotationRate, double betaRotationRate, double gammaRotationRate, double interval);
}

// W3C asks for roughly 60 Hz on devicemotion; orientation does not need to be
// anywhere near that fast and a compass fix is noisy at high rates.
static constexpr int kMotionRateHz = 60;
static constexpr int kOrientationRateHz = 30;

void WPEDeviceOrientationBridge::ensure(WebKitWebView* webView)
{
    static QSet<WebKitWebView*> bridgedViews;
    if (!webView || bridgedViews.contains(webView))
        return;
    bridgedViews.insert(webView);

    // Lifetime: tied to the view, matching WPEGeolocationBridge's arrangement
    // with the geolocation manager.
    auto* bridge = new WPEDeviceOrientationBridge(webView);
    g_object_set_data_full(G_OBJECT(webView), "wpe-qt-device-orientation-bridge", bridge,
        [](gpointer data) { delete static_cast<WPEDeviceOrientationBridge*>(data); });
}

WPEDeviceOrientationBridge::WPEDeviceOrientationBridge(WebKitWebView* webView)
    : m_webView(webView)
{
    wpe_sfos_set_device_sensors_callback(webView,
        [](gboolean orientationNeeded, gboolean motionNeeded, gpointer userData) {
            static_cast<WPEDeviceOrientationBridge*>(userData)->setNeeded(orientationNeeded != FALSE, motionNeeded != FALSE);
        }, this);
}

WPEDeviceOrientationBridge::~WPEDeviceOrientationBridge()
{
    if (m_webView)
        wpe_sfos_set_device_sensors_callback(m_webView, nullptr, nullptr);
}

void WPEDeviceOrientationBridge::setNeeded(bool orientationNeeded, bool motionNeeded)
{
    if (orientationNeeded != m_orientationActive) {
        if (orientationNeeded) {
            if (!m_rotation) {
                m_rotation = new QRotationSensor(this);
                // Without the z axis there is no compass component, so the
                // reading is relative to an arbitrary starting orientation and
                // the events must say absolute=false.
                m_rotation->setHasZ(true);
                m_rotation->setDataRate(kOrientationRateHz);
                connect(m_rotation, &QRotationSensor::readingChanged,
                        this, &WPEDeviceOrientationBridge::handleRotationChanged);
            }
            if (!m_rotation->start())
                qWarning() << "[WPE-SENSOR] rotation sensor failed to start";
        } else if (m_rotation)
            m_rotation->stop();
        m_orientationActive = orientationNeeded;
    }

    if (motionNeeded == m_motionActive)
        return;

    if (motionNeeded) {
        if (!m_accelerometer) {
            m_accelerometer = new QAccelerometer(this);
            m_accelerometer->setDataRate(kMotionRateHz);
            connect(m_accelerometer, &QAccelerometer::readingChanged,
                    this, &WPEDeviceOrientationBridge::handleMotionChanged);

            // acceleration (gravity removed) and accelerationIncludingGravity
            // are separate fields on the event and one sensor can only report
            // one mode at a time, so the gravity-free figure needs its own
            // instance. Not every backend implements User mode; when it is
            // missing the field stays NaN, which the engine turns into null
            // rather than a fabricated 0.
            auto* linear = new QAccelerometer(this);
            if (linear->isFeatureSupported(QSensor::AccelerationMode)) {
                linear->setAccelerationMode(QAccelerometer::User);
                linear->setDataRate(kMotionRateHz);
                m_linearAccelerometer = linear;
            } else {
                qInfo() << "[WPE-SENSOR] no User acceleration mode; event.acceleration will be null";
                delete linear;
            }
        }
        if (!m_gyroscope) {
            m_gyroscope = new QGyroscope(this);
            m_gyroscope->setDataRate(kMotionRateHz);
        }
        if (!m_accelerometer->start())
            qWarning() << "[WPE-SENSOR] accelerometer failed to start";
        if (m_linearAccelerometer)
            m_linearAccelerometer->start();
        if (!m_gyroscope->start())
            qInfo() << "[WPE-SENSOR] no gyroscope; event.rotationRate will be null";
    } else {
        if (m_accelerometer)
            m_accelerometer->stop();
        if (m_linearAccelerometer)
            m_linearAccelerometer->stop();
        if (m_gyroscope)
            m_gyroscope->stop();
    }
    m_motionActive = motionNeeded;
}

void WPEDeviceOrientationBridge::handleRotationChanged()
{
    QRotationReading* reading = m_rotation ? m_rotation->reading() : nullptr;
    if (!reading)
        return;

    // Axis mapping, measured on the device (Xperia 10 II / sensorfw) against the
    // gravity vector, which is unambiguous. Three held-still orientations, each
    // matching to within a degree:
    //
    //   reported y  |  y - 180  |  gravity-derived gamma
    //        174    |     -6    |         -6
    //        110    |    -70    |        -70
    //        155    |    -25    |        -25
    //
    // So sensorfw's y is the W3C gamma offset by 180, and its x is beta negated
    // (reported -9 where gravity said +9). Neither matches the documented Qt
    // convention, which is why this is measured rather than assumed. Do not
    // "simplify" these back to a straight pass-through.
    //
    // The one case the measurement did not cover is |gamma| past 90 — rolled
    // beyond on-edge — so the normalisation below is by the spec's rule rather
    // than by observation, and is the first thing to check if a page misbehaves
    // when the device is nearly upside down.
    double beta = -reading->x();
    double gamma = reading->y() - 180.0;

    // W3C: gamma is [-90, 90] and beta is [-180, 180). Rolling past on-edge is
    // represented by flipping beta rather than by letting gamma run out of range.
    if (gamma > 90.0) {
        gamma = 180.0 - gamma;
        beta = 180.0 - beta;
    } else if (gamma < -90.0) {
        gamma = -180.0 - gamma;
        beta = 180.0 - beta;
    }
    beta = std::fmod(beta + 180.0, 360.0);
    if (beta < 0)
        beta += 360.0;
    beta -= 180.0;

    // setHasZ() only *requests* the compass component; hasZ() after start is
    // what the backend actually provides. Without it there is no Earth frame of
    // reference, so alpha is meaningless and absolute must be false.
    const bool absolute = m_rotation->hasZ();
    double alpha = NAN;
    if (absolute) {
        // W3C: alpha is [0, 360). sensorfw hands out negative values here
        // (-161 was measured), which pages doing arithmetic on a compass
        // heading will read as a bearing behind them.
        alpha = std::fmod(reading->z(), 360.0);
        if (alpha < 0)
            alpha += 360.0;
    }

    wpe_sfos_device_orientation_changed(m_webView, alpha, beta, gamma, absolute ? TRUE : FALSE);
}

void WPEDeviceOrientationBridge::handleMotionChanged()
{
    QAccelerometerReading* reading = m_accelerometer ? m_accelerometer->reading() : nullptr;
    if (!reading)
        return;

    double x = NAN, y = NAN, z = NAN;
    if (m_linearAccelerometer) {
        if (QAccelerometerReading* linear = m_linearAccelerometer->reading()) {
            x = linear->x();
            y = linear->y();
            z = linear->z();
        }
    }

    double alphaRate = NAN, betaRate = NAN, gammaRate = NAN;
    if (m_gyroscope) {
        if (QGyroscopeReading* gyro = m_gyroscope->reading()) {
            // Same axis mapping as orientation: W3C alpha is about z, beta
            // about x, gamma about y. Qt reports deg/s, which is what the
            // event wants.
            alphaRate = gyro->z();
            betaRate = gyro->x();
            gammaRate = gyro->y();
        }
    }

    const int rate = m_accelerometer->dataRate();
    wpe_sfos_device_motion_changed(m_webView,
        x, y, z,
        reading->x(), reading->y(), reading->z(),
        alphaRate, betaRate, gammaRate,
        rate > 0 ? 1000.0 / rate : NAN);
}
