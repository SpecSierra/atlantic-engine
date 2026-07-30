# Benchmarking and A/B methodology

Engine changes ship behind a `WEBKIT_*` env toggle, so an A/B needs no rebuild:
`atldbg launch --env K=V` (repeatable) + `atldbg render --scroll`. Device recipes:
[DEVICE.md](DEVICE.md).

**Rule 0 — prove the instrument can move before measuring.** State the expected
effect size and the noise floor first; if the signal is below the floor, redesign
the experiment. Two changes were nearly "validated" against benchmarks that could
not have registered them.

## Shipping rule

Flag defaulted **OFF** → interleaved on-device A/B, 5 runs off / 5 on, same page
and build → report mean, spread, and whether the delta clears the noise floor.
Flip the default only if it does. If inert, say so and revert.

## Pick the scroll stimulus deliberately

The engine degrades rendering on a velocity ladder (full-res → low-res tiles →
checkerboard), so the shape of the scroll decides which code path you measure.
`atldbg render --scroll` takes `--scroll-profile`:

| Profile | Motion | Use for |
|---|---|---|
| `fling` (default) | impulse + kinetic decay + dwell at rest, repeated; peak via `--scroll-speed` | almost everything — crosses every threshold and reaches true rest |
| `touch` | real flicks via `/dev/input/event2`, through the UIProcess touch handler and APZ | confirming a change survives the real input path |
| `ramp` | legacy `y += 24` per rAF, ~1440 px/s constant | reproducing pre-2026-07 numbers only |

To attribute a change to the raster/paint path, disable both rungs:

```sh
--env WEBKIT_LOWRES_TILE_SCALE=1.0 --env WEBKIT_CHECKERBOARD_DURING_SCROLL=0
```

That is a stress test (full-res paint at fling speed), not a realistic scroll —
never quote its fps as user-facing.

- `WEBKIT_LOWRES_SCROLL_SPEED` arms the ladder even when `WEBKIT_LOWRES_TILE_SCALE=1.0`
  has disabled low-res painting, so the "low-res off" arm still reports the tier as
  engaged. The scale alone is not a clean control.
- **Historical trap** (fixed 2026-07-29): `--scroll` was `ramp` unconditionally,
  which sits at 100% checkerboard / 0% full-res, so it measured tiles that were
  never rasterized. Tell: 24 × 4.3 MP images scored 54.7 fps / 1% jank, *better*
  than text-only MDN at 11.8 fps / 76% jank. `render` now prints the velocity
  distribution and implied tier occupancy, and warns when a run never reaches
  full-res.

## Measure the stimulus; never assume it

`WEBKIT_SCROLLTIER_LOG=1` makes `render` print the engine's tier decisions next to
in-page ground truth. On build 618 they disagree by **3.0× — exactly the device
pixel ratio**: the ladder compares `dy` in device px against thresholds written as
page px. With the shipped 120 / 800 device px/s, low-res engages at 40 CSS px/s and
checkerboard at 267, so only ~4–14% of a normal scroll renders full-res. Invisible
for months because the old benchmark could not see it —
[investigations/scroll-tier-velocity-metric.md](investigations/scroll-tier-velocity-metric.md).

**dpr = 3 on this device**, and it applies to every size-derived estimate: glyph
strike memory, ImageBuffer sizes, drawn-vs-natural image scale, velocity thresholds.

## Read tuning values from the device, not the source

| Layer | low-res speed | checkerboard | settle |
|---|---|---|---|
| binary fallback (`CoordinatedBackingStoreProxy.cpp`) | 400 | 2500 | 300 ms |
| **shipped wrapper** (`deploy/runtime-common.sh`) | **120** | **800** | **200 ms** |

The wrapper wins (`${VAR:-default}`), so conclusions reasoned from the C++ are off
by 3–4×; the wrapper's own comment is stale (claims checkerboard is disabled on the
line above setting it to 800). `atldbg render --scroll` prints what is in force.
Confirm against the live process:

```sh
$SSH 'P=$(pgrep -f "WPEWebProces[s]" | head -1); tr "\0" "\n" < /proc/$P/environ | grep WEBKIT_'
```

## Two knobs that measure zero if benched naively

**MSAA is canvas-only.** `WEBKIT_SKIA_ENABLE_CPU_RENDERING=1` (auto-selected on the
Adreno 610 stack) calls `setCanUseAcceleratedBuffers(false)`, so GPU tile surfaces,
general accelerated `ImageBuffer`, and the Cocoa-only `HAVE(IOSURFACE)` path never
see `WEBKIT_SKIA_MSAA_SAMPLE_COUNT`. Only `ImageBufferSkiaAcceleratedBackend` does,
because `RenderingPurpose::Canvas` is exempt from the CPU-rendering gate. Bench it
on a canvas page. (Turning MSAA off is an 8× canvas regression — never retry.)

**Skia glyph cache** — took three attempts to bench:

- an article uses ~6–10 strikes (~200 KB) and never overflows even the stock 2 MB;
  the page needs many family/size/weight combinations;
- interleave the sizes — ascending order keeps the *instantaneous* working set tiny
  because neighbouring paragraphs share a strike;
- glyphs rasterize at device px, so strike memory is 9× the CSS estimate. An 88 px
  CSS font is one ~6.3 MB strike, bigger than any candidate limit, so every arm
  thrashes equally and returns identical numbers. Bench body text at 11–27 px CSS
  (100–600 KB per strike), which straddles the 2 MB and 8 MB limits.

## Bracket the tuned value, don't just A/B it

`stock vs shipped` cannot separate "knob does nothing" from "shipped value is too
small". Add a generous third arm (e.g. 2 / 8 / 32 MB): only the large arm moving
means the mechanism is real and the value mistuned; all three flat means the knob
is inert and the patch should be reverted.

## Harness rules

- **Interleave (ABAB), never block (AABB)** — thermal drift then hits every arm
  equally.
- **Assert exactly one browser instance per run**, discard otherwise (D-Bus
  activation can launch a second one — see [DEVICE.md](DEVICE.md)).
- **Prefer a local `file://` bench** — no network variance; `file:///home/defaultuser/…`
  works under sailjail. Verify it rendered with a screenshot first.
- **Take a second, independent signal** — fps saturates at the display rate;
  raster-thread CPU (`Skia*` threads in `render`) still moves.
- **Check units and process identity** before reporting (MB vs KB; not a prewarmed
  or zombie WebProcess).
- **`pgrep -f`/`pkill -f` match your own command line.** Bracket-escape (`foo[.]py`),
  and never chain a `pkill` with the run you are starting — the shell's argv
  contains the literal name either way.
- Kill any manual `-L 9224` tunnel before `atldbg`; it opens its own.

## Durable harnesses

| Path | Contents |
|---|---|
| `scripts/devtools/scrollbench/` | `gen.py` (bench pages of identical geometry varying only raster cost and main-thread health), `ab.py` (interleaved runs, medians + spread), `estcheck.py` (engine velocity estimate vs ground truth — this found the 3.0× dpr error) |
| `scripts/devtools/videobench/` | fullscreen video arms (`arm.sh`, `ab.sh`, `ab_fastpath.sh`), frame-trace capture (`cap.sh`), RSS slope, `tsample*.py` samplers |

## Investigation log

Keep a live `INVESTIGATION.md` while working: **CONFIRMED** (fact + the measurement
that proved it), **RULED OUT** (hypothesis + the evidence that killed it), **OPEN**
(next cheapest experiment). Update it as you go, mark guesses as guesses, and move
concluded logs to `docs/investigations/` with a status header.
