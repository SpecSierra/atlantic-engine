> **Status: SHIPPED default-ON build 630** — Page-zoom-as-device-scale made `font-size` double-zoom for `vw/vh` and `cqw/cqi` (lengths were fine, only text). The unzoom fix is on by default; `=0` opts out. A separate defect — VG web fonts never applied — is still open.

# INVESTIGATION — vw/vh font-size renders 3x too large (db.no, vg.no), 2026-07-29

Build under test: **atlantic-browser 1.0.0.beta7-626.1 / wpewebkit2-2.52.5-626.1**
(Xperia 10 II; `rpm -q` verified before the measurements below).
Reported by users as "db.no and vg.no don't display properly".

## CONFIRMED

- **Reproduced on both sites.** db.no redirects to dagbladet.no. Front-page
  headlines render enormously oversized and overflow the right edge; images,
  cards and buttons on the same page are correctly sized. Screenshots
  `dagbladet-a-133433.png`, `vg-134700.png` (freshness proved: two consecutive
  captures differed by md5).

- **Layout viewport is correct.** `innerWidth` 360, `innerHeight` 840/777,
  `devicePixelRatio` 3, `documentElement.scrollWidth` 360, viewport meta
  `width=device-width, initial-scale=1`. No horizontal overflow at the
  document level.

- **Viewport units are correct for lengths, wrong for `font-size`.**
  Measured with injected probe elements, by *rendered geometry*
  (`getBoundingClientRect`), not just computed style:

  | Declaration | Rendered | Expected |
  |---|---|---|
  | `height:100vh` | 840px | 840px OK |
  | `height:840px` | 840px | 840px OK |
  | `height:100px` | 100px | 100px OK |
  | `font-size:84px` (line box) | 84px | 84px OK |
  | `font-size:10vh` (line box) | **252px** | 84px **3.00x** |
  | `font-size:10vw` | **108px** | 36px **3.00x** |

  The error factor is exactly the device pixel ratio, on both sites, for
  `vw`/`vh`/`vmin`/`vmax`/`dvh`/`cqw`. `rem`/`em`/`px` font sizes are correct.
  `zoom` computes to 1, so this is not CSS zoom.

- **Real-page effect.** dagbladet `h2.headline` computes to **144.31px** inside
  a 360px viewport (inner span 186.75px). vg.no headlines: 151px, 126px, 66px,
  60px. These are `vw`-fitted headline sizes multiplied by 3.

- **Page zoom factor is 3.** Independent signal: `(-webkit-device-pixel-ratio:1)`
  and `(resolution:96dpi)` both **match**, while JS `devicePixelRatio` reports 3.
  WebKit evaluates that media query as `deviceScaleFactor / pageZoomFactor`, so
  3/3 = 1. Source side: `qt5-plugin/WPEQtView.cpp:291` calls
  `webkit_web_view_set_zoom_level(m_webView, m_pendingDeviceScaleFactor)` —
  the device scale factor is applied as *page zoom*.

- **Mechanism (source, consistent with every measurement above).** With
  pageZoom = 3, the frame view's size for CSS viewport units is in device px
  (1080x2520). `Style::adjustValueForPageZoom()`
  (`StyleLengthResolution.cpp:50`) divides viewport-unit lengths back by
  `RenderView::zoomFactor()` (= `frame().pageZoomFactor()`, `RenderView.cpp:823`),
  which is what makes `100vh` come out right. But
  `CSSToLengthConversionData::copyForFontSize()`
  (`CSSToLengthConversionData.h:84`) sets `m_zoom = 1` and
  `m_propertyToCompute = CSSPropertyFontSize` **without** setting
  `m_rangeZoomOption = Unzoomed`, so `adjustValueForPageZoom()` returns at its
  first line and the /3 is never applied to font sizes.

## RULED OUT

- **User agent.** Tested all five built-in profiles (`safari-iphone`,
  `chrome-android`, `firefox-android`, `chrome-desktop`, `safari-mac`) plus the
  default, via the shipped per-site override
  (`/apps/atlantic-browser/settings/site_ua_overrides`). dagbladet's
  `h2.headline` computed to **144.309601px in every single case** — byte
  identical, including the two desktop UAs — and the synthetic `10vh` probe
  stayed at 233.1px (innerHeight 777; correct 77.7) throughout. The probe is an
  injected `<div>`, so it does not depend on what HTML the site serves.
  UA does not affect this defect.

- **Compositing / frame scaling.** The defect is present in computed style and
  in `getBoundingClientRect`, i.e. before anything is composited. Non-text boxes
  on the same page are correct.

- **Local engine patch.** None of the 116 patches in
  `atlantic-engine/patches/webkit/` touches viewport units, font-size
  resolution, or zoom.

- **Text autosizing.** `font-size` in `px`/`rem`/`em` is exact; a global
  autosizing multiplier would have moved those too.

## OPEN — next cheapest experiments

1. Confirm `pageZoomFactor == 3` directly rather than by inference (one-line
   log in `WPEQtView.cpp:291`, or read the zoom level back through the browser's
   existing `webkit_web_view_get_zoom_level` call at
   `WPEWebPage.cpp:2596`). ~15 min.
2. Decide between two fixes:
   - **(a) engine, narrow:** make `copyForFontSize()` also set
     `m_rangeZoomOption = CSS::RangeZoomOptions::Unzoomed` so font-size viewport
     units get the same /zoomFactor treatment as every other length. Small,
     targeted, but patches CSS core and needs the full patch-stack validation.
   - **(b) qt5-plugin, root:** stop expressing device scale as page zoom — set
     the device scale factor through the proper WPE path and leave zoom at 1.0.
     Fixes the dpr media-query bug too, but is a much wider blast radius
     (touches every size in the engine) and risks regressing the whole
     rendering pipeline.
   Bracket both behind an env flag, default OFF, then A/B 5x5 per the
   building rules.
3. **Second, separate user-visible bug found on the way:** because the media
   query resolves dpr to 1, responsive images serve **1x assets to a 3x
   screen** — `srcset`/`image-set()` `x` descriptors pick the lowest-res
   candidate. Expect blurry images site-wide. Not yet quantified.

## CORRECTION + FIX (option a), 2026-07-29

**The mechanism stated above under CONFIRMED was wrong** in one respect, caught
before any code was written: `EvaluationTimeZoomEnabled` defaults to **false**
off Cocoa (`UnifiedWebPreferences.yaml:2795`), so
`Style::adjustValueForPageZoom()` is a no-op on WPE and the
`copyForFontSize()`/`rangeZoomOption` story could not be the cause. All the
*measurements* above stand; only the explanation changed.

Corrected mechanism, consistent with every measurement:

- The viewport-percentage cases in `computeNonCalcLengthDouble()` **return
  early**, so they skip the `* conversionData.zoom()` that `px`/`em` receive.
  `sizeForCSSDefaultViewportUnits()` is in zoomed (device) px = 2520, so
  `height:100vh` → 2520 internal → reported 840. Correct.
- `font-size` resolves via `copyForFontSize()` (zoom = 1) and stores a
  *specified* size, which `computedFontSizeFromSpecifiedSize()`
  (`StyleFontSizeFunctions.cpp:86`) later multiplies by `style.usedZoom()`.
  `84px` → specified 84 → ×3 → renders 84 CSS px. Correct.
- `10vh` → specified **252** (already zoomed) → ×3 again → renders **252 CSS
  px**. Zoom applied twice. Matches the measured 252 exactly.

**Fix committed:** `atlantic-engine@74d36df` —
`patches/webkit/webkit-viewport-unit-font-size-zoom.patch`, registered in
`scripts/patches.sh`. In `adjustValueForPageZoom()`, when
`computingFontSize()`, divide by `style.usedZoom()` so the stored specified
size is unzoomed like every other specified size. Only the viewport-percentage
cases reach that function, so px/em/rem/ch are untouched. Gated on
`WEBKIT_VIEWPORT_UNIT_FONT_SIZE_ZOOM=1`, **default off**.

Validated: `patch -p1 --dry-run` applies cleanly; no other patch in the stack
touches `StyleLengthResolution.cpp`; `bash -n scripts/patches.sh` OK.

### Still OPEN

1. **Not yet built or verified on device.** Needs a CI build (push to
   `atlantic-engine` master), then the A/B below. Nothing here is confirmed
   working yet.
2. **A/B plan.** Flag is a WebKit env var, so no rebuild between arms:
   `atldbg launch --env WEBKIT_VIEWPORT_UNIT_FONT_SIZE_ZOOM=1` vs unset,
   interleaved ABAB. Expected effect size is enormous (3.00x → 1.00x), far
   above any noise floor — this is a correctness check, not a perf measurement.
   Pass criteria, on both dagbladet.no and vg.no:
   - probe `font-size:10vh` == `innerHeight/10` (±1px), `10vw` == `innerWidth/10`
   - `height:100vh` still == `innerHeight` (no regression on the length path)
   - `font-size:16px`, `1rem`, `1em` unchanged at 16px
   - dagbladet `h2.headline` drops from 144.31px to ~48px; headlines no longer
     overflow the right edge (screenshot, freshness-proved)
3. **Container-query units in font-size** resolved against a real container skip
   `adjustValueForPageZoom()` at their own call site
   (`StyleLengthResolution.cpp:260`) and are NOT fixed by this patch. The
   cq→viewport fallback is. Unquantified on real pages.
4. **The dpr media-query bug is untouched by this patch.**
   `(-webkit-device-pixel-ratio:1)` still matches on a 3x screen, so `srcset`/
   `image-set()` still pick 1x assets → blurry images site-wide. Separate fix,
   separate investigation.

## SECOND DEFECT: VG web fonts not applied (2026-07-29, build 626, unpatched)

Triggered by "some fonts are still wrong on the page right now". Note the
font-size patch (74d36df) is **not built or deployed**, so the 3x font-size
defect is fully live on the device; that alone makes text look wrong. The
following is a *separate* defect found while looking.

### CONFIRMED

- **vg.no renders its headlines in a fallback font.** Measuring the same string
  at 24px/700, `"VG Serif Variable"`, `"VG Sans Variable"` and
  `"VG Effekt Variable Complete"` all measure **388.7px** — byte-identical to a
  deliberately nonexistent family `"NoSuchFontXYZ"` (388.7). On the same page
  `Roboto` measures 335.8 and `"Austin News Deck Web"` 318.2, so the
  measurement instrument works and those two faces genuinely apply.
  The real headline element's computed family is `"VG Serif Variable"` and
  `document.fonts.check()` on its own computed font returns **false**.

- **The font files download fine.** VGSerifVariable.woff2 99,677 B,
  VGSansVariable.woff2 62,752 B, VGEffektVariableComplete.woff2 155,651 B, via
  both `link` (preload) and `css` initiators. A manual `fetch()` of the VG
  Serif URL returns 99,260 bytes. So this is not a network/adblock failure.

- **Only `font-size` is affected by the viewport-unit bug.** Swept 20
  properties with a `10vh` value against the expected 84px: `line-height`,
  `letter-spacing`, `word-spacing`, `text-indent`, `border-width`,
  `outline-width`, `border-radius`, `padding`, `margin`, `width`, `height`,
  `column-gap`, `column-width`, `flex-basis`, `text-decoration-thickness`,
  `text-underline-offset`, `stroke-width`, `perspective`, `background-size`,
  `box-shadow`, `text-shadow`, `transform` all measure exactly 1.00x.
  `font-size` alone is 3.00x. **Patch 74d36df's scope is therefore complete.**

- **Retraction: images are NOT low-res.** The earlier prediction that the
  dpr=1 media query would make `srcset` pick 1x assets is **wrong**. Measured
  natural/CSS width ratios on vg.no: 3.29, 3.45, 3.29, 3.29, 3.00, 3.45, 3.45,
  4.94. The w-descriptor/`sizes` selection path uses the real device pixel
  ratio, not the media-query value. The dpr media query still misreports
  (`-webkit-device-pixel-ratio:1` matches, `min-resolution:2dppx` false), which
  would still affect CSS-driven art direction, but the actual images on these
  pages are fine.

### RULED OUT / INSTRUMENTS THAT FAILED THEIR CONTROL

- **`new FontFace(...).load()` is unusable in this build.** It rejects with
  "NetworkError" for *everything*, including `"Austin News Deck Web"` (which
  demonstrably works on the page) and including a face constructed from an
  already-fetched 99,260-byte ArrayBuffer with no network involved. So the
  NetworkError seen for the VG families is an artifact and is **not** evidence
  about those fonts. (Possibly a real bug in its own right; unexamined.)

- **Dynamically injected `@font-face` does not apply either.** Injecting a
  `<style>` with fresh family names pointing at the same URLs, then using them,
  left all four measuring 388.7 — including a control pointing at the
  known-good Austin file with plain `format("woff2")`. So this method could not
  test the format-token hypothesis. `document.fonts.check()` also returned
  `true` for all of them while they rendered as fallback, so check() is
  unreliable here too.

### OPEN — leading hypothesis, NOT proven

Every family on vg.no that uses `format("woff2")` applies (Roboto, Austin News
Deck Web); all three that use the legacy `format("woff2-variations")` token do
not:

    @font-face { font-family:"VG Serif Variable";
      src:url(".../VGSerifVariable.woff2") format("woff2-variations"); ... }

`FontCustomPlatformData::supportsFormat()`
(`platform/graphics/skia/FontCustomPlatformDataSkia.cpp:135`) accepts
`woff2-variations` only under `#if ENABLE(VARIATION_FONTS)`, while plain
`woff2` is accepted unconditionally. But `ENABLE_VARIATION_FONTS` defaults
**ON** for the WPE port (`OptionsWPE.cmake:117`) and Atlantic does not override
it, so the gate should be satisfied — the hypothesis does not yet hang
together. Confounder: `Inter` declares plain `format("woff2")` and also fails
to apply.

Next cheapest experiment (~20 min): a **local `file://` bench page** (per the
harness rules — removes CORS, network and timing variables), serving one copy
of the VG woff2 declared three ways (`woff2`, `woff2-variations`, no format
token) plus a known-good static woff2 control, pushed to the device with
`scp`. Verify the control applies before drawing any conclusion. Then confirm
whether `ENABLE_VARIATION_FONTS` is actually ON in the shipped library
(`tr -c '\40-\176' '\n' < libWPEWebKit-2.0.so.1 | grep -i variation`).

## PATCH SCOPE WAS WRONG — container units, 2026-07-29

Commit 74d36df (viewport units only) **would not have fixed either reported
site**, and was amended to d09d4ed. Found by trying to simulate the fix live:
rewriting every viewport-unit font-size in vg.no's own stylesheets changed
**0 declarations out of 2596 rules** — the sites do not size headlines with
`vw` at all.

Scanning the actual rules:

    dagbladet  h2.headline:has(.auto-font-size-line)
                 { font-size: var(--lab-auto-font-size, 5cqi) }
               --lab-auto-font-size is unset, so the 5cqi FALLBACK renders:
               144.31px where correct is 48.10px
    vg.no      ._avatarInitials { font-size: 40cqw }  -> 432px, not 144px

Both are **container-query units**, which take a different code path
(`resolveContainerUnit()` at `StyleLengthResolution.cpp:258`) that explicitly
skips `adjustValueForPageZoom()` when `computingFontSize()`.

Confirmed with an explicit 300x200 `container-type:size` container:

| Declaration | Got | Expected |
|---|---|---|
| `font-size:10cqw` | **90px** | 30px (3.00x) |
| `font-size:10cqh` | **60px** | 20px (3.00x) |
| `font-size:10cqi` | **90px** | 30px (3.00x) |
| `font-size:10cqb` | **60px** | 20px (3.00x) |
| `height:10cqw` | 30px | 30px OK |
| `height:10cqh` | 20px | 20px OK |

Same double-zoom, same cause: the container's `contentBoxWidth()` is a zoomed
layout value. Patch now covers both call sites; env var renamed
`WEBKIT_VIEWPORT_UNIT_FONT_SIZE_ZOOM` -> **`WEBKIT_FONT_SIZE_UNIT_UNZOOM`**
since it is no longer viewport-specific. `patch -p1 --dry-run` OK,
`bash -n scripts/patches.sh` OK.

**Lesson worth keeping:** the synthetic `10vh` probe proved an engine bug, but
proving the bug is not the same as proving it is *this page's* bug. Checking
which units the sites actually use should have come first — it is one CSSOM
scan and it would have caught the wrong scope before the first commit.

### Still OPEN

- **Unbuilt, unverified.** Needs a CI build; nothing is confirmed working.
- A/B once built: `atldbg launch --env WEBKIT_FONT_SIZE_UNIT_UNZOOM=1` vs
  unset. Pass criteria: `10cqw` in a 300px container == 30px; `10vh` ==
  innerHeight/10; `height:100vh` and `height:10cqw` unchanged; `16px`/`1rem`
  unchanged; dagbladet `h2.headline` 144.31px -> ~48px; vg `._avatarInitials`
  432px -> 144px; no right-edge overflow, freshness-proved screenshot.
- The **VG web fonts not applying** (previous section) is a separate defect and
  is NOT addressed by this patch.

## VERIFIED ON DEVICE — build 629, 2026-07-29

### 1. Engine patch (d09d4ed) — SHIPPED, VERIFIED, still default OFF

CI run 30461704633 success. Installed atlantic-browser/wpewebkit2 **629.1**;
`WEBKIT_FONT_SIZE_UNIT_UNZOOM` confirmed present in the shipped
libWPEWebKit-2.0.so.1.9.9 before measuring. Interleaved ABABAB, 3 arms each:

| Check | flag off | flag on |
|---|---|---|
| `font-size:10cqw` (300px container) | 90.00 (3.00x) | **30.00** OK |
| `font-size:10cqh` (200px container) | 60.00 (3.00x) | **20.00** OK |
| `font-size:10cqi` | 90.00 (3.00x) | **30.00** OK |
| `font-size:10vh` | 252.00 (3.00x) | **77.70** OK |
| `font-size:10vw` | 108.00 (3.00x) | **36.00** OK |
| dagbladet `h2.headline` | 164.12px | **54.71px** |
| `height:` 100vh / 10cqw / 10cqh | unchanged | unchanged |
| `16px` / `1rem` / `2em` / `100px` | unchanged | unchanged |

Zero spread within each arm (deterministic computed style — correctness check,
not a perf measurement). Screenshot freshness-proved.

### 2. Root-cause fix in the qt5 plugin (9871be3) — WORKS, experimental

`ATLANTIC_TRUE_DEVICE_SCALE=1`: dispatch the scale through
`wpe_view_backend_dispatch_set_device_scale_factor()`, give WebKit the LOGICAL
size (m_size / scale), leave page zoom at 1.0, divide input coords by the scale.
Built locally against /opt/wpe-sfos and hot-deployed (~40 s per iteration, much
faster than CI).

**With the engine patch OFF, this alone fixes every font-size unit** — and also
`devicePixelRatio` 1 -> **3**, `(-webkit-device-pixel-ratio:3)` false -> **true**,
`(min-resolution:2dppx)` false -> **true**. innerWidth/innerHeight stay 360/840.

- **Full resolution kept.** Mean std within each 3x3 device-pixel block: **3.81**
  (zoom path 3.64). A nearest-neighbour 3x upscale measures **0.00** — which is
  exactly what the first revision produced.
- **Input verified end-to-end.** Raw tap at device (540,900) opened the article
  whose headline `elementFromPoint(180,300)` reports.
- **Inert when off** — reproduces the 3.00x defect exactly.

**Ordering gotcha (cost one wrong result):** the scale must be dispatched AFTER
the `WebKitWebView` is constructed. Dispatching right after backend creation
looks right, but no `wpe_view_backend` client is attached yet and libwpe drops
it silently; WebKit then renders a 360x840 buffer upscaled 3x. It still "fixed"
the font sizes — by rendering the whole page at 1/3 resolution. Visually subtle;
the 3x3-block test is what caught it. **Always measure resolution, not just
computed style, when changing the scale model.**

### Still open before the plugin fix could ship on

1. Pinch zoom still baselined on `m_defaultZoomLevel = 3` (browser repo,
   `WPEWebPage.cpp:2625-2633`) — wrong once zoom means user zoom.
2. Scroll degradation ladder thresholds change meaning again; re-tune + re-A/B.
3. `webkit-svg-filter-scale-cap.patch` premise (9x) becomes 3x.
4. RAM: correct dpr means sites serve real 3x assets. Unmeasured, and RAM is
   already a tracked problem.
5. Device left on the **stock 629 plugin**; the experimental one is one scp away.

### Unrelated defects confirmed still present (NOT fixed by either change)

- **dagbladet's own auto-fit JS never sets `--lab-auto-font-size`**, so the
  `5cqi` fallback renders and long headlines still overflow even at the correct
  size. Site-side or a JS defect; uninvestigated.
- **vg.no web fonts still never apply.** `format("woff2-variations")` is now
  **RULED OUT** as the cause: the shipped build has `ENABLE_VARIATION_FONTS 1`
  (read from the real generated `WebKitBuild/Release/config.h`), so
  `supportsFormat()` accepts that token. Cause still unknown.

## vg.no residual overflow = the web-font defect, 2026-07-29 (build 629, fix ON)

With `WEBKIT_FONT_SIZE_UNIT_UNZOOM=1` the 3x defect is gone, but vg.no text
still leaves the page. **Different cause.**

All 12 genuinely-overflowing leaf elements (excluding legitimately clipped
carousels) are the same component:

    SPAN._dynamic-segment_  white-space:pre  font-family:"VG Serif Variable"
    font-weight:817  font-size:39.546661px / 56.425251px / 32.57523px ...

Fractional sizes = VG's text-fitting JS choosing a size so the line exactly
fills its box. And it succeeds: the fitted span is 357px wide inside a parent
that is *also* 357px. The problem is the box starts at x=16, so 16+357 = 373 >
360 viewport.

**The fitter is fitting against the wrong font.** `"VG Serif Variable"` is not
applied — it measures identical to a nonexistent family, and
`document.fonts.check('817 24px "VG Serif Variable"')` is **false**. VG sizes
its headlines around its own font's metrics; substitute a wider fallback and
the computed size overflows.

So: fixing vg.no completely requires fixing the web-font defect, which is
independent of the font-size patch.

### Web-font defect: what is now RULED OUT

- **`format("woff2-variations")`** — the shipped build has
  `ENABLE_VARIATION_FONTS 1` (read from the real generated
  `WebKitBuild/Release/config.h`), so `supportsFormat()` accepts it. The CSS
  parser also accepts `<string>` formats
  (`CSSPropertyParserConsumer+Font.cpp:552`), and the CSSOM shows all the rules
  intact.
- **Network / adblock** — every font file is fetched. On a local bench served
  from the device, the access log shows all five `.woff2` requests returning
  **200**.
- **Variation-font support being compiled out** — see above.

### Instruments that failed their own control (do not trust these)

1. `new FontFace(...).load()` rejects with "NetworkError" for *everything*,
   including a face built from an already-fetched ArrayBuffer. Useless here.
2. Dynamically injected `@font-face` never applies, including a control
   pointing at a font that demonstrably works on the live page.
3. **Local bench, both `file://` and `http://127.0.0.1:8099`**: all five faces
   parse (verified via CSSOM), all five files return 200 (verified in the server
   access log), `document.fonts.status` is `loaded` — and yet all six spans,
   including the bogus-family control, measure an identical 207.6px. Faces
   report status `unloaded`. So on the bench NOTHING applies, which contradicts
   vg.no where Roboto/Austin/DIN/Inter do differ from the bogus baseline.
   Suspect the bench itself (python `http.server` serves `.woff2` as
   `application/octet-stream`; untested).

### Caveat on the vg.no font comparison

On vg.no, `Roboto`, `Inter`, `"Austin News Deck Web"` and `"DIN Next LT Pro"`
all measured **identically** (416.5 / 457.9) while differing from the bogus
baseline (409.9 / 413.8). Four unrelated typefaces cannot share metrics to
0.1px, so "applied = differs from bogus" is probably measuring *which fallback
was chosen*, not whether the real face loaded. The VG-vs-others split is real
and reproducible, but the mechanism behind it is not established.

**Next step: serve the bench with a correct `font/woff2` Content-Type from a
real server, and confirm the control applies before reading anything else.**

## DEFAULT ON — build 630, verified 2026-07-29

`a742083` pushed; CI 30466495080 success; Pages deploy 30467519586 success;
device updated to **630.1**.

Verified with the browser launched from a **plain `setsid /usr/bin/atlantic-browser`
with no environment variables at all** (`/proc/<pid>/environ` confirmed to
contain no `WEBKIT_FONT_SIZE_*`):

    font-size:10cqw  30.00   font-size:10vh  77.70    height:10cqw   30.00
    font-size:10cqh  20.00   font-size:10vw  36.00    height:10cqh   20.00
    font-size:10cqi  30.00                            height:100vh  777.00
    16px 16.00 | 1rem 16.00 | 2em 32.00 | height:100px 100.00   -> all unchanged
    dagbladet h2.headline 59.42px    text elements overflowing right: 46 -> 9

    VERDICT: PASS

Opt-out re-verified: `WEBKIT_FONT_SIZE_UNIT_UNZOOM=0` restores 3.00x
(10cqw 90.00, 10vh 252.00, headline 178.26px), so the bisect lever still works.

### Remaining on these two sites (both site-side / separate defects)

- **dagbladet**: `--lab-auto-font-size` is still never set, so the `5cqi`
  fallback renders. That is a fixed proportion, so a long word ("gigantsum")
  still runs off the right edge even at the correct size. 9 elements still
  overflow, down from 46.
- **vg.no**: web fonts still never apply, so its text-fitting JS sizes against
  fallback metrics. Unsolved; see the previous section for what is ruled out.

Neither is caused by, or fixable in, the font-size patch.
