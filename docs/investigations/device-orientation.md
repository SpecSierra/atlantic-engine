# DeviceOrientation / DeviceMotion on WPE

Status: **in progress** — engine foundation landing, sensor data path next.

`window.DeviceOrientationEvent` and `window.DeviceMotionEvent` do not exist in our
build. Sites that feature-detect them (map compasses, 360° photo viewers, casual
games, parallax effects) take their no-sensor path. It is also 5 points on
html5test (Device Orientation 3 + Device Motion 2).

## What is already in the tree, and what is missing

`ENABLE_DEVICE_ORIENTATION` is defined `PRIVATE OFF` in
`Source/cmake/WebKitFeatures.cmake:160` and no port turns it on — WPE included.
Everything behind it in WebCore is present and generic:
`DeviceOrientationController`, `DeviceMotionController`, the `*Client` interfaces,
`DeviceOrientationData` / `DeviceMotionData`, both events, and
`DeviceOrientationAndMotionAccessController`.

What is **not** in the tarball is anything platform-side. Apple strips
`PLATFORM(IOS_FAMILY)`-only sources from WPE releases, so
`DeviceOrientationClientIOS`, `DeviceMotionClientIOS`, `MotionManagerClient.h` and
`WebCore/DeviceOrientationUpdateProvider.h` are all absent.

**Dead end — do not restart here.** `WebKit/WebProcess/WebCoreSupport/WebDeviceOrientationUpdateProvider.{h,cpp,messages.in}`
looks like exactly the right seam: a generic IPC receiver with
`DeviceOrientationChanged(alpha, beta, gamma, …)` / `DeviceMotionChanged(…)`
messages and no Cocoa code of its own. It cannot be reused as-is — every header
it includes (`MotionManagerClient.h`, `DeviceOrientationUpdateProvider.h`) is one
of the stripped files. Reviving it means writing those anyway, so write the
client directly instead.

## The path that does work

On non-iOS, `LocalDOMWindow::deviceOrientationController()`
(`Source/WebCore/page/LocalDOMWindow.cpp:2130`) resolves the controller as a
**`Supplement<Page>`** — `DeviceOrientationController::from(page)`. Nothing in the
tree ever *provides* that supplement, which is the whole reason the feature is
inert on WPE; `from()` returns null forever.

So the shape is the same as geolocation, which this repo already bridges:

    WebPage.cpp:1024   WebCore::provideGeolocationTo(page, WebGeolocationClient::create(*this));

We add the mirror of that line for device orientation and motion, with clients
that hold the last sample and are fed over IPC from the UI process, where the
sensors live. Sensor access stays out of the bwrap-sandboxed WebProcess, exactly
as it does for position.

Client interface is tiny (`dom/DeviceOrientationClient.h`, `dom/DeviceClient.h`):
`startUpdating()`, `stopUpdating()`, `setController()`, `lastOrientation()`,
`deviceOrientationControllerDestroyed()`. Feeding a sample is one call:
`DeviceOrientationController::didChangeDeviceOrientation(DeviceOrientationData*)`.
Build data with the **four-argument** `DeviceOrientationData::create(alpha, beta,
gamma, absolute)` — the five-argument `compassHeading`/`compassAccuracy` overload
is the iOS one.

`startUpdating()` / `stopUpdating()` are what keep the sensors off when no page is
listening, so they need a WebProcess→UIProcess message; the samples need the
reverse direction. Both are new.

## Enabling the flag alone is not the deliverable

html5test scores these two items on API presence only:

    engine.js:1501   passed: !!window.DeviceOrientationEvent
    engine.js:1511   passed: !!window.DeviceMotionEvent

So `ENABLE_DEVICE_ORIENTATION=ON` by itself banks all 5 points while no event ever
fires. That is precisely the failure mode that rules out Web Payments
(see the html5test ledger): a site feature-detects success and then silently gets
nothing, which is worse for the user than an honest absence. The flag is the
foundation for the data path, not a result on its own — do not ship it alone.

It is at least *safe* on its own: every caller of `deviceOrientationController()` /
`deviceMotionController()` null-checks (`LocalDOMWindow.cpp:2218-2273`), so a
missing supplement degrades to "no events", never a crash.

## Sensor source

Verified on the device (Xperia 10 II, SFOS 5.2.0.15): `sensorfwd.service` active,
`libsensorclient-qt5.so.1` and `libQt5Sensors.so.5.6.3` present, QML QtSensors
plugin installed. Build side, `/opt/sfos-sysroot` (the `SYSROOT` in
`scripts/common.sh:13`) carries `QtSensors` headers and `Qt5Sensors.pc`, so the
qt5 plugin can link it without a sysroot change.

The bridge belongs in `qt5-plugin/` next to `WPEGeolocationBridge`, converting
QtSensors readings to the W3C alpha/beta/gamma convention and only running while
WebKit has asked for updates.

## Order of work

1. `ENABLE_DEVICE_ORIENTATION ON` + the `DeviceOrientationEvent` runtime pref.
2. WebProcess clients + `provideDeviceOrientationTo` / `provideDeviceMotionTo`,
   supplements installed from `WebPage.cpp`.
3. IPC both ways + `wpe_sfos_*` exported entry points (the convention used by
   `webkit-wpe-page-scale-api.patch`).
4. `WPEDeviceOrientationBridge` in the qt5 plugin, driven by QtSensors.

Steps 1-3 are one patch, `patches/webkit/webkit-wpe-device-orientation.patch`.
