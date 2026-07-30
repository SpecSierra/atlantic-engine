> **Status: SHIPPED, one defect still open** — The raster-cost trigger shipped default-ON in build 625 (user-validated). Still open: the ladder measures `dy` in device px against thresholds written as page px, so on this dpr=3 device low-res engages at ~40 CSS px/s and checkerboard at ~267 CSS px/s. Read this before touching the scroll tier ladder or its benchmarks.

# INVESTIGATION — low-res-tiles-during-scroll trigger is the wrong metric, 2026-07-29

Build under test: **atlantic-browser 1.0.0.beta7-618.1 / wpewebkit2-2.52.5-618.1**
(Xperia 10 II; installed version verified before every measurement below).

User report: the low-res-during-scroll heuristic is keyed on scroll speed in
px/s, which "is not a good metric" — it fails to engage on heavy sites (which
need it) and engages too eagerly on light sites (which don't), giving a visible
blur-then-sharpen pop on every flick.

Code: `CoordinatedBackingStoreProxy::setVisibleRect()` / `updateIfNeeded()` in
`patches/webkit/webkit-lowres-tiles-during-scroll-env.patch` (+ the
`webkit-scrolltier-log-diagnostic.patch` and `webkit-lowres-tiles-cpu-path.patch`).

## CONFIRMED

### C1. The trigger is a 3-rung speed ladder sampled off visibleRect deltas
`setVisibleRect()` computes `speed = |dy| / dt` between consecutive visibleRect
updates and classifies into `ScrollTier::{None,LowRes,Checkerboard}` at 400 and
2500 px/s, holding the tier for `WEBKIT_CHECKERBOARD_SETTLE_MS` (default 300 ms).
Samples with `dt >= 0.2 s` are discarded outright. Verified against the patched
source actually built by CI
(`/opt/github-runner/cache/atlantic-build/sources/wpewebkit-2.52.5/Source/WebCore/platform/graphics/texmap/coordinated/CoordinatedBackingStoreProxy.cpp:495-515`)
and by confirming every related env string is present in the shipped device binary.

### C2. The engine's velocity estimate is 3.0x the true scroll velocity — DEVICE pixels measured against thresholds that read as page pixels
`light.html`, 15 s fling window. Engine's own `speed=` field
(`WEBKIT_SCROLLTIER_LOG=1`) vs per-rAF `window.scrollY` deltas sampled in-page:

| | n | p50 | p75 | p90 | p95 | max |
|---|---|---|---|---|---|---|
| page (ground truth) | 448 | 294 | 957 | 2056 | 2680 | 10000 |
| engine estimate | 440 | 872 | 2955 | 6320 | 7623 | 10486 |

Ratio **3.0x at p50, 3.1x at p90** — flat across the distribution, i.e. a scale
factor, not noise. `devicePixelRatio` is **3** on this device (innerWidth 360 CSS
px vs screen.width 1080 device px), confirmed via `atldbg eval`.

Combined with C4 (the shipped thresholds are the wrapper's 120/800, not the
binary's 400/2500), the effective thresholds in the units the user experiences:

| tier | shipped (device px/s) | effective (CSS px/s) |
|---|---|---|
| low-res | 120 | **40** |
| checkerboard | 800 | **267** |

**40 CSS px/s is barely moving** — a slow deliberate drag clears it. 267 CSS px/s
is a leisurely scroll, nowhere near a fling. This is the quantified cause of
"engages too eagerly": essentially *every* scroll gesture is classified as a
fling, and half of an ordinary flick is classified as needing the most aggressive
rung. Measured occupancy on a normal fling stimulus (p50 = 269 CSS px/s):

| | none (full-res) | low-res | checkerboard |
|---|---|---|---|
| predicted from page ground truth | 4% | 46% | 50% |
| engine's own decisions | 14% | 36% | 50% |

The two agree closely, which cross-validates both the harness and the reading of
the code. **Only ~4-14% of an ordinary scroll is rendered at full resolution.**

### C3. The trigger does not discriminate content cost at all
Five real touchscreen flicks per page (`WEBKIT_SCROLLTIER_LOG=1`), tier histogram
over armed samples:

| page | none | low-res | checkerboard | median speed |
|---|---|---|---|---|
| light (cheap tiles, idle main thread) | 5% | 40% | 55% | 976 |
| heavy (gradients+shadows, idle main thread) | 4% | 20% | 76% | 1927 |
| stall (cheap tiles, 45 ms task every 60 ms) | 2% | 34% | 64% | 1421 |

All three get essentially the same aggressive treatment despite raster cost
differing by design. The tier is a function of the *gesture*, not the *page*.
The inversion the user described is visible in the raw data: the light page
reached a **higher** peak velocity (21436 px/s) than the heavy page (9460 px/s) —
cheap pages scroll faster, so the metric degrades them harder.

### C4. The thresholds actually in force come from the launcher wrapper, not the binary — and are 3-4x lower than the source suggests
`/opt/wpe-sfos/libexec/atlantic/runtime-common.sh:471-474` exports, as
`${VAR:-default}`:

```sh
export WEBKIT_LOWRES_TILE_SCALE="${WEBKIT_LOWRES_TILE_SCALE:-0.3}"
export WEBKIT_LOWRES_SCROLL_SPEED="${WEBKIT_LOWRES_SCROLL_SPEED:-120}"      # binary default: 400
export WEBKIT_CHECKERBOARD_DURING_SCROLL="${WEBKIT_CHECKERBOARD_DURING_SCROLL:-800}"  # binary default: 2500
export WEBKIT_CHECKERBOARD_SETTLE_MS="${WEBKIT_CHECKERBOARD_SETTLE_MS:-200}" # binary default: 300
```

Verified against the live WebProcess `/proc/<pid>/environ`. Reasoning from
`CoordinatedBackingStoreProxy.cpp` alone is therefore wrong by 3.3x (low-res) and
3.1x (checkerboard). This is the same class of trap recorded for the startup
work — *the wrapper env overrides the binary defaults*.

Two further defects in that block:
- **The comment contradicts the code.** It states "The checkerboard (top) rung is
  DISABLED here (=0); set it to e.g. 2500 to re-enable" — the line directly below
  sets it to **800**. The most aggressive rung is on, at a threshold 3x lower than
  the value the comment suggests for re-enabling it.
- **`WEBKIT_LOWRES_SCROLL_SPEED` arms the ladder even when low-res tiles are
  disabled.** `lowResScrollSpeedThreshold()` honours an explicitly-set speed
  without checking `lowResTilesEnabled()`, so setting `WEBKIT_LOWRES_TILE_SCALE=1.0`
  stops low-res *painting* but the tier still arms (and still suppresses the
  sharpen pass, and still gates the checkerboard branch). This made the control
  arm of the first A/B report "85% degraded"; it was arming, not painting.

## RULED OUT

### R1. "The `dt < 0.2` gate starves the trigger" — **RETRACTED, see C11. It was right.**
My leading hypothesis, and the one the existing diagnostic patch header suspected
("no longer engages on device (build 480) … suspected: visibleRect updates
arriving with dtSec >= 0.2"). Measured rejection rates:

| page | ARM samples | SKIP (gate) | reject rate |
|---|---|---|---|
| light | 279 | 5 | 1.8% |
| heavy | 181 | 6 | 3.2% |
| stall | 117 | 5 | 4.1% |

2-4% on every page, including one deliberately stalling its main thread with a
45 ms task every 60 ms. **The gate does not starve the trigger in build 618.**
Reason: independent scrolling / APZ (`WEBKIT_INDEPENDENT_SCROLL`, shipped 540)
drives visibleRect updates from the scrolling thread's own 16 ms timer, so sample
cadence is decoupled from main-thread health. The build-480 symptom in the patch
header was fixed somewhere between 480 and 618; that note is stale.

**This conclusion was wrong.** It rests entirely on synthetic pages, which have
ONE compositing layer. On a real multi-layer page the same gate rejects **100%**
of samples — see C11. The measurement above is accurate; the generalisation from
it was not.

### R2. "The feature no longer engages at all" (stale claim in the diagnostic patch header)
Disproven immediately: 279 ARM lines across 5 flicks on the light page, tiers
actively assigned. It engages, and then some.

### C5. On a cheap page, low-res tiles are not merely useless — they cost performance
Interleaved (ABAB) 4x2 A/B on `light.html`, fling stimulus, 10 s windows,
checkerboard disabled so only the low-res rung varies:

| arm | fps | p50 | p95 | jank | raster CPU |
|---|---|---|---|---|---|
| `LOWRES_TILE_SCALE=1.0` (off) | **51.6** | 18.0 | 26.5 ms | 1.3% | 25.3% |
| `LOWRES_TILE_SCALE=0.3` (on) | **50.0** | 18.0 | 28.0 ms | 3.0% | 28.2% |
| delta | **-3.1%** | 0 | **+5.7%** | **+1.7 pp** | **+11.0%** |

Per-arm fps spread was 51.4-51.7 and 50.0-50.1 (n=4 each), so the 1.6 fps delta is
~5x the noise floor — comfortably real. Low-res on a cheap page is a **loss on
every axis**: fewer frames, worse tail latency, more jank, and 11% *more* raster
CPU. That is the expected sign once the page was never raster-bound: painting a
tile small, upscaling it at composite, then repainting it full-res at settle is
strictly more total work than painting it once.

So the user's "too eagerly engage" complaint has **no upside to trade against** on
light pages — it costs both image quality and performance. Combined with C4 (it
engages above 40 CSS px/s) this is the dominant user-visible defect.

### C6. On a raster-bound page the SAME knob is a large win — the mechanism is sound, the trigger is not
Same harness, same stimulus, `heavy.html` (65-69% raster CPU vs light's 25%, i.e.
genuinely paint-limited):

| arm | fps | p50 | p95 | jank | raster CPU |
|---|---|---|---|---|---|
| `LOWRES_TILE_SCALE=1.0` (off) | 36.4 | 18.0 | **77.0 ms** | 13.3% | 69.0% |
| `LOWRES_TILE_SCALE=0.3` (on) | 38.2 | 18.5 | **47.5 ms** | 12.1% | 65.2% |
| delta | +5.2% | — | **-38.3%** | -1.2 pp | -5.4% |

Per-arm fps spread 36.0-36.4 vs 38.1-38.8 (n=4), non-overlapping. The win is in
the **tail**: p95 frame time drops 38%, which is the stutter actually perceived
mid-fling; mean fps moves comparatively little because it is display-rate bound.

The ON arm also scrolled ~26% faster (velocity p50 184 vs 146 CSS px/s), so it
exposed *more* tiles per second — the confound works against the ON arm, making
this a conservative estimate of the effect.

**Conclusion — this is the crux of the whole investigation.** The identical knob,
unchanged, measured on two pages:

| page | p95 change | raster CPU change |
|---|---|---|
| heavy (raster-bound) | **-38.3%** | -5.4% |
| light (not raster-bound) | **+5.7%** | +11.0% |

The mechanism pays off precisely when raster is the bottleneck and costs real
performance precisely when it is not. The current trigger fires above 40 CSS px/s
on both and **cannot distinguish them** — it does not measure the variable that
determines even the *sign* of the outcome.

This also settles the redesign-vs-retune question: re-calibrating thresholds (O4)
reduces false engagement on light pages, but reduces true engagement on heavy
pages by exactly the same rule, giving up the 38% tail win. A velocity threshold
can only trade one against the other; a cost/budget trigger separates them. The
proposed controller (raster-cost EWMA vs frame budget, scale derived from
overshoot) is therefore justified on measurement, not on principle.

### C7 (O4 answered). Re-calibration alone does NOT work — it gives up heavy-page benefit without fixing the light-page cost
Three arms, interleaved, 3 reps each, on both pages. `off-baseline` sets
`WEBKIT_LOWRES_SCROLL_SPEED=99999` as well as `TILE_SCALE=1.0` so the ladder
genuinely never arms (confirmed `armed=0%`); the earlier two-arm A/B could not do
this, see C4.

**Light page** (not raster-bound):

| arm | fps | p95 | jank | raster CPU | armed |
|---|---|---|---|---|---|
| off-baseline | 51.0 | **27.0 ms** | 1.3% | 25.3% | 0% |
| stock 120/800 | 51.4 | 29.0 ms | 3.4% | 26.5% | 85.5% |
| recal 1200/7500 | 50.4 | **29.0 ms** | 3.4% | 26.5% | **43.0%** |

Re-calibration **halved engagement (85.5% -> 43.0%) and changed the penalty not
at all** — p95, jank and raster CPU identical to stock. The light-page cost is
therefore *not* proportional to how often the tier is armed: it is incurred as
soon as the feature engages at all during a gesture, because the sharpen-at-rest
full-res repaint happens once per engagement regardless of its duration.

**Heavy page** (raster-bound), corrected run with the time-anchored driver:

| arm | fps | p95 | jank | armed |
|---|---|---|---|---|
| off-baseline | 38.9 | **76.0 ms** | 12.4% | 0% |
| stock 120/800 | 39.8 | **44.0 ms (-42.1%)** | 9.5% | 88.0% |
| recal 1200/7500 | 39.1 | **53.0 ms (-30.3%)** | 12.4% | 46.3% |

Re-calibration **gives up roughly a quarter of the tail win** (-42% -> -30%) and
returns jank to baseline (12.4% vs stock 9.5%). Both heavy runs agree: stock
-40.5% / -42.1%, recal -36.5% / -30.3%.

**Conclusion: the O4 interim ship candidate is not viable.** Raising the
thresholds costs real benefit on the pages that need it while delivering no
measurable improvement on the pages that don't — the predicted behaviour of a
single scalar threshold applied to two populations that differ along a *different*
axis, now measured rather than argued. It removes the "just re-tune it" option and
leaves the cost-aware trigger as the only design that separates the cases.

Secondary finding: partial engagement (43-46% armed) is on some metrics *worse*
than either extreme — heavy-page jank returns to baseline while raster CPU stays
elevated. Consistent with transition cost: every engage/disengage cycle triggers a
whole-tile full-res sharpen repaint, so a trigger hovering near its threshold pays
that repeatedly. **The controller needs asymmetric hysteresis, not just a better
threshold.**

### C8 (O2 answered). Raster cost separates the two pages by 23.7x — the cost-based trigger is validated
Build **620** (instrumentation `webkit-tile-raster-cost-instrumentation.patch`,
presence verified in the shipped `libWPEWebKit-2.0.so.1.9.9` before measuring).
Low-res fully disabled for the run (`TILE_SCALE=1.0` **and**
`LOWRES_SCROLL_SPEED=99999`) so the figures reflect content cost, not the
controller's own decisions. Identical 256x256 (65536 px) tiles on both pages:

| page | raster ns/px p50 | ms per tile p50 | settled EWMA |
|---|---|---|---|
| light | **11.9** | **0.8 ms** | 22.5 ns/px |
| heavy | **282.3** | **13.0 ms** | 353.9 ns/px |

**Spread 23.7x on p50** (15.7x on the settled EWMA, which is what a controller
would actually read). The decision rule was fixed before the measurement: <2x
would have killed the redesign, 10x+ validates it. It clears the bar by 2x.

The budget arithmetic this enables, at a 16.6 ms frame budget:

| page | cost/tile | tiles affordable per frame | 3 newly-exposed tiles |
|---|---|---|---|
| light | 0.8 ms | ~20 | 2.4 ms = **0.15x budget** -> do not degrade |
| heavy | 13.0 ms | 1.3 | 39 ms = **2.35x budget** -> degrade |

That is the discriminator the speed trigger cannot express: the same 3-tile
exposure is 0.15x budget on one page and 2.35x on the other, while both pages
produce identical scroll velocities. Note also that a cost-derived scale would be
*gentler* than the current fixed 0.3x — 1/sqrt(2.35) = 0.65, which lands heavy
right at budget while being far less visible than 0.3x.

Caveat: logging is throttled to one line per 32 tiles, so n=16/13 represents
~512/~416 tiles. Adequate for a distribution estimate; the p90 for light (246.5
ns/px) shows cost varies within a page too, which is why the controller must use
a moving average rather than a single sample.

### C9. The cost trigger works, but does NOT meet the bar I set — it is better than speed on light, slightly worse on heavy
Build **621** (`webkit-lowres-cost-trigger.patch`, presence verified in the
shipped lib). Pass/fail was fixed before any data: heavy must keep >=-30% p95 vs
baseline; light must *return to baseline*.

**Two calibration errors found by the smoke test, before any A/B was run:**

1. `costCheckerboardOvershoot=11` was wrong. My reasoning was "at the 0.3 floor
   low-res recovers only ~11x, so past that even floor-scale misses the frame ->
   checkerboard". The conclusion does not follow: floor-scale low-res still
   removes 11x of work *and keeps content visible*, while checkerboard shows
   blank bands. On heavy it pinned `tier=2` permanently (overshoot 20.4) giving
   p95 72 ms / jank 16% / worst frame 645 ms — worse than baseline AND than the
   speed trigger. Fix: default the rung off; the scale floor is the ceiling on
   degradation.
2. Per-pass accounting overstates overshoot. `px=604160` is ~9 tiles, a whole
   layer flush whose raster spreads over 2 SkiaCPUWorker threads and several
   frames; comparing that to a single-frame 11 ms budget inflates overshoot.
   Corrected by raising the budget (env-tunable, no rebuild — the reason those
   were env knobs).

**Final matched comparison** (checkerboard off in every arm, so only the trigger
differs; `cost` at `BUDGET_MS=33`):

| page | arm | fps | p95 | jank | raster CPU |
|---|---|---|---|---|---|
| heavy | off-baseline | 38.8 | 79.0 ms | 12.6% | 61.4% |
| heavy | speed-lowres | 37.6 | **45.0 ms (-43.0%)** | 12.5% | 68.1% |
| heavy | **cost-b33** | 38.5 | **49.0 ms (-38.0%)** | 13.9% | 72.2% |
| light | off-baseline | 51.5 | 26.0 ms | **1.3%** | **26.0%** |
| light | speed-lowres | 49.9 | 28.5 ms (+5.6%) | 3.2% | 28.6% (+8.3%) |
| light | **cost-b22/40** | 50.9 | 27.0 ms (+3.8%) | **2.1%** | **25.7% (-1.2%)** |

**Verdict against the pre-registered rule:**
- heavy **PASS** (-38% clears the -30% bar) but 5 points behind the speed trigger.
- light **FAIL** — it does not return to baseline. It halves the penalty
  (jank 3.2% -> 2.1%, p95 +5.6% -> +3.8%) and fully recovers the raster-CPU
  regression (+8.3% -> -1.2%), but baseline jank is 1.3%.

So the cost trigger **strictly dominates the speed trigger on the light page and
is slightly behind it on the heavy page** — a real improvement, but not the clean
separation the 23.7x cost spread promised, and not what I said would count as
success. Reporting it as a win would be moving the goalposts.

**Why it does not separate cleanly, and what the next lever is.** At
`BUDGET_MS=11` the light page computed overshoot 1.24 and engaged at scale 0.90 —
a scale that saves ~19% of band raster but still pays a **full-res sharpen
repaint of every degraded tile** afterwards. Net negative. Raising the budget
stops most marginal engagements, but whenever it *does* engage the fixed
overhead is paid in full. This is C7's finding restated: the penalty is per
*engagement*, not per unit of degradation.

The remaining lever is therefore not the trigger but the **cost of engaging** —
the unconditional whole-tile full-res sharpen pass. Candidates: sharpen only
tiles intersecting the viewport, sharpen progressively over several frames, or
skip the sharpen entirely for tiles whose derived scale was above ~0.8 (visually
indistinguishable, so not worth a repaint). Until that is addressed, *any*
trigger — speed or cost — carries a floor of ~0.8 pp jank on cheap pages.

**Recommendation: keep `WEBKIT_LOWRES_COST_TRIGGER` but leave it OFF by default.**
It is not inert and not harmful, but it does not yet earn a default flip: it
trades 5 points of heavy-page tail for half the light-page penalty. Revisit after
the sharpen-overhead work, which should improve both triggers and may change
which one wins.

### Tooling gap found in C9
`ab.py`'s `tier_armed` column reads `[scrolltier] ARM` lines and so reports 0%
for cost-trigger arms, which emit `[costtier]` instead. The engagement figures
for cost arms in the tables above come from the raw `[costtier]` trace, not from
that column. Fix before the next controller experiment, or an arm that silently
never engages will look identical to one that engages perfectly.

### C10. Device testing: the cost trigger degraded STATIONARY pages — root cause and fix
Reported by the user on real sites: "black boxes/lines all over the pages" and
"the low res shows too early". Reproduced on franceinfo.fr (build 621); the
synthetic single-layer `heavy.html` could NOT reproduce it.

**Cause: no scroll-motion gate.** The speed ladder could only ever arm inside the
`dy != 0` branch of `setVisibleRect`, so it was implicitly scroll-gated. The cost
trigger evaluates on every layer flush and lost that condition, engaging during
load and on idle repaints. Measured on an idle franceinfo: **99 layer proxies,
284 passes pinned at the 0.3 scale floor, with nothing scrolling.**

**The "black lines" are a LATENT PRE-EXISTING BUG that this exposed.**
`lowResBufferSize()` rounds up with `ceil()`: a 256 px tile at 0.3 gives a 77 px
buffer while content paints at exactly 0.3, filling 76.8 of 77 texels. The
unpainted fractional column upscales ~3.3x into a dark seam at every tile edge.
Transient degradation hides it; held at rest it becomes a permanent dark GRID.
**This bug is in the shipped speed-ladder path too** — it is simply invisible
there because degradation always ends. Worth its own fix (floor() instead of
ceil(), or a 1px paint inset); tracked as O5.

**Fixes (build 622):** scroll gate (`WEBKIT_LOWRES_COST_MOTION_MS`, 120 ms);
immediate disengage when motion stops, bypassing hysteresis so tiles sharpen at
rest; engage margin (`WEBKIT_LOWRES_COST_ENGAGE_X`, 2.0) so it never engages
above scale ~0.71.

**Verified on franceinfo (622):** idle = 440/440 passes `scrolling=0`, `tier=0`,
screenshot clean (no grid, no blur). During 5 real flicks = engages only at
overshoot >= 2.0, at derived scales **0.63-0.70** — far gentler than the fixed
0.3 the speed ladder uses.

Lesson: a condition removed during a refactor was load-bearing in a way no
benchmark caught, because every automated measurement scrolls. **Nothing in the
harness ever tested the idle case.** Add an idle-render check to the bench.

### O5 (new). Fix the low-res tile-edge seam
`lowResBufferSize()` ceil() rounding leaves an unpainted fractional texel column
that upscales into a visible seam at tile edges. Affects the shipped speed ladder
as well as the cost trigger. Independent of which trigger wins.

### O6 (new). The sharpen pass is the remaining performance lever
When degradation ends, EVERY degraded tile is invalidated whole and repainted at
full resolution — including prepaint-cushion tiles never looked at. This single
behaviour explains three separate measurements: C7 (halving engagement changed
the light penalty by nothing), the 0.90-scale engagement still paying the full
+1.9pp jank, and partial engagement being worse than either extreme. Candidates,
cheapest first: skip the sharpen when scale was >= ~0.8 (visually identical);
sharpen only viewport-intersecting tiles; spread it over several frames.
**Improves the speed ladder too**, so it pays off whichever trigger ships, and
may narrow the cost trigger's 5-point heavy-page deficit.

### C11. On a REAL page the speed ladder never engages at all — R1 retracted
franceinfo.fr, build 623, `WEBKIT_LOWRES_COST_TRIGGER=0`, low-res forced on
(`LOWRES_SCROLL_SPEED=2`):

```
ARM: 0     SKIP: 536     PAINT-DECIDE: 0
```

**Every eligible sample is discarded by the `dt < 0.2` gate.** So the shipped
low-res feature does nothing on franceinfo — and by extension on any comparably
layered real site.

Cause: **per-layer sampling sparsity.** franceinfo has ~99 layer proxies, each
with its own `m_lastScrollSampleTime`. Any single layer's `setVisibleRect` fires
only when THAT layer changes, so its dt routinely exceeds 200 ms. The synthetic
pages have one layer, which gets every update, so dt stays small and the gate
rejects only 2-4% — which is why R1 concluded the gate was harmless. The
generalisation was invalid; the stale suspicion in the diagnostic patch header
(build 480) was correct all along.

**Consequences, and they are large:**
- The **-42% p95 heavy-page win (C6/C7) was measured on a single-layer synthetic
  page** where the dy-path works. It does not demonstrate any benefit on real
  sites, because the feature never engages there.
- The seams the user reported came from the **cost trigger** (the only trigger
  that engages on real pages), not from the speed ladder.
- Any future A/B of a *speed*-based arm on a real page is measuring nothing.
  **The bench must include a multi-layer page** (`multilayer.html`) — a
  single-layer page cannot exercise the arming path a real site takes.

### C12. The cost trigger's scroll gate had the identical per-layer defect
Same root cause, my own code: `m_lastScrollMotionTime` was per-proxy, so on
franceinfo **964 of 964 samples reported `scrolling=0`** while the page was being
flung, leaving the trigger inert. A layer whose `updateIfNeeded` runs less often
than the motion window never sees itself as scrolling, and a fixed header never
moves at all.

Whether the user is scrolling is a property of the **page**, not of a layer.
Fixed by recording motion process-wide (relaxed atomic), written by whichever
layer observes movement and read by all of them; window widened 120 -> 250 ms.

Two bugs from one wrong assumption, so it is worth stating as a rule:
**anything derived from how often a single backing store is updated is unsound on
a real page.** Per-layer update cadence is a function of layer count and content
churn, not of user input.

### C13. Calibration note: budget 33 + engage margin 2.0 double-counted
Raising the budget to 33 ms was done *before* the engage margin existed; with
both, overshoot on franceinfo peaks at 0.89 and never reaches the 2.0 bar. The
margin alone already excludes the light page (overshoot 1.24 at budget 11), so
budget should return to 11. Not yet re-verified — the gate fix (C12) had to land
first, since nothing engaged at all before it.

### C14 (O6 answered). Scoping the sharpen pass to the viewport wins on every metric
`WEBKIT_LOWRES_SHARPEN_VIEWPORT_ONLY=1`, build 626, cost trigger active, 4 reps
interleaved. Instrument checked first: **531 tiles sharpened vs 2172 deferred —
80% of the repaint work avoided**, with one layer showing `sharpened=0
deferred=50` (every low-res tile off-screen).

| | heavy | multilayer |
|---|---|---|
| fps | 37.1 -> **39.3** (+5.9%) | 29.2 -> **30.9** (+6.0%) |
| p95 | 50.0 -> **48.5** (-3.0%) | 60.5 -> **54.0** (-10.7%) |
| jank | 13.9% -> 13.5% | 21.8% -> **18.1%** (-3.7 pp) |
| raster CPU | 75.8% -> **70.2%** (-7.4%) | 80.8% -> **77.0%** (-4.7%) |

Per-arm fps spreads are non-overlapping on both pages (36.9-37.2 vs 38.8-39.4;
29.1-29.6 vs 30.5-31.2), so the deltas clear the noise floor. Meets the
pre-registered PASS rule: improves p95 and jank beyond spread on both pages, with
no regression on any metric.

**Caveat, same class as C6/C7:** `vel_p50` differs between arms (196 vs 112 on
heavy, 185 vs 157 on multilayer) because `scrollY` read-back lags when the
compositor is behind, so the arms did not traverse identical ground. The
viewport arm scrolled *less*, which means *less* work, so the measured magnitude
is probably optimistic. What is NOT confounded is the mechanism: the 531 vs 2172
tile count is a direct engine-side measurement independent of input fidelity, and
raster CPU falls in the direction that count predicts. There is also no plausible
mechanism by which repainting fewer OFF-SCREEN tiles makes rendering worse.

Conclusion: the effect is real and the direction certain; the exact magnitude is
not. Recommend enabling, subject to user validation that deferred cushion tiles
never appear soft on screen (the 512 px margin plus re-sharpening as the viewport
advances should prevent it, but that is a visual property no benchmark here
measures).

### Measurement limitation carried by C6/C7 (heavy page)
`vel_p50` differs across arms on the heavy page even with the time-anchored
driver (91 / 350 / 318 px/s) because `window.scrollY` read-back lags when the
compositor is behind — the slow arm's *sampled* velocity under-reports the motion
actually requested. Consequences:

- **raster-CPU comparisons across heavy-page arms are not usable** (the faster arm
  genuinely does more scrolling work; the sign of the stock-vs-baseline raster
  delta flipped between the two heavy runs for exactly this reason);
- **p95 comparisons remain valid and conservative** — the degraded arms scroll
  *further*, i.e. expose more tiles, and still post better tail latency.

Fixing this properly needs a scroll driver that verifies achieved position
against requested position, or velocity taken from the scrolling tree rather than
from `scrollY`. Not required for the conclusions above; required before quoting
any raster-CPU number on a raster-bound page.

## OPEN

- **O2 (partly answered by C6).** Direct per-tile raster cost, light vs heavy.
  The *proxy* signal is already decisive — raster-thread CPU is 25% vs 69% for
  identical scroll geometry, a 2.8x spread, and the sign of the low-res outcome
  flips between them. What is still needed for the controller itself is the
  per-tile timing hook (EWMA ms/tile in `SkiaPaintingEngine::paint`/`replay`), so
  the trigger has a cost signal available *in the engine at decision time*
  rather than only to an external observer. Needs an engine patch + CI build.
- **O3.** Is the 3x a plain units bug, or were the thresholds chosen empirically
  *in* device px? The checkerboard comment says "device px/s" explicitly; the
  low-res comment gives no units and describes the ladder as "slow = full res,
  quick = low-res, ultra-fast = checkerboard", which 40/267 CSS px/s plainly is
  not. Either way the shipped calibration does not deliver the documented
  intent.
- ~~**O4**~~ — **answered, see C7: re-calibration is not viable.** Original text:
  Re-calibration A/B: raise
  the wrapper thresholds so the *effective* CSS values match the documented intent
  (e.g. low-res 1200 device px/s = 400 CSS px/s, checkerboard 7500 = 2500 CSS
  px/s) and re-run **both** arms of the two-page bench plus a subjective
  sharpen-pop check. Post-C6 this is no longer a test of "mistuned vs wrong
  metric" — C6 already showed a single threshold cannot separate the two cases.
  It is a test of *how much of the heavy-page 38% tail win survives* a
  calibration conservative enough to stop degrading light pages. That number is
  the value the cost-based controller has to beat, and it is the honest interim
  ship candidate if the controller slips.

**Standard regression test for any trigger change from here on:** the light/heavy
pair must be run *together*. A trigger change that improves one while silently
giving up the other is the exact failure this investigation exists to prevent —
and a single-page A/B cannot see it.

## Tooling notes (gotchas hit here)

- **busybox `grep` is unreliable on the 167 MB `libWPEWebKit-2.0.so.1`.**
  `grep -c -F` returned 0 for strings that are definitely present and `grep -ao`
  with a character class silently missed matches — this nearly produced a false
  "the patch is not in the build" conclusion. Use
  `tr -c "\40-\176" "\n" < "$LIB" | grep "^WEBKIT_"`.
- **`atldbg render --scroll` could not have observed any of this.** Its legacy
  stimulus was a constant `y += 24` per rAF (~1412 CSS px/s measured): never
  accelerates, never settles. Against the thresholds actually in force that is
  **100% checkerboard / 0% full-res** — it was measuring tiles that were never
  rasterized, so no paint-path or tier-logic change could register. Replaced —
  see `scripts/devtools/atldbg/scroll.py` and `--scroll-profile`.
- **Never trust the stimulus you think you produced.** The 3x estimator error
  (C2) was only visible because the page measures its own scroll velocity
  independently of whatever the driver intended.
- **Never read a threshold out of the source.** The shipped value came from the
  launcher wrapper (C4) and was 3-4x lower than the compiled default, and the
  wrapper's own comment disagreed with its own code. `atldbg render --scroll` now
  reads the thresholds in force from the live WebProcess `/proc/<pid>/environ`
  and prints them in both device and CSS px, with their source.

---
---
