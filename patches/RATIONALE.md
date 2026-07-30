# Why each patch exists

Hand-maintained rationale, recovered from the old README. `SERIES.md` is generated
and says *what* each patch touches; this says *why* it is there and what would let
it go away. Add a line here when you add a patch whose reason is not obvious from
its name.

Most of the entries below are portability fixes for building 2.52.x with the CI
host's toolchain against the SFOS sysroot: a header that is not self-sufficient, a
missing `<cstdint>`/`<cstddef>`, or a file using `ENABLE()`/`USE()`/`WTF_EXPORT_PRIVATE`
without including the header that owns it. They are behaviour-neutral, and the plan
is to replace the whole class of them with a forced-include prelude — see
[../docs/STREAMLINE-PLAN.md](../docs/STREAMLINE-PLAN.md) A1.

| Patch | Disposition | Why |
|---|---|---|
| `libepoxy-rtld-default-fallback.patch` | `keep temporarily` | coupled to `libegl-stubs.so`; re-check once the 5.1 runtime is exercised |
| `libepoxy-rtld-default-fallback.patch` | `keep temporarily` | currently applied in the engine build so `libegl-stubs.so` can satisfy missing EGL symbols on Sailfish/hybris |
| `webkit-quirks-no-video.patch` | `keep` | harmless compatibility patch while the WebKit carry-forward is still being rebased |
| `webkit-icu-imported-targets.patch` | `keep temporarily` | fixes the 2.52.4 configure path on Ubuntu 24.04 by repairing the `ICU::` imported targets after `find_package(ICU ...)` |
| `webkit-ramsize-cstddef.patch` | `keep temporarily` | fixes the 2.52.4 WTF compile on Ubuntu 24.04 by adding the missing `<cstddef>` include for `size_t` in `RAMSize.h` |
| `webkit-wtf-header-includes.patch` | `keep temporarily` | fixes newer WTF header self-sufficiency issues on Ubuntu 24.04 by adding missing `<cstdint>` and `Assertions.h` includes for `EnumTraits.h` and `TypeCasts.h` |
| `webkit-wtf-platform-stdint.patch` | `keep temporarily` | fixes additional WTF 2.52.4 portability/self-sufficiency issues by importing `Platform.h` anywhere new Android WTF files use `OS(ANDROID)` and `<cstdint>` where `uint8_t` is used in `UTF8Conversion.h` |
| `webkit-wtf-glib-platform.patch` | `keep temporarily` | fixes the same self-sufficient header problem across the new WTF GLib files by importing `Platform.h` wherever `USE(GLIB)`, `PLATFORM(WPE)`, or `OS(...)` guards are used directly |
| `webkit-wtf-glib-header-includes.patch` | `keep temporarily` | fixes the next GLib WTF self-sufficiency layer by importing the headers that own `WTF_EXPORT_PRIVATE` and `WTF_MAKE_TZONE_ALLOCATED` in the new GLib headers |
| `webkit-wtf-linux-header-includes.patch` | `keep temporarily` | fixes the same self-sufficiency issue in the Linux WTF memory/thread headers by importing `Platform.h` and `ExportMacros.h` where `OS(...)` and `WTF_EXPORT_PRIVATE` are used directly |
| `webkit-wtf-posix-unix-platform.patch` | `keep temporarily` | fixes the same `Platform.h` ownership problem in the WTF POSIX/Unix sources that use `OS(...)`, `PLATFORM(...)`, or `USE(...)` directly |
| `webkit-memoryfootprint-cstddef.patch` | `keep temporarily` | fixes `MemoryFootprint.h` on Ubuntu 24.04 by adding the missing `<cstddef>` include for `size_t` |
| `webkit-unistdextras-includes.patch` | `keep temporarily` | fixes `UniStdExtras.h` by importing the headers that own `WTF_EXPORT_PRIVATE` and `OS(...)` before the inline Unix helpers are declared |
| `webkit-pal-system-header-includes.patch` | `keep temporarily` | fixes the same PAL system header/source self-sufficiency issues by importing `ExportMacros.h`, `<memory>`, and `Platform.h` where the PAL system classes use them directly |
| `webkit-pal-text-header-includes.patch` | `keep temporarily` | fixes the same PAL text header self-sufficiency issues by importing `<span>` and `Assertions.h` where the PAL text code uses them directly |
| `webkit-pal-header-owners.patch` | `keep temporarily` | fixes the next PAL owner-header wave by importing `TZoneMalloc.h`, `ExportMacros.h`, `Platform.h`, `<memory>`, and `<span>` where Clock, text registry, kill ring, and crypto digest headers use them directly |
| `webkit-jsc-glib-export-macros.patch` | `keep temporarily` | fixes the JavaScriptCore GLib private headers by importing `JSExportMacros.h` wherever `JS_EXPORT_PRIVATE` declarations are used directly |
| `webkit-jsc-assembler-platform.patch` | `keep temporarily` | fixes the JavaScriptCore arch-specific assembler sources by importing `Platform.h` before they use `ENABLE()` and `CPU()` in their top-level compile guards |
| `webkit-jsc-cpu-b3-includes.patch` | `keep temporarily` | fixes the next JavaScriptCore header-ownership wave by importing `<cstddef>` for `CPU.h` and `Platform.h` for the failing B3 abstract-heap headers |
| `webkit-jsc-b3-export-macros.patch` | `keep temporarily` | fixes the broader JavaScriptCore B3 header self-sufficiency wave by importing `JSExportMacros.h` anywhere B3 headers use `JS_EXPORT_PRIVATE` directly |
| `webkit-jsc-b3-platform.patch` | `keep temporarily` | fixes the broader JavaScriptCore B3 and Air owner-header wave by importing `Platform.h` anywhere those headers and sources use `ENABLE(B3_JIT)` directly |
| `webkit-jsc-b3-cstdint.patch` | `keep temporarily` | fixes the next JavaScriptCore B3 and Air self-sufficiency wave by importing `<cstdint>` anywhere those files use fixed-width integer types directly |
| `webkit-jsc-bytecode-platform.patch` | `keep temporarily` | fixes the next JavaScriptCore bytecode owner-header wave by importing `Platform.h` anywhere bytecode headers and sources use `ENABLE()`, `USE()`, or related platform macros directly |
| `webkit-jsc-dfg-platform.patch` | `keep temporarily` | fixes the next JavaScriptCore DFG owner-header wave by importing `Platform.h` anywhere DFG headers and sources use `ENABLE()`, `USE()`, or related platform macros directly |
| `webkit-jsc-ftl-platform.patch` | `keep temporarily` | fixes the next JavaScriptCore FTL owner-header wave by importing `Platform.h` anywhere FTL headers and sources use `ENABLE()`, `USE()`, or related platform macros directly |
| `webkit-jsc-heap-cstddef.patch` | `keep temporarily` | fixes the next JavaScriptCore heap self-sufficiency wave by importing `<cstddef>` anywhere heap headers and sources use `size_t` directly |
| `webkit-jsc-inspector-remote-glib.patch` | `keep temporarily` | fixes the next JavaScriptCore remote inspector GLib owner-header wave by importing `Platform.h` and `JSExportMacros.h` where those files use `ENABLE(REMOTE_INSPECTOR)` and `JS_EXPORT_PRIVATE` directly |
| `webkit-jsc-jit-platform.patch` | `keep temporarily` | fixes the next JavaScriptCore JIT owner-header wave by importing `Platform.h` anywhere JIT headers and sources use `ENABLE()`, `USE()`, or related platform macros directly |
| `webkit-jsc-lol-platform.patch` | `keep temporarily` | fixes the next JavaScriptCore LOL JIT owner-header wave by importing `Platform.h` anywhere those files use `ENABLE(JIT)` and `USE(JSVALUE64)` directly |
| `webkit-jsc-wasm-platform.patch` | `keep temporarily` | fixes the next JavaScriptCore WebAssembly owner-header wave by importing `Platform.h` anywhere Wasm headers and sources use `ENABLE()`, `USE()`, or related platform macros directly |
| `webkit-jsc-llint-build-defines.patch` | `keep temporarily` | fixes the JavaScriptCore LLInt object-library link on the Ubuntu 24.04 runner by making `LowLevelInterpreterLib` inherit the same compile definitions as `JavaScriptCore` |
| `webkit-jsc-shell-object-link.patch` | `keep temporarily` | fixes the JavaScriptCore `bin/jsc` object-library link on the Ubuntu 24.04 runner by replacing the broken custom archive step with a CMake static target linked under `--whole-archive` |
| `webkit-webcore-user-message-handlers-platform.patch` | `keep temporarily` | fixes the WebCore page user-message handler namespace files by importing `Platform.h` before they use `ENABLE(USER_MESSAGE_HANDLERS)` directly |
| `webkit-webcore-colorconversion-export-macros.patch` | `keep temporarily` | fixes `ColorConversion.h` by importing `PlatformExportMacros.h` before it uses `WEBCORE_EXPORT` in template specializations |
| `webkit-webcore-webkitnamespace-platform.patch` | `keep temporarily` | fixes `WebKitNamespace.h` by importing `Platform.h` before it uses `ENABLE(USER_MESSAGE_HANDLERS)` directly |
| `webkit-webcore-avif-platform.patch` | `keep temporarily` | fixes `AVIFImageDecoder.cpp` by importing `Platform.h` after `config.h` before it uses `USE(AVIF)` directly |
| `webkit-webcore-avif-reader-platform.patch` | `keep temporarily` | fixes `AVIFImageReader.cpp` by importing `Platform.h` after `config.h` before it uses `USE(AVIF)` directly |
| `webkit-webcore-context-export-macros.patch` | `keep temporarily` | fixes `ContextDestructionObserver.h` by importing `PlatformExportMacros.h` before it uses `WEBCORE_EXPORT` directly |
| `webkit-webcore-bitmaptexturepool-owners.patch` | `keep temporarily` | fixes `BitmapTexturePool.h` by importing `PlatformExportMacros.h` before it uses `WEBCORE_EXPORT` directly in the texmap pool singleton API |
| `webkit-webcore-texmap-owner-headers.patch` | `keep temporarily` | fixes the next WebCore texmap ownership wave by importing `Platform.h` / `PlatformExportMacros.h` before texmap headers use `ENABLE()`, `USE()`, and `WEBCORE_EXPORT` directly |
| `webkit-renderbox-isnan.patch` | `keep temporarily` | fixes the 2.52.4 WebCore compile on Ubuntu 24.04 by making `RenderBox.h` use `std::isnan` with an explicit `<cmath>` include |
| `webkit-shapeoutside-isnan.patch` | `keep temporarily` | fixes the 2.52.4 WebCore shape-outside compile on Ubuntu 24.04 by making `ShapeOutsideInfo.cpp` use `std::isnan` with an explicit `<cmath>` include |
| `webkit-bubblewrap-sfos-sandbox.patch` | `keep` | re-enables the WPE bubblewrap process sandbox on SFOS/Android-4.14: `--dev-bind / /` (no `pivot_root`/`--dev` masking of GPU nodes), shared netns for Web/GPU (hybris abstract sockets), and `flatpakInfoFd = -1` (read-only rootfs). Ported from the historical prose patch |

## Retired

| Was | What happened |
|---|---|
| `patches/qt-bridge/*` | texture cache, exported-image lifetime, display/window update, adaptive fps, gnuinstalldirs, epoxy-gl fix, wpeqtview carry-forward — all baked into the in-repo `qt5-plugin/` source; the patch files were deleted (see git history) |
| `patches/historical/BubblewrapLauncher-sfos-sandbox.patch` | was the prose source for `webkit-bubblewrap-sfos-sandbox.patch`; directory no longer exists. Rationale now lives in [../docs/COMPAT.md](../docs/COMPAT.md) and [../docs/investigations/sandbox-bubblewrap.md](../docs/investigations/sandbox-bubblewrap.md) |
