# Atlantic Browser v1.0.0 Beta 1 — Initial Beta Release

Atlantic Browser is a WPE WebKit-based browser for Sailfish OS 5.1, built from two
repositories:

| Repo | Purpose |
|------|---------|
| `atlantic-engine` | Build scripts, WebKit patches, cmake toolchains, RPM packaging, CI pipeline |
| `atlantic-browser` | Sailfish Silica Qt5/QML browser UI with a custom WPE WebKit webview bridge |

---

## Core Engine — `atlantic-engine`

### WPE WebKit Build Infrastructure

- **WebKit 2.52.4** cross-compiled for SFOS 5.1 aarch64 on an Ubuntu 24.04 build host
- Self-contained **Qt5 WPE plugin** (`qt5-plugin/`) adapted from upstream Qt6 source
- Standalone builds of **libwpe 1.17.0**, **WPEBackend-fdo 1.17.0**, and **libepoxy 1.5.11**
  (patched for SFOS EGL compatibility via hybris)
- Cross-compilation toolchain configs (meson cross files, cmake toolchain files) targeting
  SFOS 5.1.0.5 sysroot
- Native aarch64 build support on Ubuntu 24.04 (`build-all.sh`)

### Compatibility & Shims

- **glibc compatibility shims** for SFOS 5.x older glibc — `getrandom`, `arc4random`,
  EGL, and execve wrappers for sailjail/sandbox compatibility
- **EGL stubs** for missing SFOS EGL 1.5 symbols, with `dlsym(RTLD_DEFAULT)`-based
  `eglGetProcAddress` resolution
- **WOFF2** font rendering: bundled `libwoff2dec` and `libbrotli` patched for SFOS glibc
- ARM64 SIGILL skip shims for unsupported CPU instructions on the Snapdragon 630/Adreno 610
- GNUInstallDirs patch for Qt5 plugin multiarch layout

### WebKit Source Patches (31 patches)

WebKit WTF, PAL, JSC, and WebCore headers patched for aarch64/SFOS builds:
- WTF: Android portability headers, glib/linux/POSIX source guards, RAMSize header,
  UniStdExtras
- PAL: system, text, and owner headers
- JSC: glib exports, assembler guards, B3/DFG/FTL/LLInt bytecode and JIT guards,
  GPR info, Wasm guards, heap headers, inspector/disassembler guards, shell linking
- WebCore: header owners, texmap owners, ScrollAnimationKeyboard narrowing fix
- GPU Process: EGL default display fallback for hybris/SFOS, `PlatformDisplay::Type::Default`
  fix
- Media: GstQueue2 ring-buffer buffering watermark patches; Venus hardware video decode
  enabled for H.264/H.265; VP8/VP9 forced to software decode (droidvdec crashes on VP9)
- Qt bridge: viewport scale, demand-driven compositing via `QQuickWindow::update()`,
  exported-image lifetime fixes

### CI Pipeline (GitHub Actions self-hosted runner)

- **Self-hosted build workflow** on `builder-arm64` (aarch64 Ubuntu 24.04)
- Toolchain-hash cache busting for automatic rebuilds when compiler flags change
- **ccache** compiler cache (4.5 GB) with cross-run reuse
- Build-time fetch of EasyList/EasyPrivacy for content blocking
- Source tree isolation and CI-safe paths
- Automated CLI smoke tests for build validation
- **Ninja** build using all available CPU cores

### Performance & Tuning

- **Clang 18 + ThinLTO** (Link-Time Optimization) for JSC and WebCore
- ARM64 `-mtune=cortex-a73` CPU flags for Kryo 260 big.LITTLE clusters
- JSC thread tuning for Linux ARM64 with `-fno-semantic-interposition`
- Incremental GC, reduced heap RAM fraction (0.35), lowered JIT tier-up thresholds
- Omitted frame pointer, gc-sections, I-cache alignment tuning
- Skia GPU painting: 3 threads, 256px tile size
- Adaptive 3-tier FPS throttling on the compositor side
- GPU min-clock udev rule for Adreno 610
- GStreamer: reduced buffering delay, configurable watermarks
- CPU affinity via `taskset` — browser pinned to big cores (4–7)

### RPM Packaging & Repository

- RPM specs for all components: `wpewebkit2`, `wpewebkit2-qt5`, `atlantic-browser`,
  `wpebackend-fdo`, `libwpe`, `libepoxy`, `wpe-sfos-compat`, `bubblewrap`,
  `xdg-dbus-proxy`, `firejail`
- RPM signing via GPG (`rpmsign`)
- **GitHub Pages RPM repository** at `specsierra.github.io/atlantic-engine/aarch64/`
- Launcher scripts, subprocess wrappers, desktop file, app icon packaged in RPMs
- PulseAudio server configuration in runtime environment

### Content Blocking

- **adblock-rust engine** with C FFI bridge — compiled from Rust into a `.so` and
  integrated into the WebKit build pipeline
- EasyList/EasyPrivacy filter lists fetched at build time, compiled to `.dat` format
- Additional Piano/AT Internet tracker domains in a manual block list
- WebKit content blocker bytecode converter for Adblock Plus filter lists
- Versioned cache identifier using source file modification timestamps

### Sandbox & Security

- **Firejail confinement** with native **sailjaild** permission system integration —
  the default sandbox on SFOS 5.1; ensures browser subprocesses are confined to
  a restricted filesystem view
- `bwrap` and `xdg-dbus-proxy` built and packaged for the device
- Bind-mounts for `/odm`, `/vendor/firmware_mnt`, and `/run/display` (Wayland socket)
- **WPE bubblewrap process sandbox** — available but **disabled by default**;
  it blanks pages on hybris/SFOS devices (GPU process requires GBM, absent on hybris)
- GPU process disabled by default on hybris (lacks GBM)

### Viewport & Rendering Fixes

- Qt5 plugin viewport scale patch applied during build
- Demand-driven compositing in the Qt bridge, avoiding constant repaints
- Drop redundant per-frame full-screen texture pass in `WPEQtViewBackend::texture()`
- `libwpe` fullscreen handler registered in `WPEQtViewBackend` to complete the
  set-fullscreen handshake (fix: video fullscreen no longer exits immediately)

---

## Browser UI — `atlantic-browser`

### Architecture

- **WPE WebKit engine layer**: `WPEWebPage`, `WPEWebContainer`, `WPEWebPageCreator` —
  a custom Qt5 C++ bridge between the Sailfish Silica QML UI and WPE WebKit's C API
- Replaced all Gecko/EmbedLite scaffolding (QtMozEmbed) with WPE equivalents
- Shared `SHARED_SECONDARY_PROCESS` model — multiple tabs share one WebProcess
- WebProcess crash isolation: a single tab crash no longer kills the browser;
  auto-reload on crash via one-shot detection
- `BrowserService` D-Bus integration: `openUrl`, `ui` service, registered on session bus
- Sailfish Transfer Engine integration for downloads

### User Interface

- **Sailfish Silica** native look-and-feel with ambience theme following
- **Frosted-glass chrome**: blurred ambience wallpaper behind browser chrome using
  `FastBlur` and `FrostedBox` (FBO-immune)
- **SFOS-style 2-column tab switcher** with tab thumbnails (captured via
  `webkit_web_view_get_snapshot`), domain strip, and active tab borders
- **Full-height sidebar popup menu** with glass background
- **Toolbar**: URL bar, padlock security indicator, stop/refresh toggle button,
  home/back/close-tab navigation, loading progress shimmer bar with spinning stop button
- **Brave-style start page** with branded launch splash
- Ambience-tinted chrome across all surfaces — never black, properly composited
- Popup menu hides the address bar when open; footer glass wired to backdrop

### Touch & Gesture Input

- Pinch-to-zoom via CSS `transform: scale()` injected into page JS (not QML scale
  transforms — avoids compositor conflicts)
- Long-press text selection via JS bridge with cursor visibility improvements,
  zoom-aware coordinate scaling, and native Silica teardrop selection handles
- Scroll-to-show/hide toolbar bridge
- Touch event handling: passive touch listeners injected at document level for
  smooth kinetic scrolling; Qt hover/pointer events suppressed during touch to
  prevent scroll stalls; compositor-synthesised mouse events blocked
- Image long-press download menu via `DockedPanel`
- `touch-action: manipulation` removed — was breaking WPE's native scroll recognizer

### Keyboard & IME

- Qt input-method support enabled on WPE pages
- IME commit text forwarded to WebKit keys; preedit updates applied immediately
- Backspace and repaint handling during IME composition
- Soft-keyboard keycode mapping bypassed; UTF-8 locale forced for keyboard input
- Per-key soft keyboard text updates

### Media & Volume

- HTML5 media state wired into browser runtime (play/pause/seek)
- Video fullscreen lifecycle handling
- Volume control: system `MainVolume2` polled via GDBus peer connection to PulseAudio,
  mapped to `el.volume` in page JS (read-only — does not write back, avoids slider pinning)
- Media paused on device suspend
- Autoplay GStreamer init blocked; media bridge MutationObserver performance optimized

### Security & Privacy

- **Process isolation**: one WebProcess per tab + process swap on cross-site navigation
  (PSON, pinned explicitly; `ATLANTIC_DISABLE_PSON=1` to A/B). OOPIF site isolation
  (`ATLANTIC_ENABLE_SITE_ISOLATION`) stays opt-in/off: WPE 2.52.x cannot composite
  cross-process iframes (blank frames + isolated-process crash, device-proven 2026-07-22)
- **Content blocker**: versioned cache, EasyList/EasyPrivacy conversion, manual block list
- **AdBlock**: new C++ `AdBlockEngine` adapter integrated with `WPEWebPage` at the
  resource-load level; adblock-rust `.so` linked with explicit `WPE_PREFIX/lib` path
- Mobile user-agent string set before first load (no Android/Pixel strings)
- Persistent cookies enabled by default
- DOM rendering kept in the WebProcess (not GPU process) for hybris compatibility

### File Handling & Downloads

- Native file selector via `ContentPickerPage`
- Harden file chooser path resolution with cancel-race handling
- File picker cancel fallback with retry-before-cancel logic
- Downloads integrated with Sailfish Transfer Engine; runtime transfer controls
  wired to `BrowserService`

### Build & Packaging (Browser)

- QMake-based build replacing hardcoded `/workspace/` paths with qmake variables
- RPM spec rewritten for WPE WebKit engine (split from settings package)
- Side-by-side install with Sailfish browser — distinct launcher icon (Atlantic
  compass-rose SVG design) and separate package name
- Browser launcher icon standardized in packaging; stale launcher actions removed
- Compatibility headers for building on Ubuntu 24.04 targeting SFOS 5.0 sysroot
- Qt 5.6.3 compatibility fixes (`toMSecsSinceEpoch()` fallback, `QScopedPointer::take()`)

### Scroll & Rendering

- `SHARED_SECONDARY_PROCESS` model to reduce multi-process CPU contention
- Demand-driven compositing: dropped continuous 60fps frame pump to a 2-second watchdog;
  `WPEQtView::triggerUpdate()` drives repaints on demand
- `WEBKIT_SKIA_GPU_PAINTING_THREADS` auto-selected from EGL surfaceless capability
- Smooth scrolling disabled for touch (fixes rubber-band feel)
- Passive touch/wheel listeners injected at document level for kinetic scroll
- `backdrop-filter` CSS disabled in injected stylesheet for performance
- BGRA OpenGL rendering path enabled
- Memory pressure limits for `NetworkProcess`; background tab timeout halved
- Window repaint ticks forced for WPE; alpha compositing restored

### Compatibility & Quirks

- SFOS 5.1.0.5 SDK target with Qt 5.6.3 and Silica
- Silica `IconButton.text` property replaced with `IconButton + Label` column
  (text property unsupported in older Silica)
- `toSecsSinceEpoch()` fallback for Qt 5.6.3
- `QQuickCloseEvent` incomplete type fixes
- `manhattanLength()` narrowing warnings suppressed under Clang 18

### Cleanup

- All Gecko/EmbedLite dead code removed (`qtmozembed`, `qmoz` scaffolding)
- Unused tests, tools, backup-unit, and build artifacts removed
- Login and search engine models (Gecko-specific) removed
- `connman-qt5` and `nemo-qml-plugin-systemsettings` dependencies dropped
- Captive portal code trimmed to WPE essentials

---

## Summary

| Area | Status |
|------|--------|
| WPE WebKit version | **2.52.4** |
| SFOS target | **5.1.0.5** (Pispala) |
| Build host | aarch64 Ubuntu 24.04 |
| CI | GitHub Actions self-hosted runner |
| RPM publishing | GitHub Pages repository |
| Sandbox | Firejail + sailjaild (default), Bubblewrap (disabled — blanks on hybris) |
| Content blocking | adblock-rust engine + EasyList/EasyPrivacy |
| UI framework | Qt 5.6.3 + Sailfish Silica QML |
| License | MPL 2.0 |
