# scrollbench — controlled bench pages + interleaved A/B for scroll/raster work

Dev-only helpers (not part of any build or RPM) for measuring the scroll
degradation ladder — low-res tiles, checkerboard, tile upload budget — on the
SFOS dev device. Built for the 2026-07-29 investigation into the low-res trigger;
see `INVESTIGATION.md` on the build host.

## Bench pages (`gen.py`)

Three pages of **identical geometry** (same height, same scrollable length, same
paragraph count) that vary only in the two factors the px/s trigger conflates:

| Page | Raster cost per tile | Main thread | Expectation |
|------|---------------------|-------------|-------------|
| `light.html` | cheap (flat bg, plain text) | idle | low-res should NOT engage |
| `heavy.html` | expensive (gradient + box-shadow blur + text-shadow, no JS) | idle | low-res SHOULD engage |
| `stall.html` | cheap | 45 ms task every 60 ms | isolates the `dt<0.2` sampling gate |

Because scroll geometry is held constant, any difference in tier behaviour is
attributable to content cost or main-thread health — never to how far you
scrolled. Each page also carries an in-page velocity sampler (`window.__bench`).

**Always run `light` and `heavy` together.** Measured on build 618, the identical
`WEBKIT_LOWRES_TILE_SCALE=0.3` knob is worth **−38% p95 frame time** on `heavy`
(raster-bound, 69% raster CPU) and **+5.7% p95 / +11% raster CPU** on `light`
(not raster-bound, 25%). A trigger change that improves one while silently giving
up the other is the exact failure mode this bench exists to catch, and a
single-page A/B cannot see it.

```sh
python3 gen.py
sshpass -p root scp -P 2222 -o StrictHostKeyChecking=no \
    light.html heavy.html stall.html defaultuser@localhost:/home/defaultuser/
```

`file:///home/defaultuser/...` loads fine under sailjail, and a local page
removes network variance from the measurement.

## Interleaved A/B (`ab.py`)

```sh
python3 ab.py light-ab.json
```

Spec is JSON: `url`, `seconds`, `reps`, `profile` (`fling`/`touch`/`ramp`),
`speed`, and an `arms` list of `{label, env}`. It relaunches the browser per arm
so process-wide env actually applies, and follows the harness rules from the
build-server README:

- **arms are interleaved (ABAB, never AABB)** so thermal drift hits every arm equally;
- exactly one browser instance is asserted per run (`wait_for_ui_name` guards the
  D-Bus-activation trap that silently starts a second browser);
- **fps is not the only signal** — raster-thread CPU is collected alongside,
  because fps saturates at the display rate while raster CPU keeps moving;
- per-arm **spread** is printed so a delta can be judged against the noise floor.

`tier_armed` reports how often the ladder *armed*, which is **not** the same as
"painted low-res": `WEBKIT_LOWRES_SCROLL_SPEED` arms the tier even when
`WEBKIT_LOWRES_TILE_SCALE=1.0` has disabled low-res painting. Use it to confirm
both arms saw the same stimulus, not to infer what was painted.

## Estimator check (`estcheck.py`)

```sh
python3 estcheck.py 15 fling
```

Compares the engine's own scroll-velocity estimate (`WEBKIT_SCROLLTIER_LOG=1`,
device px/s) against ground truth measured in the page (per-rAF `window.scrollY`
deltas, CSS px/s). Both observe the same motion, so a systematic gap is estimator
error — and on a threshold trigger, estimator error *is* a false-engage rate.

On build 618 this reports a flat **3.0x** over-estimate: the ladder compares
device pixels against thresholds that read as page pixels, and `dpr = 3`.

## Gotchas these tools encode

- The thresholds in force come from the **launcher wrapper**
  (`runtime-common.sh`: 120 / 800 device px/s), not the binary's compiled
  fallbacks (400 / 2500). The wrapper wins. `atldbg` reads them from the live
  WebProcess `/proc/<pid>/environ` rather than assuming either.
- `dpr = 3` on this device, so a 120 device px/s threshold fires at 40 CSS px/s.
- Never chain a `pkill` with the run you are starting — the shell's own argv
  contains the pattern. Bracket-escaping does not save you there.
