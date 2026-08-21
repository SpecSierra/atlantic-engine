# DeviceOrientation / DeviceMotion on WPE

Status: **working on device**; mapping measured, normalisation fixed on 665.

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

## Shape of the implementation

    QtSensors (sensorfw)          WPEDeviceOrientationBridge      qt5-plugin, UI process
      |                                    |
      | readingChanged                     | wpe_sfos_device_orientation_changed()
      v                                    v
    WebPageProxy ---- DeviceOrientationChanged ----> WebPage        IPC
      ^                                                |
      |                                                v
      +---- SetDeviceSensorsNeeded ---- WebDeviceOrientationClient
                                                       |
                                        DeviceOrientationController (Page supplement)

`SetDeviceSensorsNeeded` is the half that matters for battery: `startUpdating()` /
`stopUpdating()` are called by `DeviceController` as listeners come and go, and
the state is forwarded up only when it changes, so a page that never touches the
API never spins a sensor.

Unavailable axes travel as NaN across the C boundary and become `std::nullopt`,
so the events report `null`. A page reading `accelerationIncludingGravity.z == 0`
as "lying flat" would otherwise be lied to by a device that cannot measure it.

## Two gates a caller has to satisfy

Neither is ours, both are easy to lose an afternoon to:

- `LocalDOMWindow::isAllowedToUseDeviceMotionOrOrientation()` requires a **secure
  context** — sensors are https-only, silently dead on http.
- It also requires the `DeviceOrientationEvent` preference, which already
  defaults true for the WebKit port, so no embedder change is needed.

Permission is not a third gate: `hasPermissionToReceiveDeviceMotionOrOrientationEvents()`
only consults the access controller when `deviceOrientationPermissionAPIEnabled`
is set, which is the iOS-style `requestPermission()` API and off here.

## Order of work

1. `ENABLE_DEVICE_ORIENTATION ON`. **Done.**
2. WebProcess clients + `provideDeviceOrientationTo` / `provideDeviceMotionTo`,
   supplements installed from `WebPage.cpp`. **Done.**
3. IPC both ways + the `wpe_sfos_*` exported entry points. **Done.**
4. `WPEDeviceOrientationBridge` in the qt5 plugin, driven by QtSensors. **Done.**
5. Verify on device — nothing below has been run yet.

Steps 1-3 are `patches/webkit/webkit-wpe-device-orientation.patch`.

## Verified on device (build 664, Xperia 10 II, SFOS 5.2.0.15)

The whole chain delivers: `DeviceOrientationEvent`/`DeviceMotionEvent` exist,
events fire, `absolute` is true (sensorfw does supply a compass component),
`interval` is 16.67 ms as requested, and `accelerationIncludingGravity`
magnitude is 9.91 m/s². `event.acceleration` is null because this backend has no
`QAccelerometer::User` mode — logged once at startup, degraded rather than faked.

**The axis conventions did not match Qt's documentation and had to be measured**
against the gravity vector, which is unambiguous when the device is held still.
Three held-still orientations:

| reported y | y − 180 | gravity-derived gamma |
|---|---|---|
| 174 | −6 | −6 |
| 110 | −70 | −70 |
| 155 | −25 | −25 |

So `gamma = y − 180` and `beta = −x` (reported −9 where gravity said +9). A
fourth defect only the tilt test exposed: sensorfw's `z` goes **negative**
(−161 measured), while the spec requires alpha in [0, 360).

Gravity-derived beta is ill-conditioned when |gamma| approaches 90 — both `ay`
and `az` go to zero — so disagreement there is the reference being unreliable,
not the reading. Do not "correct" against it in that regime.

## Still not verified

- **|gamma| past 90** (rolled beyond on-edge). The beta-flip itself still has
  not been observed firing on real data — but the wrapping around it has now
  been fixed after it misfired (see below), so the remaining risk is smaller.
- **alpha's absolute accuracy.** It is in range and stable, but nothing has
  checked it against a known bearing, so "is north actually north" is open.
- The 60 Hz / 30 Hz sensor rates are the spec's suggestion; their battery cost
  has not been measured.

## The normalisation trap (found on build 665)

The measured mapping (`beta = -x`, `gamma = y - 180`) was right, but the code
around it applied the W3C beta-flip rule *before* folding gamma into range. That
rule is only meaningful once gamma is already inside [-180, 180).

sensorfw's `y` goes **negative** — `y = -179` was observed with the phone flat —
so `y - 180` reaches -359 (and in principle -540). The flip branch fired on that
and produced `gamma = 179` for a flat phone: worse than doing nothing, and still
outside the legal range.

Fix: wrap both angles with a `wrapTo180()` helper first, then apply the flip.
Verified against every data point captured so far:

| raw x, y | converted (beta, gamma) | gravity truth |
|---|---|---|
| 1, -179 | -1.0, 1.0 | -0.7, 1.0 |
| -9, 174 | 9.0, -6.0 | 9, -6 |
| 4, 110 | -4.0, -70.0 | -10 (noisy), -70 |
| 0, 155 | 0.0, -25.0 | 0, -25 |

alpha keeps its own [0, 360) wrap — folding it with `wrapTo180()+180` shifts the
bearing by half a turn instead, which is a tempting one-liner and completely
wrong.
