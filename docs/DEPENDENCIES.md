# Third-party components

Everything we pull from someone else, and where the version is pinned. Use this
to sweep for updates; each row's **Pinned in** is the single file to edit.

Most pins live in `versions.env`. The exceptions are called out explicitly.

---

## 1. Engine stack (source builds)

| Component | Version | Pinned in | Upstream |
|---|---|---|---|
| WPE WebKit | 2.52.5 | `versions.env` (`LEGACY_WPEWEBKIT_VERSION`, `TARGET_WPEWEBKIT_VERSION`) + `rpm/wpewebkit2.spec` `Version:` | <https://wpewebkit.org/releases/> |
| libwpe | 1.17.0 | `versions.env` + `rpm/libwpe.spec` | <https://github.com/WebPlatformForEmbedded/libwpe> |
| WPEBackend-fdo | 1.17.0 | `versions.env` + `rpm/wpebackend-fdo.spec` | <https://github.com/Igalia/WPEBackend-fdo> |
| libepoxy | 1.5.11 | `versions.env` + `rpm/libepoxy.spec` | <https://github.com/anholt/libepoxy> |
| libavif (decode-only, dav1d backend) | v1.4.2 | `versions.env` (`LIBAVIF_VERSION`) | <https://github.com/AOMediaCodec/libavif> |
| bubblewrap | 0.11.2 | `versions.env` (`BUBBLEWRAP_VERSION`) | <https://github.com/containers/bubblewrap/releases> |
| Qt5 WPE plugin source snapshot | 2.52.1 | `versions.env` (`LEGACY_QT5_PLUGIN_SOURCE_VERSION`) **and** `%global qt5_snapshot_version` at the top of `rpm/wpewebkit2-qt5.spec` | vendored in `qt5-plugin/` |

**Version bump gotcha:** a WebKit bump is not a one-line edit — follow
`docs/investigations/` → *WPE version bump procedure* (patch stack must be
validated **sequentially**; soname needs a triple check).

## 2. Platform / SDK

| Component | Version | Pinned in |
|---|---|---|
| SFOS SDK target sysroot | 5.1.0.11 | `versions.env` (`SFOS_SYSROOT_VERSION`, `TARGET_SFOS_VERSION`) — fetched from <https://releases.sailfishos.org/sdk/targets/> |
| GitHub Actions runner | 2.334.0 | build host only, `/opt/github-runner/` |

## 3. Rust adblock engine

`adblock-engine/` — our FFI wrapper (`atlantic-adblock`, MPL-2.0) around Brave's engine.

| Crate | Version | Pinned in |
|---|---|---|
| `adblock` (Brave) | **0.13.2** | `adblock-engine/Cargo.toml` (`"0.13"`) → resolved in `Cargo.lock` | 
| `serde_json` | 1.x | `adblock-engine/Cargo.toml` |

Upstream: <https://github.com/brave/adblock-rust> · <https://crates.io/crates/adblock>

**Traps on a bump** (both recorded in the investigations):
- The FFI is declared in **both** repos. An arity mismatch is silent at link time
  and shows up as a UI-process Wayland death that looks like a graphics bug. The
  symbol is now suffixed `_v2` so stale callers fail to *link* instead.
- The serialized DAT is keyed by **format version** (0.13 = `adblock/v5`), with
  3 sync points including the browser's `kDefaultBaseUrl`. Bumping the crate
  usually means regenerating the DAT and touching all 3.

## 4. Filter lists (fetched at build time, not vendored)

All URLs in `versions.env`; fetched by `scripts/build-adblock-lists.sh` into
`data/content-blocker/` (gitignored). Each has an optional `*_SHA256` pin —
**all currently empty**, i.e. we track the latest snapshot. Set the hashes plus
`CONTENT_BLOCKER_STRICT=1` for reproducible/locked builds.

| List | Source |
|---|---|
| EasyList | easylist.to |
| EasyPrivacy | easylist.to |
| uBO Filters (Ads) | uBlockOrigin/uAssets `filters/filters.txt` |
| uBO Annoyances | uAssets `filters/annoyances.txt` |
| uBO Annoyances — Cookies | uAssets `filters/annoyances-cookies.txt` |
| Fanboy's Annoyance | secure.fanboy.co.nz |
| Fanboy's Social | secure.fanboy.co.nz |
| Fanboy's Cookiemonster | secure.fanboy.co.nz |
| ABP Anti-Circumvention (core) | gitlab.com/eyeo/anti-cv |
| ABP Anti-CV regional (24 languages) | same repo, `REGIONAL_ANTI_CV_LISTS` |
| **atlantic-extra.txt** | *ours*, vendored at `data/content-blocker/atlantic-extra.txt` — domains EasyList misses (e.g. jeuxvideo GetJad) |

Last vendored EasyList snapshot, for reference: `202605281837` (2026-05-28),
hashes recorded in `versions.env` comments.

## 5. Adblock runtime resources

| Component | Pin | Note |
|---|---|---|
| Brave `adblock-resources` | `master` (unpinned) | redirect surrogates only |
| uBO `scriptlets.js` | **commit `56b82011` (2023-03-24)** | ⚠️ deliberately frozen — the last *old-format* (pre-ES-module) revision, the only one adblock-rust's resource assembler can parse. **Do not bump** without a resource-assembler change. |

Merged into `adblock-resources.json` by the builder's `--resources` mode.

## 6. DuckDuckGo autoconsent

| Component | Version | Pinned in |
|---|---|---|
| `@duckduckgo/autoconsent` | **16.23.0** (sha256-pinned) | `versions.env` — `AUTOCONSENT_VERSION`, `AUTOCONSENT_URL`, `AUTOCONSENT_SHA256` |

MPL-2.0. npm tarball; the build extracts **only** `dist/autoconsent.standalone.js`
and renames it to `autoconsent.js` (`scripts/build-adblock-lists.sh`). That bundle
self-initializes with rules embedded — there is no separate `rules.json`, and the
playwright bundle is not used. The browser injects it verbatim as a document-start
user script in every frame.
Consumers: `apps/wpe/WPEUserScripts.h`, `WPEWebPage.cpp`, `BrowserPage.qml`.
To bump: change `AUTOCONSENT_VERSION` and re-pin `AUTOCONSENT_SHA256`
(`AUTOCONSENT_URL` now derives the version). Then check the bundle's self-init
tail still ends with `consent.initialize(config, rules)` and still sets
`window.autoconsentReceiveMessage` / `window.autoconsentStandalone` — that is the
whole contract with our injector.
Upstream: <https://github.com/duckduckgo/autoconsent/releases>

## 7. Libraries bundled from Ubuntu (copied, not built)

`scripts/stage-compat-shims.sh` copies these out of `/usr/lib/aarch64-linux-gnu`
into `wpe-sfos-compat` because SFOS doesn't ship them. **They are pinned by
whatever the build host has installed** — bumping the host's Ubuntu packages
silently bumps these, and the filenames are hard-coded with full version
suffixes, so a host upgrade *breaks the build loudly* (file not found).

| Library | Bundled file |
|---|---|
| libsoup3 | `libsoup-3.0.so.0.7.1` |
| brotli | `libbrotlidec.so.1.1.0`, `libbrotlicommon.so.1.1.0` |
| libatomic | `libatomic.so.1.2.0` |
| libjpeg-turbo | `libjpeg.so.8.2.2` |
| libgbm | `libgbm.so.1.0.0` |
| enchant2 (+ hunspell backend module) | `libenchant-2.so.2.3.3` |
| hunspell | `libhunspell-1.7.so.0.0.1` |
| dav1d | `libdav1d.so.7.0.0` |
| hunspell en_US dictionary | `/usr/share/hunspell/en_US.{aff,dic}` |

Plus two **stubs we compile ourselves** to avoid pulling in more: 
`libgssapi_krb5.so.2` (for libsoup3) and `libharfbuzz-icu.so.0` (avoids
`libicuuc.so.74`, absent on SFOS). Sources in `shims/compat/`.

## 8. Provided by SFOS / Jolla (not ours to update)

Linked from the sysroot, listed as `Requires` — track only when the SFOS target
version moves.

- **xdg-dbus-proxy** — 0.1.7+git1, already at the `/usr/bin/xdg-dbus-proxy` path
  libWPEWebKit is compiled to exec. We used to build and package our own 0.1.6,
  which only shadowed Jolla's; dropped 2026-08-18. `atlantic-browser` still
  `Requires` it, now satisfied by the stock package.
- **sqlcipher** — deliberately *not* built by us. Jolla ships it; building our
  own collided on soname and caused heap corruption at startup. See the password
  manager investigation.
- GStreamer 1.0 (+ droid codecs), GLib/GIO, cairo, fontconfig, freetype2,
  harfbuzz, ICU, libpng, libwebp, sqlite3, zlib, wayland, xkbcommon.
- Qt 5 (Core/Qml/Gui/Quick/DBus/Concurrent/Sql), Silica, mlite5,
  nemo-transferengine, nemo-qml-plugin-{policy,notifications,connectivity},
  sailfish-policy, sailfish-components-pickers, libkeepalive, vault, oneshot.

## 9. Search engines

`atlantic-browser/data/searchEngines/brave.xml` — OpenSearch descriptor for
Brave Search. Static, only needs touching if the endpoint changes.

---

## Update status — checked 2026-08-18

| Component | Ours | Upstream | Action |
|---|---|---|---|
| WPE WebKit | 2.52.5 | 2.52.5 (2.53.90 = dev toward 2.54) | ✅ current |
| libwpe | 1.17.0 @ `445a0b55` | main; latest tag 1.16.3 | ✅ pinned 2026-08-18 |
| WPEBackend-fdo | 1.17.0 @ `84492327` | main; latest tag 1.16.1 | ✅ pinned 2026-08-18 |
| libepoxy | 1.5.11 @ `1b6d7db1` | main; latest tag 1.5.10 | ✅ pinned 2026-08-18 |
| libavif | v1.4.2 | v1.4.2 | ✅ bumped 2026-08-18 |
| bubblewrap | 0.11.2 | 0.11.2 | ✅ bumped 2026-08-18 |
| xdg-dbus-proxy | — | Jolla 0.1.7+git1 | ✅ dropped, use stock |
| adblock (Brave) | 0.13.2 | 0.13.2 | ✅ current |
| @duckduckgo/autoconsent | 16.23.0 | 16.23.0 | ✅ bumped 2026-08-18 |
| SFOS SDK target | 5.1.0.11 | 5.1.0.11 | ✅ newest published |
| Actions runner | 2.334.0 | 2.336.0 | 🔼 host-only |
| Filter lists | auto-latest | EasyList 202608181036 | ✅ nothing to pin |
| Brave adblock-resources | `master` | last change 2026-07-29 | ✅ auto-fetched |
| uBO scriptlets.js | 56b82011 (2023) | frozen on purpose | ⛔ do not bump |
| Ubuntu-bundled libs | host packages | nothing upgradable | ✅ |

### Three deps were not actually pinned — fixed 2026-08-18

`scripts/build-engine.sh` and `setup-rpmbuild.sh` both cloned with
`--branch "${VERSION}" ... 2>/dev/null ||` and a bare fallback clone. For libwpe,
WPEBackend-fdo and libepoxy those tags **do not exist upstream** — 1.17.0 and
1.5.11 are the in-development version strings on `main`, not releases. So the
first clone failed silently every time and the build took whatever `main` was on
the day the work dir was created. A CI cache wipe could change the engine with no
version change anywhere.

Now: `clone_pinned()` in `scripts/common.sh` shallow-fetches an **exact commit**
(GitHub serves arbitrary reachable SHAs) and **fails the build** on a bad or
missing pin. Pins live in `versions.env` as `LIBWPE_COMMIT`, `LIBEPOXY_COMMIT`,
`WPEBACKEND_FDO_COMMIT`, set to the commits this host has been building and
device-verifying. The `*_VERSION` values stay — they name the RPMs and match what
the built `.pc` files advertise.

libavif keeps its tag clone (its `v*` tags are real releases) but lost its silent fallback.

To move a pin: check out the new commit, rebuild, device-verify, then update
`*_COMMIT` — and `*_VERSION` plus the `rpm/*.spec` `Version:` field only if
upstream's declared version actually changed.

Note libepoxy has `patches/engine/libepoxy-rtld-default-fallback.patch` applied on
top; it was verified to apply cleanly against the pinned commit.

### bubblewrap 0.11.2 needs a -Werror relaxation

0.11.2's overlay-mount error path passes possibly-NULL args to a `"%s"` format
and GCC 13 on this host escalates upstream's `-Werror=format=2` over it, so the
build fails. 0.11.0 compiled clean and `meson.build` is unchanged between them —
it is the C code that moved. `scripts/build-sandbox-deps.sh` now appends
`-Wno-error=format-overflow`; it still warns, it just does not fail.

That append goes through `native_c_args()`, because meson's built-in `c_args`
land *after* a project's own `add_project_arguments` (so a `-Wno-error` only
wins from there), and `CFLAGS` is ignored once a native file defines `c_args`.
The helper reads the tuning flags back out of `native-meson.ini` instead of
restating them, so the two cannot drift.

0.11.2 is the CVE-2026-41163 fix. It only affects setuid installs, which we are
not, and upstream now defaults `support_setuid=false` — the built binary reports
*"setuid use of bubblewrap is not supported in this build"*, so the affected code
is compiled out.

### libavif v1.0.4 -> v1.4.2 is soname-compatible

`LIBRARY_VERSION_MAJOR` is still 16, so the soname stays `libavif.so.16` and
WebKit's `USE_AVIF` link is unaffected. The lean decode-only build survives the
bump unchanged: same cmake flags, and `NEEDED` is still just libdav1d, libm and
libc — the whole point of building our own instead of using Ubuntu's. The
packaging symlink is derived from the real filename, so `libavif.so.16.4.2` ->
`libavif.so.16` needs no edit.

Verified by compiling and linking WebKit 2.52.5's exact libavif API surface
(`AVIFImageReader.cpp`: decoder create/parse/NthImage, `strictFlags`,
`avifRGBImage` fields, `imageTiming.duration`) against the 1.4.2 headers and the
built library.

---

## Quick update sweep

```sh
cd /release/workspace/atlantic-engine
grep -nE '_VERSION=|_URL=|_SHA256=' versions.env      # everything in one screen
grep -A2 '^name = "adblock"' adblock-engine/Cargo.lock # Brave engine actual version
```

Then compare against upstream:

| Check | Where |
|---|---|
| WPE WebKit | <https://wpewebkit.org/release/> |
| libwpe / WPEBackend-fdo | GitHub releases (both under 1.17.0 now) |
| adblock-rust | <https://crates.io/crates/adblock> — `cargo update -p adblock --dry-run` |
| autoconsent | <https://github.com/duckduckgo/autoconsent/releases> |
| bubblewrap | <https://github.com/containers/bubblewrap/releases> |
| libavif | <https://github.com/AOMediaCodec/libavif/releases> |
| Filter lists | auto-latest; nothing to do unless locking builds |
| Ubuntu-bundled libs | `apt list --upgradable` on this host |

**Never bump blind:** WPE WebKit (patch stack), adblock-rust (FFI + DAT format),
uBO scriptlets.js (frozen on purpose). Everything else is routine.
