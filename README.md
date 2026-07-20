# atlantic-engine

Build, packaging, and compatibility work for **Atlantic Browser** on **Sailfish OS**.

## Status

This repo is now being used to move Atlantic onto a cleaner baseline:

- **Target OS:** Sailfish OS **5.1.0.8**
- **Target engine:** WPE WebKit **2.52.5**
- **Priority:** smaller patch queue, simpler packaging, faster engine updates
- **Sandboxing — bwrap WebProcess sandbox, ON by default (verified on-device):** `ENABLE_BUBBLEWRAP_SANDBOX=ON` + the ported SFOS patch; `ATLANTIC_ENABLE_SANDBOX` defaults to 1. Confirmed working on an Xperia 10 II (SFOS 5.1, kernel 4.14): the WebProcess and the xdg-dbus-proxy run inside `bwrap`. This is *more* renderer isolation than the stock Gecko browser, which has none (it relies solely on Sailjail). Sailjail-style firejail confinement is wired but **default-off / experimental**: on SFOS it must run via the booster (a direct `firejail --profile=` re-exec fails with a `seteuid` error) and SFOS firejail replaces the inner bwrap with `fbwrap`, so it cannot nest — bwrap-only is the chosen posture. Toggle with `ATLANTIC_ENABLE_SANDBOX` / `ATLANTIC_ENABLE_SAILJAIL`
- **Not a priority right now:** growing the old preload stack

The live scripts in this repo now default to the **SFOS 5.1.0.8 / WPE 2.52.5**
line. The older **WPE 2.52.1** line is still available by explicit override. The
Qt5 bridge is **no longer carried forward from the old 2.52.1 source snapshot**:
it lives in this repo as a self-contained source tree (`qt5-plugin/`, adapted
from the upstream qt6 bindings) that is overlaid onto the current WebKit source
at build time — effectively a patch on whatever engine version `versions.env`
pins. Those pins are explicit in `versions.env` so the remaining runtime work
can happen deliberately instead of chasing hard-coded versions scattered through the
scripts.

The repo-side validation baseline is now stronger than it was on the old line:

- the engine, WebKit, Qt5 bridge, and Atlantic UI all build cleanly against a fresh **2.52.4** temp prefix
- the native RPM path can package that validated temp prefix directly without hard-coded soname drift
- `setup-rpmbuild.sh` and the WebKit RPM specs now stage the **2.52.4** engine source plus the in-repo **`qt5-plugin/`** bridge source

## Live workspace

Current checkouts on the build host:

| Path | Role |
| --- | --- |
| `/release/workspace/atlantic-engine` | engine build, packaging, compatibility cleanup |
| `/release/workspace/atlantic-browser` | Atlantic browser UI/application |

## Repo layout

| File | Purpose |
| --- | --- |
| `versions.env` | central version pins for the current scripted baseline and the migration target |
| `build-all.sh` | top-level orchestrator over the split build entrypoints |
| `scripts/bootstrap-host.sh` | host dependencies, sysroot setup, and workspace bootstrap |
| `scripts/build-engine.sh` | engine dependency build (`libwpe`, `libepoxy`, `WPEBackend-fdo`) |
| `scripts/build-webkit.sh` | WPE WebKit build, in-repo Qt5 bridge overlay, and GLIBC patching |
| `scripts/build-ui.sh` | Atlantic UI/browser build against the staged engine |
| `scripts/package-rpms.sh` | packaging entrypoint that delegates to the native RPM staging script |
| `build-rpms-native.sh` | native RPM staging/packaging script |
| `adblock-engine/` | Brave/Rust adblock engine: `libatlantic_adblock.so` + the `builder` that compiles filter lists into `engine.dat` |
| `web-extension/` | WebKit WebProcess extension that runs the Brave engine on every resource request (the sole network ad/tracker blocker) |
| `data/content-blocker/` | build-time download target for EasyList/EasyPrivacy (gitignored, not vendored; fetched by `build-rpms-native.sh`, URLs/pins in `versions.env`) |
| `cmake/` | shared CMake cache presets used by both the script and spec packaging paths |
| `deploy/` | helper-process wrappers, shared runtime env, and deployment-time assets |
| `docs/RENDERING-AUDIT.md` | live rendering-path audit notes and remaining GPU-path checks |
| `native-meson.ini` | native meson config for engine-side dependencies |
| `sfos-toolchain.cmake` | SFOS sysroot toolchain for Qt/UI builds |
| `qt5-plugin/` | self-contained Qt5 WPE bridge source (adapted from upstream qt6), overlaid onto the pinned WebKit version at build time |
| `patches/` | repo-local engine, WebKit, and historical patches grouped by area |
| `shims/compat/` | C shim sources and linker maps for the remaining compatibility package/workarounds |

## Version pins

The important pins now live in `versions.env`.

### Current scripted baseline

| Item | Version |
| --- | --- |
| SFOS sysroot | `5.1.0.8` |
| libwpe | `1.17.0` |
| libepoxy | `1.5.11` |
| WPEBackend-fdo | `1.17.0` |
| WPE WebKit | `2.52.5` |
| Qt5 plugin source | in-repo `qt5-plugin/` (tracks the pinned WebKit; the `2.52.1` label in `versions.env` survives only for RPM snapshot-tarball naming) |

### Migration target

| Item | Version |
| --- | --- |
| SFOS baseline | `5.1.0.8` |
| WPE WebKit | `2.52.5` |

## Current script behavior

`build-all.sh` and `build-rpms-native.sh` now expose a real split between bootstrap,
engine, WebKit, UI, and packaging entrypoints. The current cleanup pass does six
important things:

1. Removes hard-coded version drift by sourcing `versions.env`.
2. Fixes the missing `WPE_SOURCE_DIR` wiring in `build-all.sh`.
3. Stops packaging and depending on `bubblewrap` even though the current WPE build already sets `-DENABLE_BUBBLEWRAP_SANDBOX=OFF`.
4. Drops `libglibc-compat.so`, `libglib-compat.so`, and default GLIBC retagging from the normal **SFOS 5.1.0.8** path while keeping the still-uncertain shims explicit.
5. Makes the build flow easier to rework incrementally for the SFOS 5.1.0.8 / WPE 2.52.4 line without editing one rescue-style script.
6. Makes the Qt5 bridge explicit by building it from the in-repo `qt5-plugin/` source overlaid onto the pinned WebKit version, instead of carrying it forward from an old engine snapshot.

Recent validation tightened the live flow further:

1. `scripts/build-ui.sh` now drives the qmake-generated `apps/` subproject correctly and builds only the Atlantic browser targets instead of tripping over unrelated subapps.
2. `build-rpms-native.sh` now stages shared-library families dynamically, avoids mutating the source prefix in place, and can package from an alternate validated prefix while keeping the runtime `/opt/wpe-sfos` paths explicit.
3. `setup-rpmbuild.sh`, `rpm/wpewebkit2.spec`, and `rpm/wpewebkit2-qt5.spec` now reflect the real **2.52.4 + in-repo `qt5-plugin/`** source layout instead of the stale **2.50.5** assumptions.

That last point is intentional: isolation work is out of the default path for this migration
unless it becomes a release requirement again later.

## Legacy compatibility inventory

This is the current keep/drop inventory for the old SFOS 5.0 compatibility stack.

| Item | Status | Why |
| --- | --- | --- |
| `libglibc-compat.so` | `keep temporarily` | 2.52.4 helper/runtime binaries still require `__libc_single_threaded@GLIBC_2.17` on-device |
| `patch-glibc-versions.py` | `remove` on SFOS 5.1 unless a specific binary still needs it | should not stay in the normal path if the new baseline already matches runtime glibc |
| `libglib-compat.so` | `remove` on SFOS 5.1 if GLib ABI is sufficient | carried for older GLib behavior on the SFOS 5.0 line |
| `libcow_string_compat.so` | `remove` on SFOS 5.1 | the rebuilt 5.1 runtime makes `invoker` fail on `__libc_single_threaded`, so this shim is no longer safe in the default path |
| `libsigill_skip.so` | `re-check` | only keep if the rebuilt 5.1 line still trips unsupported CPU feature probes |
| `libgetauxval_fix*.so` | `removed from default package` | legacy workaround no longer used by the current runtime closure |
| `libexecve_wrap*.so` | `removed from default package` | tied to the older wrapped process-launch path and sailjail-era assumptions |
| broad `LD_PRELOAD` stacks | `remove` | migration goal is a minimal runtime closure, not global preload repair |
| `libegl-stubs.so` | `keep temporarily` | still potentially relevant if Sailfish/hybris EGL remains short on required symbols |
| `patches/engine/libepoxy-rtld-default-fallback.patch` | `keep temporarily` | coupled to `libegl-stubs.so`; re-check once the 5.1 runtime is exercised |
| `patches/historical/BubblewrapLauncher-sfos-sandbox.patch` | `keep (reference)` | the prose source for the now-active `patches/webkit/webkit-bubblewrap-sfos-sandbox.patch`; kept as the rationale record |
| sailjail-disabled packaging/profile workarounds | `keep` | sailjail re-enable is still planned; the bubblewrap process sandbox is now wired in separately |

## Current local patch queue

These are the repo-local patches currently relevant to the live build flow.

| Patch | Status | Notes |
| --- | --- | --- |
| `patches/engine/libepoxy-rtld-default-fallback.patch` | `keep temporarily` | currently applied in the engine build so `libegl-stubs.so` can satisfy missing EGL symbols on Sailfish/hybris |
| `patches/webkit/webkit-quirks-no-video.patch` | `keep` | harmless compatibility patch while the WebKit carry-forward is still being rebased |
| `patches/webkit/webkit-icu-imported-targets.patch` | `keep temporarily` | fixes the 2.52.4 configure path on Ubuntu 24.04 by repairing the `ICU::` imported targets after `find_package(ICU ...)` |
| `patches/webkit/webkit-ramsize-cstddef.patch` | `keep temporarily` | fixes the 2.52.4 WTF compile on Ubuntu 24.04 by adding the missing `<cstddef>` include for `size_t` in `RAMSize.h` |
| `patches/webkit/webkit-wtf-header-includes.patch` | `keep temporarily` | fixes newer WTF header self-sufficiency issues on Ubuntu 24.04 by adding missing `<cstdint>` and `Assertions.h` includes for `EnumTraits.h` and `TypeCasts.h` |
| `patches/webkit/webkit-wtf-platform-stdint.patch` | `keep temporarily` | fixes additional WTF 2.52.4 portability/self-sufficiency issues by importing `Platform.h` anywhere new Android WTF files use `OS(ANDROID)` and `<cstdint>` where `uint8_t` is used in `UTF8Conversion.h` |
| `patches/webkit/webkit-wtf-glib-platform.patch` | `keep temporarily` | fixes the same self-sufficient header problem across the new WTF GLib files by importing `Platform.h` wherever `USE(GLIB)`, `PLATFORM(WPE)`, or `OS(...)` guards are used directly |
| `patches/webkit/webkit-wtf-glib-header-includes.patch` | `keep temporarily` | fixes the next GLib WTF self-sufficiency layer by importing the headers that own `WTF_EXPORT_PRIVATE` and `WTF_MAKE_TZONE_ALLOCATED` in the new GLib headers |
| `patches/webkit/webkit-wtf-linux-header-includes.patch` | `keep temporarily` | fixes the same self-sufficiency issue in the Linux WTF memory/thread headers by importing `Platform.h` and `ExportMacros.h` where `OS(...)` and `WTF_EXPORT_PRIVATE` are used directly |
| `patches/webkit/webkit-wtf-posix-unix-platform.patch` | `keep temporarily` | fixes the same `Platform.h` ownership problem in the WTF POSIX/Unix sources that use `OS(...)`, `PLATFORM(...)`, or `USE(...)` directly |
| `patches/webkit/webkit-memoryfootprint-cstddef.patch` | `keep temporarily` | fixes `MemoryFootprint.h` on Ubuntu 24.04 by adding the missing `<cstddef>` include for `size_t` |
| `patches/webkit/webkit-unistdextras-includes.patch` | `keep temporarily` | fixes `UniStdExtras.h` by importing the headers that own `WTF_EXPORT_PRIVATE` and `OS(...)` before the inline Unix helpers are declared |
| `patches/webkit/webkit-pal-system-header-includes.patch` | `keep temporarily` | fixes the same PAL system header/source self-sufficiency issues by importing `ExportMacros.h`, `<memory>`, and `Platform.h` where the PAL system classes use them directly |
| `patches/webkit/webkit-pal-text-header-includes.patch` | `keep temporarily` | fixes the same PAL text header self-sufficiency issues by importing `<span>` and `Assertions.h` where the PAL text code uses them directly |
| `patches/webkit/webkit-pal-header-owners.patch` | `keep temporarily` | fixes the next PAL owner-header wave by importing `TZoneMalloc.h`, `ExportMacros.h`, `Platform.h`, `<memory>`, and `<span>` where Clock, text registry, kill ring, and crypto digest headers use them directly |
| `patches/webkit/webkit-jsc-glib-export-macros.patch` | `keep temporarily` | fixes the JavaScriptCore GLib private headers by importing `JSExportMacros.h` wherever `JS_EXPORT_PRIVATE` declarations are used directly |
| `patches/webkit/webkit-jsc-assembler-platform.patch` | `keep temporarily` | fixes the JavaScriptCore arch-specific assembler sources by importing `Platform.h` before they use `ENABLE()` and `CPU()` in their top-level compile guards |
| `patches/webkit/webkit-jsc-cpu-b3-includes.patch` | `keep temporarily` | fixes the next JavaScriptCore header-ownership wave by importing `<cstddef>` for `CPU.h` and `Platform.h` for the failing B3 abstract-heap headers |
| `patches/webkit/webkit-jsc-b3-export-macros.patch` | `keep temporarily` | fixes the broader JavaScriptCore B3 header self-sufficiency wave by importing `JSExportMacros.h` anywhere B3 headers use `JS_EXPORT_PRIVATE` directly |
| `patches/webkit/webkit-jsc-b3-platform.patch` | `keep temporarily` | fixes the broader JavaScriptCore B3 and Air owner-header wave by importing `Platform.h` anywhere those headers and sources use `ENABLE(B3_JIT)` directly |
| `patches/webkit/webkit-jsc-b3-cstdint.patch` | `keep temporarily` | fixes the next JavaScriptCore B3 and Air self-sufficiency wave by importing `<cstdint>` anywhere those files use fixed-width integer types directly |
| `patches/webkit/webkit-jsc-bytecode-platform.patch` | `keep temporarily` | fixes the next JavaScriptCore bytecode owner-header wave by importing `Platform.h` anywhere bytecode headers and sources use `ENABLE()`, `USE()`, or related platform macros directly |
| `patches/webkit/webkit-jsc-dfg-platform.patch` | `keep temporarily` | fixes the next JavaScriptCore DFG owner-header wave by importing `Platform.h` anywhere DFG headers and sources use `ENABLE()`, `USE()`, or related platform macros directly |
| `patches/webkit/webkit-jsc-ftl-platform.patch` | `keep temporarily` | fixes the next JavaScriptCore FTL owner-header wave by importing `Platform.h` anywhere FTL headers and sources use `ENABLE()`, `USE()`, or related platform macros directly |
| `patches/webkit/webkit-jsc-heap-cstddef.patch` | `keep temporarily` | fixes the next JavaScriptCore heap self-sufficiency wave by importing `<cstddef>` anywhere heap headers and sources use `size_t` directly |
| `patches/webkit/webkit-jsc-inspector-remote-glib.patch` | `keep temporarily` | fixes the next JavaScriptCore remote inspector GLib owner-header wave by importing `Platform.h` and `JSExportMacros.h` where those files use `ENABLE(REMOTE_INSPECTOR)` and `JS_EXPORT_PRIVATE` directly |
| `patches/webkit/webkit-jsc-jit-platform.patch` | `keep temporarily` | fixes the next JavaScriptCore JIT owner-header wave by importing `Platform.h` anywhere JIT headers and sources use `ENABLE()`, `USE()`, or related platform macros directly |
| `patches/webkit/webkit-jsc-lol-platform.patch` | `keep temporarily` | fixes the next JavaScriptCore LOL JIT owner-header wave by importing `Platform.h` anywhere those files use `ENABLE(JIT)` and `USE(JSVALUE64)` directly |
| `patches/webkit/webkit-jsc-wasm-platform.patch` | `keep temporarily` | fixes the next JavaScriptCore WebAssembly owner-header wave by importing `Platform.h` anywhere Wasm headers and sources use `ENABLE()`, `USE()`, or related platform macros directly |
| `patches/webkit/webkit-jsc-llint-build-defines.patch` | `keep temporarily` | fixes the JavaScriptCore LLInt object-library link on the Ubuntu 24.04 runner by making `LowLevelInterpreterLib` inherit the same compile definitions as `JavaScriptCore` |
| `patches/webkit/webkit-jsc-shell-object-link.patch` | `keep temporarily` | fixes the JavaScriptCore `bin/jsc` object-library link on the Ubuntu 24.04 runner by replacing the broken custom archive step with a CMake static target linked under `--whole-archive` |
| `patches/webkit/webkit-webcore-user-message-handlers-platform.patch` | `keep temporarily` | fixes the WebCore page user-message handler namespace files by importing `Platform.h` before they use `ENABLE(USER_MESSAGE_HANDLERS)` directly |
| `patches/webkit/webkit-webcore-colorconversion-export-macros.patch` | `keep temporarily` | fixes `ColorConversion.h` by importing `PlatformExportMacros.h` before it uses `WEBCORE_EXPORT` in template specializations |
| `patches/webkit/webkit-webcore-webkitnamespace-platform.patch` | `keep temporarily` | fixes `WebKitNamespace.h` by importing `Platform.h` before it uses `ENABLE(USER_MESSAGE_HANDLERS)` directly |
| `patches/webkit/webkit-webcore-avif-platform.patch` | `keep temporarily` | fixes `AVIFImageDecoder.cpp` by importing `Platform.h` after `config.h` before it uses `USE(AVIF)` directly |
| `patches/webkit/webkit-webcore-avif-reader-platform.patch` | `keep temporarily` | fixes `AVIFImageReader.cpp` by importing `Platform.h` after `config.h` before it uses `USE(AVIF)` directly |
| `patches/webkit/webkit-webcore-context-export-macros.patch` | `keep temporarily` | fixes `ContextDestructionObserver.h` by importing `PlatformExportMacros.h` before it uses `WEBCORE_EXPORT` directly |
| `patches/webkit/webkit-webcore-bitmaptexturepool-owners.patch` | `keep temporarily` | fixes `BitmapTexturePool.h` by importing `PlatformExportMacros.h` before it uses `WEBCORE_EXPORT` directly in the texmap pool singleton API |
| `patches/webkit/webkit-webcore-texmap-owner-headers.patch` | `keep temporarily` | fixes the next WebCore texmap ownership wave by importing `Platform.h` / `PlatformExportMacros.h` before texmap headers use `ENABLE()`, `USE()`, and `WEBCORE_EXPORT` directly |
| `patches/webkit/webkit-renderbox-isnan.patch` | `keep temporarily` | fixes the 2.52.4 WebCore compile on Ubuntu 24.04 by making `RenderBox.h` use `std::isnan` with an explicit `<cmath>` include |
| `patches/webkit/webkit-shapeoutside-isnan.patch` | `keep temporarily` | fixes the 2.52.4 WebCore shape-outside compile on Ubuntu 24.04 by making `ShapeOutsideInfo.cpp` use `std::isnan` with an explicit `<cmath>` include |
| `patches/qt-bridge/` | `removed` | all historical qt-bridge patches (texture cache, exported-image lifetime, display/window update, adaptive fps, gnuinstalldirs, epoxy-gl fix, wpeqtview carry-forward) are baked into the in-repo `qt5-plugin/` source; the patch files were deleted — see git history |
| `patches/webkit/webkit-bubblewrap-sfos-sandbox.patch` | `keep` | re-enables the WPE bubblewrap process sandbox on SFOS/Android-4.14: `--dev-bind / /` (no `pivot_root`/`--dev` masking of GPU nodes), shared netns for Web/GPU (hybris abstract sockets), and `flatpakInfoFd = -1` (read-only rootfs). Ported from the historical prose patch |
| `patches/historical/BubblewrapLauncher-sfos-sandbox.patch` | `keep (reference)` | prose source/rationale for the active webkit-bubblewrap-sfos-sandbox.patch above |

## Practical next steps

The next useful repo changes should be:

1. Run device/runtime validation for the rebuilt **SFOS 5.1.0.8 / WPE 2.52.4** packages.
2. Re-check the remaining explicit shims (`libsigill_skip.so`, `libegl-stubs.so`) against real runtime behavior.
3. Make fresh install match the staged tree exactly, with no manual device-side fixes.
4. Decide whether the remaining older RPM specs beyond the WebKit pair should be aligned further or retired in favor of the native packaging path.

## GitHub Actions build automation

This repo now has a first self-hosted ARM64 workflow at
`.github/workflows/build-atlantic-packages.yml`.

- Trigger modes:
  - manual `workflow_dispatch`
  - automatic `push` builds on `master` when build/package inputs change
- Runner labels:
  - `self-hosted`
  - `Linux`
  - `ARM64`
  - `atlantic`
- Main CI wrapper:
  - `scripts/ci-build.sh`

The workflow intentionally builds in isolated CI paths instead of the live
development prefix, while still seeding the CI sysroot from the local updated
host sysroot when the raw 5.1 SDK target archive is not publicly downloadable:

- `CI_ROOT=/opt/github-runner/builds/<run-id>-<attempt>`
- `WPE_PREFIX=${CI_ROOT}/wpe-sfos-prefix`
- `OUT=${CI_ROOT}/wpe-sfos-rpms`
- `STAGING=${CI_ROOT}/wpe-sfos-stage`
- `PUBLIC_SFOS_BASE_VERSION=5.1.0.8`
- `LOCAL_SFOS_SOURCE_SYSROOT=/opt/sfos-sysroot`
- `QT5_PLUGIN_SOURCE_DIR` is unset — CI builds the bridge from the in-repo `qt5-plugin/` default
- `NPROC=6`
- `SYSROOT=/opt/github-runner/cache/sfos-sysroot-5.1.0.5`

The WPE source tree and install prefix now live under a stable cache root
(``/opt/github-runner/cache/atlantic-build``) so ccache sees consistent paths
between runs, and the CI wrapper runs a smoke test that must record a cache hit
before the full build starts.

That keeps CI runs from clobbering the live `/opt/wpe-sfos` tree used for manual
device work on the host.

Artifacts uploaded from each run include:

- `artifacts/build.log`
- `artifacts/summary.txt`
- `artifacts/rpms/*.rpm`
- `artifacts/rpm-repo/aarch64/` with `repodata/` (rpm-md metadata)
- `artifacts/rpm-repo/RPM-GPG-KEY-atlantic-ci` (public signing key)
- `artifacts/rpm-repo/atlantic-ci.repo` (ready-to-use zypper repo file)
- `artifacts/build-config/` when WebKit metadata is available

On successful `master` builds, the workflow also publishes the same rpm-md tree
to GitHub Pages (`gh-pages` branch):

- `https://specsierra.github.io/atlantic-engine/aarch64/`

RPMs and repository metadata are signed in CI. Configure these GitHub repository
secrets for signing:

- `ATLANTIC_RPM_SIGNING_KEY` — ASCII-armored private GPG key used for RPM/repo signing
- `ATLANTIC_RPM_SIGNING_KEY_ID` — key id or uid string used by `rpmsign`/`gpg`
- `ATLANTIC_RPM_SIGNING_PASSPHRASE` — passphrase for the private key (can be empty for passphrase-less CI keys)

Package release/iteration now tracks CI runs (`RPM_ITERATION=<run>.<attempt>`),
so `zypper up` can pick up each new build instead of seeing repeated `-1`
releases.

Phone setup for updates:

```bash
devel-su
rpm --import https://specsierra.github.io/atlantic-engine/RPM-GPG-KEY-atlantic-ci
zypper ar -f https://specsierra.github.io/atlantic-engine/aarch64 atlantic-ci
zypper ref
zypper up atlantic-browser wpewebkit2 wpewebkit2-qt5 wpebackend-fdo libwpe libepoxy wpe-sfos-compat
```

## CLI test automation

Basic automated tests now cover the Python CLI helpers:

- `scripts/write-runtime-env.py`
- `scripts/write-webkit-feature-flags.py`

Run them locally with:

```bash
python -m unittest discover -s tests -p 'test_*.py' -v
```

GitHub Actions also runs the same suite via `.github/workflows/cli-tests.yml`
whenever these CLI scripts or tests change on `master`.

## Build philosophy

Atlantic should be maintained like a browser port:

- engine updates should be routine
- local patches should stay named and small
- runtime layout should be explicit
- the UI should remain thin while the engine moves forward

If a change makes the next engine bump easier, it is probably the right change.

## License

First-party code in this repository is licensed under the **Mozilla Public
License 2.0** (see `LICENSE.txt`) — consistent with the `atlantic-browser`
repository and with the Brave/Rust `adblock` engine this project builds on.

This repository also contains code derived from third-party upstreams that keep
their original licenses (these are **not** relicensed under MPL-2.0):

| Path | License | Origin |
|------|---------|--------|
| `qt5-plugin/` | LGPL-2.1-or-later | WebKit WPE Qt API (Copyright Igalia S.L / Zodiac Inflight Innovations) |
| `patches/webkit/` | per WebKit | patches against WebKit (LGPL-2.1 / BSD-2-Clause) |
| `adblock-engine/` | MPL-2.0 | wraps the MPL-2.0 `adblock` crate (Brave) |

Keep the upstream copyright/license headers in those files intact. Per-file
`SPDX-License-Identifier` headers take precedence over this summary.
