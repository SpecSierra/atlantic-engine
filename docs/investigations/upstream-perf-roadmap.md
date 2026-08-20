> **Status: OPEN (2026-08-03, still current at the 2.52.6 bump 2026-08-20)** — A
> roadmap, not a conclusion. Derived from open upstream bugs against WPE 2.52.x,
> our actual engine line. Item 2 is **done and negative** (see below); the rest
> are unstarted and ranked by expected value. The 2.52.5 → 2.52.6 bump changed
> nothing here: 2.52.6 is a bugfix release with no perf work in these areas.

# Upstream performance roadmap

## Why this file exists

Most of our rendering work has been root-caused from the device down. This is the
other direction: what upstream already knows is slow, filtered to what acts on
the 2.52 line (2.52.6 as of 2026-08-20). It exists so we stop re-deriving things Igalia has already filed, and so
we know which landmines are waiting in the 2.54 bump.

Sources are WebKit Bugzilla (WPE WebKit + WebKitGTK components), the
WebPlatformForEmbedded downstream tracker, and the Igalia WebKit periodicals.

## Verified against our tree

### The glClear regression is not ours (yet)

Bug [306420] reports excessive `glClear` in CoordinatedGraphics from commit
`306119@main`, hitting embedded hardest (reporter is on NXP iMX8MP). Checked
against pristine 2.52.5, and **re-checked against pristine 2.52.6 at the
2026-08-20 bump**: `TextureMapper::clearColor()` exists at
`Source/WebCore/platform/graphics/texmap/TextureMapper.cpp:833` and has **zero
call sites** in the tree (the only `clearColor(` hits tree-wide are unrelated
ANGLE ones). The regression landed on main after the 2.52 branch, so no 2.52.x
point release can pull it in.

**Action: none now.** Re-check at the 2.54 bump. This matters more than its size
suggests — the frame-handoff work already deleted a redundant `glClear` + quad,
so taking 2.54 blind would re-import exactly the class of bug we removed.

### We ship a configuration upstream never validated

Bug [287572]: enabling `WEBKIT_SKIA_ENABLE_CPU_RENDERING=1` on the WPE bots
produced ~140 unexpected results — ~130 ImageOnlyFailures (compositing, filters,
backgrounds, canvas, SVG, WebVTT), 8 crashes, 2 WebVTT timeouts. It was closed
**procedurally**, by moving the variable into the Python tooling so devs and bots
match. The failures were never fixed.

We set this variable from `atlantic-browser.bin` whenever the GPU-conservative
probe trips, which is every launch on the dev device. It doubles our fps, so this
is not an argument to turn it off — it is an argument that we had unmeasured
correctness debt in the paths that generate our bug reports.

## Item 2 — RESOLVED NEGATIVE: the 287572 crashers do not crash us

Ran all eight upstream crashers on device, build **636**
(`wpewebkit2-2.52.5-636.1`), Xperia 10 II / Adreno 610.

Confirmed the WebProcess was in the flagged configuration before trusting the
result — `/proc/<webproc>/environ` showed:

```
WEBKIT_SKIA_ENABLE_CPU_RENDERING=1
WEBKIT_SKIA_CPU_PAINTING_THREADS=2
ATLANTIC_GPU_CONSERVATIVE=1
```

**Result: all 8 survived.** WebProcess PIDs 27771 and 27843 were identical before
and after the run — no crash, no respawn, no coredumps in
`/var/lib/systemd/coredump`.

| # | Upstream test | Result |
|---|---|---|
| 0 | `fast/canvas/canvas-bg.html` | survived |
| 1 | `fast/css/cascade/box-shadow-and-webkit-box-shadow-cascade-order.html` | survived |
| 2 | `fast/images/large-image-webkit-canvas.html` | survived |
| 3 | `fast/inline/out-of-flow-with-static-position-in-ifc.html` | survived |
| 4 | `…/imagebitmap/imageBitmapRendering-transferFromImageBitmap.html` | survived |
| 5 | `…/imagebitmap/imageBitmapRendering-transferFromImageBitmap-flipped.html` | survived |
| 6 | `…/imagebitmap/imageBitmapRendering-transferFromImageBitmap-webgl.html` | survived |
| 7 | `…/imagebitmap/imagebitmap-replication-exif-orientation.html` | survived |

Harness: `scripts/devtools/cpurender/`. It checkpoints into `localStorage` before
each test and reloads after, so a WebProcess death leaves the index pointing at
the culprit rather than losing the run. Re-run instructions are in its README.

**What this does and does not close.** It closes the crash category: the CSS
box-shadow and canvas ImageBitmap crashes upstream sees do not reproduce on our
engine build on Adreno 610. It does **not** touch the ~130 ImageOnlyFailures —
those are pixel diffs and need reference renders we do not have on device. If we
ever see silent visual corruption in filters, SVG, or compositing, that list is
the first place to look, not the last.

## Ranked next steps

### 1. Backport damage-for-compositing early, behind a gate — high payoff

Bug [319685] flips `UseDamagingInformationForCompositing` on for GTK and WPE
(PR #69662), deliberately held until after the next stable branch, so it lands in
**2.54, not 2.52**. Companion bug [315687] restricts compositing with damage in
the Skia compositor.

Cherry-pick onto 2.52.6 rather than waiting. Ship as `ATLANTIC_DAMAGE_COMPOSITING`
default **OFF** and A/B on device. This is the same lever as
`WEBKIT_SKIP_ROOT_CUSTOMPROP_REPAINT` and the damage-limited compositing work,
but general rather than special-cased, and it is explicitly aimed at low-end
embedded GPUs — our situation.

Pre-register the known defects so we do not re-root-cause them:

- [316052] opacity animation does not damage descendant layers
- [307135], [314299] flaky damage tests

Validate with `WEBKIT_SHOW_DAMAGE=1`.

### 2. ~~Run the 287572 crashers on device~~ — DONE, negative (above)

### 3. Measure the complex-text tax — medium-high payoff, cheap to measure

Bug [295019]: since the Skia switch, GTK/WPE run in **always-force-complex-text**
mode. The bug proposes restoring auto-detection of the simple text path, with
PR #47225 open and no published numbers.

Profile paint on CNN and franceinfo and attribute time to Skia shaping. Those
profiles are 34% and 44% style resolution respectively — text-heavy, main-thread
bound, exactly where forcing the complex path on every run is pure overhead. If
the slice is meaningful, backport and A/B; if not, we have cheaply killed a
theory. We need a different lever on CNN regardless, since
`WEBKIT_STYLE_SMART_RECONSTRUCT` is byte-identical inert there.

### 4. Re-check tile sizing against the seam fix — medium payoff, cheap

2.52 computes layer tile size differently depending on whether GPU rendering is
enabled. We run CPU rendering, and we carry a `ceil()`-rounding tile-edge seam fix
plus a low-res ladder that the same rounding affected. Confirm which branch of the
new sizing logic we land on and that the seam fix still holds — the sizing rule
changed underneath our patch.

### 5. Watch `BitmapTexture::copyFromExternalTexture()` — speculative

Bug [320746], filed 2026-07-31, unowned: WebProcess freezes in
`glCopyTexSubImage2D` during a **partial tile update**, on 2.52.4, on a plain GL
texture rather than a DMA-BUF or tiled allocation. Different GPU (etnaviv GC880),
but the signature — page visible, stops updating, stops responding — is close
enough to the compositor-futex class to be worth naming as a suspect instead of
re-deriving it from scratch.

### 6. Harvest bug [245783] as a slow-site corpus — medium payoff, cheap

The GTK slow-performance tracker aggregates 60+ dependent bugs with named
reproducers: Twitter / YouTube / Reddit / GitLab scrolling, Google Docs and GitLab
typing lag, blur-filter slowdowns, constant CPU on news sites, idle-tab memory.
Still NEW and unassigned as of July 2026. The maintainers' own stated methodology
is "benchmark on old hardware, because these only show up there" — our situation
exactly. This is a ready-made regression corpus for the bench harness, and more
honest than synthetic scores given what we know about instrument traps.

### 7. Upstream two of our fixes — strategic

The compositor futex / `CoordinatedPlatformLayer::m_lock` skip (33 stalls → 0 on a
5×5 A/B) has no upstream equivalent, and 2.52's "avoid blocking waiting for tile
painting" work is adjacent to it. Same for the tile-edge `ceil()` seam. Filing
both against the WPE component gets Igalia review and stops us carrying them
across every version bump — the patch stack is already 39 after consolidation.

## Two calibration notes

**The vsync cliff.** Chris Lord's fix (MotionMark 35 → 233) applied to exactly one
backend: Wayland, because it is the only one that fully implements vsync signals.
When a frame missed its budget, WPE waited for the *next* vsync before starting
again — a hard 60 → 30 drop rather than graceful degradation. Worth confirming
empirically that our hybris/Wayland path no longer does this. Both the fullscreen
judder and the low-res scroll degradation have frame-pacing signatures rather than
throughput deficits.

**The main-thread wheel ack is 50 ms upstream.** `EventDispatcher::wheelEvent()`
waits on `m_waitingForBeganEventCondition` with a 50 ms timeout, then falls back to
non-blocking. We ship `WEBKIT_TOUCH_ACK_TIMEOUT_MS=100`. Different code path, so
not a contradiction — but if 100 ms was chosen by feel, upstream's number is a
datapoint worth testing against.

## Coverage caveat

This covers the WPE WebKit and WebKitGTK Bugzilla components, the
WebPlatformForEmbedded issues, and the 2026 Igalia periodicals. It does **not**
exhaustively cover Layout-and-Rendering or JavaScriptCore, and outside the eight
bugs read in full, it is based on bug summaries rather than complete comment
threads.

[245783]: https://bugs.webkit.org/show_bug.cgi?id=245783
[287572]: https://bugs.webkit.org/show_bug.cgi?id=287572
[295019]: https://bugs.webkit.org/show_bug.cgi?id=295019
[306420]: https://bugs.webkit.org/show_bug.cgi?id=306420
[307135]: https://bugs.webkit.org/show_bug.cgi?id=307135
[314299]: https://bugs.webkit.org/show_bug.cgi?id=314299
[315687]: https://bugs.webkit.org/show_bug.cgi?id=315687
[316052]: https://bugs.webkit.org/show_bug.cgi?id=316052
[319685]: https://bugs.webkit.org/show_bug.cgi?id=319685
[320746]: https://bugs.webkit.org/show_bug.cgi?id=320746
