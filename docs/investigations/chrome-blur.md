> **Status: SHIPPED** — Screen-fixed blurred chrome via `gl_FragCoord`-sampled wallpaper, device-verified. The plan section below is background for why the earlier attempts failed.
>
> Archived `handover.md`, `blur-plan.md` (build host `/root`), 2026-07-30.

# Blur — Handover

**Date:** 2026-06-06  
**Repo:** `SpecSierra/atlantic-browser`  
**Commit:** `10eb6014` (blurred ambience wallpaper with FastBlur)

## RESOLVED (2026-06-06) — screen-fixed blurred wallpaper

The "wallpaper stuck to the element / no dark tint / no blur" issue is fixed in
`apps/shared/Background.qml`. Working approach, verified on device:

- **Screen-fixed reveal:** the chrome no longer *positions* a wallpaper Image to
  line up with the element. Instead the blurred wallpaper is sampled in the
  fragment shader using `gl_FragCoord` (window/screen pixel coords):
  `wpCoord = vec2(gl_FragCoord.x/screenW, 1.0 - gl_FragCoord.y/screenH)`.
  This is the same window-fixed trick the upstream Silica glass-noise shader uses
  (`gl_FragCoord.xy * glassTextureSizeInv`). The element acts as a window onto a
  pinned wallpaper — exactly the asked-for effect. No `mapToItem`/`y:-wallpaper.y`
  hacks (those only compensated the immediate parent offset, not absolute screen Y).
- **Capture must survive small/clipped elements:** the wallpaper `Image` is
  `Screen.width × Screen.height` with `layer.enabled: true` +
  `layer.textureSize = Screen`. The layer FBO forces a full-screen render even when
  the host `Background` is a tiny clipped toolbar — without it, the device only
  captured the clipped strip, so the URL bar went black while the full-screen tab
  selector looked fine. (`clip: true` on the root still prevents the visible Image
  from covering web content.)
- **Capture gotchas confirmed:** `visible:false` on the Image → SES captures
  nothing (black). Keep it visible; `hideSource:true` + `clip:true` keep it off the
  web view. `asynchronous:false` so the image is ready before first capture.
- **Compositing:** single `ShaderEffect` pass = blurred wallpaper (FastBlur
  radius 64) → dark tint `mix(rgb, black, 0.40)` → subtle glass noise. Tweak the
  `tint` alpha (line ~101) to taste.

Note: bottom toolbar can look dark — that's correct. The fire ambience's bottom is
near-black (water reflection), and a screen-fixed bottom toolbar reveals that
region. Brighter ambiences / larger surfaces show the blur clearly.

**Follow-up / optimization (not blocking):** `wpCapture` and the final `wpTexture`
SES are `live:true`, so every Background instance re-renders a full-screen FastBlur
each frame. The wallpaper is static — could switch to `live:false` + `scheduleUpdate()`
on image-ready / ambience-change to cut GPU load. Left live because it's confirmed
working and the static-capture timing is fiddly.

---
## (Original notes below — superseded by the RESOLVED section above)

## What Works

- **Ambience wallpaper detection** — `Sailfish.Ambience 1.0` import, `Ambience.source` → derived `.jpg` path. Wallpaper image loads correctly.
- **GPU blur** — `FastBlur { radius: 24 }` from QtGraphicalEffects produces visible blur.
- **Blend/opacity** — custom `ShaderEffect { blending: true; opacity: 0.55 }` composites blurred wallpaper at 55%.
- **Darkening** — fragment shader `c * 0.7` dims the blurred layer.
- **Glass noise preserved** — original `graphic-shader-texture` ShaderEffect on top, unchanged.
- **Tint rectangle removed** — replaced with darkening blur.
- **No WPE/web content interaction** — no captures of `webView`, no C++ `SilicaBackground.Background` layer effects. Safe for web rendering.

## Files Changed (single file)

`apps/shared/Background.qml` — imports `QtGraphicalEffects 1.0`, `Sailfish.Ambience 1.0`. Adds:
- `Ambience.source` → wallpaper `.jpg` URL derivation
- `Image { y: -wallpaper.y; ... }` — screen-fixed wallpaper source
- `ShaderEffectSource { hideSource: true; live: true }` — live capture
- `FastBlur` — GPU blur
- Custom blur overlay `ShaderEffect` — composites blurred dark wallpaper
- Root `Item { clip: true }` — clips wallpaper to toolbar bounds

## Unresolved Issue — Wallpaper Image Renders on Top of Web Content

The `Image` element used as wallpaper source renders visibly on screen, **blocking the web page content**. Attempted mitigations:

| Mitigation | Result |
|------------|--------|
| `Image.visible: false` | `ShaderEffectSource` captures **nothing** — blur disappears |
| `ShaderEffectSource.hideSource: true` (without `visible: false`) | Image **still renders** on screen, blocking web content |
| `Item.clip: true` on root | Prevents bleeding outside toolbar bounds, but Image **within** toolbar still covers |

**Root cause:** The Image must be rendered (visible) for `ShaderEffectSource` to capture its texture. `hideSource: true` on `ShaderEffectSource` is supposed to hide the source item from rendering, but it's not working on this device/GLES stack.

### Screen-Fixed Positioning

`Image { y: -wallpaper.y }` is intended to compensate for toolbar movement (keep wallpaper fixed in screen space). When combined with the visibility issue, the Image either:
- Renders opaquely blocking web content (when visible)
- Stops the blur from working (when `visible: false`)

With `ShaderEffectSource.live: true`, the capture should update when `wallpaper.y` changes. This logic is correct in theory but untestable due to the visibility issue.

## Current State on Device

The latest deployed `Background.qml` has:
- `clip: true`, `live: true`, `hideSource: true`
- Image is visible (no `visible: false`)

Expected behavior with this config: **still broken** — Image renders on top of web content.

## Environment

- **Device:** Xperia 10 II, Sailfish OS 5.x, GLES3 on Adreno 610
- **Web engine:** WPE WebKit 2.52.4
- **CI:** `SpecSierra/atlantic-engine` — builds RPMs at push to `atlantic-browser` main

## Next Steps / Approaches to Try

1. **Use `layer.enabled` on a wrapper Item** — force the Image into an FBO. `ShaderEffectSource` can capture FBO-backed items even with `visible: false`. Test: wrap `wpImage` in `Item { layer.enabled: true; Image { ... } }`, set wrapper `visible: false`, capture the wrapper.

2. **Use `FastBlur` directly on Image** (remove `ShaderEffectSource`). Test: `FastBlur { anchors.fill: parent; source: wpImage; }` Make `wpImage.visible: false` and see if `FastBlur` can source from a hidden item. (FastBlur is a QtGraphicalEffects item, not ShaderEffectSource.)

3. **Use `OpacityMask` or `GaussianBlur` on the wrapper Item** — different QtGraphicalEffects might handle hidden sources differently.

4. **Manual z-ordering** — put `wpImage` at `z: -999` behind everything, rely on it being occluded by web content rather than using `visible: false`.

5. **Switch to `SilicaBackground.Background` with a workaround** — the C++ Background cannot be layer-effected or captured, but maybe its wallpaper image URL can be obtained through `Ambience.source` and rendered natively by the Background. Then apply blur *only* through the glass ShaderEffect (blur the glass texture, not the wallpaper). This was the earlier "noise blur" approach that the user said was "not the ask" — they want wallpaper blur, not noise blur.

6. **D-Bus wallpaper path** — query `com.jolla.ambienced` D-Bus for the wallpaper file path, load it directly, and bypass `ShaderEffectSource`/`FastBlur` entirely by writing a custom blur in the existing glass ShaderEffect's fragment shader.

---

# Blur Implementation Plan — Atlantic Browser

## Problem

The browser chrome uses a "glass" effect that composites the **Sailfish ambience
wallpaper** through a semi-transparent noise texture (`Background.qml` line 54-90).
This shows wallpaper through chrome — not blurred web page content. Modern browsers
blur the actual page content behind toolbars/menus.

## Why Past Attempts Failed

Commit `c3d6d63f` ("ui: integrate ambience compositing for glass blur effect"):

- Tried: `Background.Background(sourceItem=glassTextureItem)` — no material set, no
  blur pipeline
- Result: rendered fully transparent
- Commit `dc65f62a` reverted to the ShaderEffect approach

Root cause: `Background` needs a properly processed `sourceItem` (via `FilteredImage`)
AND an explicit `material` (e.g. `BlurMaterial`). Lipstick's `BlurredBackground.qml`
shows the working pattern:

```qml
Background {
    sourceItem: Lipstick.compositor.blurSource   // already filtered/blurred
    material: M.BlurMaterial                     // must be explicit
}
```

## Target Architecture

```
ShaderEffectSource { sourceItem: webView.contentItem }
    ↓ (captures WPE web content at reduced resolution)
FilteredImage { filters: GlassBlur { ... } }
    ↓ (GPU gaussian blur: downscale → convolve → saturate)
Background { sourceItem: <filtered>, material: SilicaBackground.Materials.blur, color: tint }
    ↓ (compositing shader: BlurMaterial blends source with ambience tint)
Existing glass noise ShaderEffect (on top)
    ↓
Result: Blurred web page content + ambience tint + subtle glass noise
```

This mirrors lipstick's compositor blur pipeline exactly.

### Key Silica Types

| Type | Location | Role |
|------|----------|------|
| `FilteredImage` | C++ (Background plugin) | Applies GPU filter chain to `sourceItem` |
| `GlassBlur` | `GlassBlur.qml` | Resize→Gaussian(N reps)→HSV saturate |
| `Background` | C++ (Background plugin) | Renders source via Material shader |
| `BlurMaterial` | `BlurMaterial.qml` | Samples sourceTexture, blends with color |
| `Materials.blur` | singleton | Pre-built BlurMaterial instance |

GlassBlur defaults: 256×256 downscale, SampleSize17, deviation 5, 2 repetitions

## WPE Capture Feasibility

`WPEWebPage` uses `WPEQtView::updatePaintNode()` which returns a standard
`QSGSimpleTextureNode` wrapping a `GL_TEXTURE_2D`. The internal EGLImage is
re-imported into the Qt GL context's texture namespace — it looks like any
other textured `QQuickItem` to `ShaderEffectSource`. Capture confirmed possible.

Source item to capture: `webView.contentItem` (the `WPEWebPage`, which has
`setFlag(ItemHasContents, true)`). NOT `webView` itself (the container has
no rendered content).

## Implementation Steps

### Step 1: New BlurCapture Component

**File:** `apps/browser/qml/pages/components/BlurCapture.qml` (new)

```qml
import QtQuick 2.2
import Sailfish.Silica.Background 1.0
import Sailfish.Silica 1.0

Item {
    id: root

    property Item source: null
    property bool enabled: true
    property int quality: 1          // 0=off, 1=fast, 2=normal
    property alias result: filtered  // expose for Background.sourceItem

    ShaderEffectSource {
        id: capture
        sourceItem: root.enabled && root.source ? root.source : null
        sourceRect: Qt.rect(0, 0, root.width, root.height)
        live: false
        hideSource: true
    }

    GlassBlur {
        id: blur
        repetitions: root.quality >= 2 ? 2 : 1
        deviation: root.quality >= 2 ? 5 : 4
        size { width: 256; height: 256 }
    }

    FilteredImage {
        id: filtered
        sourceItem: capture
        filtering: root.enabled
        filters: blur
    }

    function update() { capture.scheduleUpdate() }
}
```

### Step 2: Wire Into BrowserPage

**File:** `apps/browser/qml/pages/BrowserPage.qml` (lines 228-365)

After line 228 (`Shared.WebView` closing brace), add:

```qml
Browser.BlurCapture {
    id: blurCapture
    z: 1                          // between webView(0) and dimmer(3)
    width: browserPage.width
    height: browserPage.height
    source: webView.contentItem
    enabled: blurEnabled.value    // from settings
}
```

Wire blur result to overlay at line 332-365:
```qml
Browser.Overlay {
    id: overlay
    blurSource: blurCapture.result   // new property
    // ... existing ...
}
```

### Step 3: Modify Background.qml

**File:** `apps/shared/Background.qml`

Add a `blurSource` property. When set, layer a `Background(BlurMaterial)` between
the wallpaper and the glass noise ShaderEffect:

```qml
Item {
    id: wallpaper

    property var blurSource: null   // NEW

    // Layer 0: Sailfish ambience wallpaper (always present)
    SilicaBackground.Background {
        anchors.fill: parent
        z: 0
    }

    // Layer 1: Blurred web content (only when blurSource provided)
    SilicaBackground.Background {
        anchors.fill: parent
        z: 1
        visible: wallpaper.blurSource != null
        sourceItem: wallpaper.blurSource
        material: SilicaBackground.Materials.blur
        color: Qt.rgba(Theme.highlightColor.r,
                       Theme.highlightColor.g,
                       Theme.highlightColor.b,
                       0.25)
    }

    // Layer 2: Glass noise texture (existing code, lines 24-90)
    Item {
        id: glassTextureItem
        // ... unchanged ...
    }

    ShaderEffect {
        id: wallpaperEffect
        // ... unchanged ...
    }
}
```

Key: The `BlurMaterial` fragment shader does:
```glsl
gl_FragColor = background2D(sourceTexture, sourceCoord);
gl_FragColor = (gl_FragColor * (1.0 - color.a)) + color;
```
This blends the blurred web content with the ambience tint color, producing
the frosted glass look.

### Step 4: Overlay Accepts Blur Source

**File:** `apps/browser/qml/pages/components/Overlay.qml`

Overlay already `extends Shared.Background` (line 22). Add the `blurSource`
alias to pass through:

```qml
Shared.Background {
    id: overlay
    // ... existing properties ...
    blurSource: blurCapture.result    // already in Background via property
}
```

Since Overlay extends Background and BrowserPage sets `overlay.blurSource`,
the property propagates automatically.

### Step 5: Extend to Other Chrome Surfaces

**PopUpMenu.qml** — Similar pattern: add `BlurCapture` or use the one from
BrowserPage. The popup menu already uses `Background.Background` for its
glass effect (line 224-235); add `blurSource` to it.

**CertificateInfo.qml** — Add a `BlurCapture` and layer a blurred Background
behind the existing glass Rectangle.

**TabView.qml** — Add `blurCapture` property; the tab grid is already sitting
on an ambience-tinted background (line 90-111).

### Step 6: Settings Toggle

**File:** `apps/browser/qml/pages/SettingsPage.qml`

```qml
TextSwitch {
    text: "Blur chrome background"
    description: "Blur web page content behind the toolbar and menus"
    checked: blurEnabled.value
    onCheckedChanged: blurEnabled.value = checked
}
```

Backend: Add `browser/blur_enabled` dconf key via `SettingManager` in C++.

### Step 7: Glass Tuning

Current values → target values with blur:
- Tint Rectangle opacity: 0.95 → 0.85
- Noise texture opacity: 0.25 → 0.15
- Blur layer tint alpha: 0.25 (adjustable per ambience)

## Files Summary

| File | Change |
|------|--------|
| `apps/browser/qml/pages/components/BlurCapture.qml` | **NEW** — GPU blur pipeline |
| `apps/browser/qml/pages/BrowserPage.qml` | Add BlurCapture, wire to Overlay |
| `apps/shared/Background.qml` | Add blurSource property + Background(BlurMaterial) layer |
| `apps/browser/qml/pages/components/Overlay.qml` | Pass through blurSource |
| `apps/browser/qml/pages/components/PopUpMenu.qml` | Add blur to menu background |
| `apps/browser/qml/pages/components/CertificateInfo.qml` | Add blur layer |
| `apps/browser/qml/pages/components/TabView.qml` | Add blur property |
| `apps/browser/qml/pages/SettingsPage.qml` | Add blur toggle |
| C++ `SettingManager` / dconf | Add `browser/blur_enabled` key |

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| ShaderEffectSource captures blank WPE frame | Schedule initial update after `contentItem.painted` signal |
| Background(sourceItem) transparent again | BlurMaterial is explicitly set; FilteredImage provides real rendered content; lipstick pattern is proven |
| GPU perf on SDM665 | 256×256 downscale + 1 rep = ~2ms. `live: false` = only update on overlay position change, not 60fps |
| Private mode texture overlap | PrivateModeTexture sits on top (z-order ensures it); blur sits behind it |
| WPE contentItem is null (no tabs) | `ShaderEffectSource.sourceItem` null check gracefully produces nothing |

## Verification

Deploy to Xperia 10 II and verify:
1. Blur visible behind toolbar when overlay is present
2. No artifacts during overlay slide animation  
3. Scroll performance acceptable (monitor frame timing)
4. Toggle in settings disables blur (falls back to wallpaper glass)
5. Popup menu, certificate info, tab view all blur when enabled
6. Private mode texture renders on top of blur correctly
7. Ambience colour change reflects in blur tint immediately
