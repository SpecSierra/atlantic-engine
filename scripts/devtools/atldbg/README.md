# atldbg — Atlantic Browser debugger

One host-side tool to debug the WPE-WebKit Atlantic browser on the SFOS dev
device: **find bugs**, **find what's executing**, **find slow functions**, and
**debug media & rendering** — without remembering the ssh / dbus / tunnel lore.

```sh
./atldbg <command> [options]          # from scripts/devtools/
~/atldbg <command> [options]          # convenience symlink on the build host
```

It builds on the existing remote-inspector client (`../wkinspector.py`) and
centralises all device access (ssh, lipstick session bus, screenshots, launch,
inspector SSH tunnel) in `device.py`. **The inspector tunnel is opened
automatically** for every command that needs it — you never set up `-L 9224`
by hand.

## Quick start

```sh
~/atldbg launch https://jolla.com   # (re)start the browser WITH the inspector
~/atldbg doctor                     # one-shot health snapshot — run this first
~/atldbg cpu -s 5                   # what's burning CPU (scroll while it runs)
~/atldbg profile -s 15              # which JS callbacks are slow (interact)
~/atldbg media -w 5                 # video/audio + decode quality over 5s
~/atldbg render --scroll            # frame pacing / jank + screenshot (fling stimulus)
~/atldbg render --scroll --scroll-profile touch   # …driven by real finger flicks
~/atldbg bug                        # live console errors / exceptions / net fails
```

## Commands

| Command | What it answers |
|---------|-----------------|
| `doctor` | Is everything healthy *right now*? procs, memory, CPU, page state, JS errors, media — all in one snapshot. Start here. |
| `bug [-s N] [-e]` | **Find bugs.** Live stream of console messages, uncaught JS exceptions (with call stack), and failed network loads. Detects WebProcess crashes during the window. `-e` = errors only. |
| `cpu [-s N]` | **Find exec usage.** Per-thread native CPU sampling (`/proc/<pid>/task/*/stat`) across UI/Web/Network/GPU processes — names the hot thread (compositor, JSC GC, Skia raster, droidvdec…). |
| `profile [-s N]` | **Find slow functions.** JS self-time profiler with `file:line:col` attribution. (This build compiles out the JSC sampling profiler, so this uses build-independent instrumentation of timers / rAF / event handlers + the Event Timing API.) |
| `media [-w N]` | **Debug video/audio.** Every `<video>/<audio>`: source, ready/network state, buffered, errors, and decode quality (total/dropped/corrupt frames). `-w N` reports decoded-fps and dropped-frame growth. Plus engine side: live GStreamer decode threads + feature rank. |
| `render [-s N] [--scroll] [--scroll-profile P]` | **Debug rendering.** Frame pacing via an injected rAF meter: fps, p50/p95 frame time, jank. `--scroll` drives motion to exercise the raster/paint path — see [Scroll stimulus](#scroll-stimulus---scroll-profile) below, the choice matters. Reports the velocity actually produced and which scroll tier it landed in, samples render-thread CPU, and grabs a screenshot to eyeball tile corruption. |
| `eval "<js>"` | Evaluate JS on the page and print the result. |
| `tabs` | List inspectable tabs (one websocket endpoint each). |
| `launch [url]` / `open <url>` | (Re)start the browser with the inspector / navigate it. |
| `shot [path]` / `log [-n N]` / `ps` | Screenshot / tail the browser log / list browser processes. |

## Multi-tab awareness (`--tab`)

Each tab is a *separate* inspector websocket endpoint. By default every
inspector command targets the **visible** tab — background tabs are
`document.hidden=true` under the engine's visibility throttling, which also
suspends their `rAF`, so debugging the wrong tab silently measures nothing.
Override with `--tab <url-substring>`, e.g. `atldbg profile --tab jolla`.

## Scroll stimulus (`--scroll-profile`)

`--scroll` needs a *shape* of motion, not just "some scrolling". The engine
degrades rendering on a velocity ladder (full-res → low-res tiles →
checkerboard), so the stimulus decides which code path you are measuring at all.

| Profile | Motion | Use it for |
|---------|--------|-----------|
| `fling` **(default)** | Velocity impulse + kinetic decay + dwell at rest, repeated. Peak set by `--scroll-speed` (default 3500 px/s). | Almost everything. It crosses every threshold and reaches true rest, so engage / degrade / settle / sharpen transitions all get exercised. |
| `touch` | Real touchscreen flicks written to `/dev/input/event2`, through the UIProcess touch handler and the APZ scrolling thread. | Validating that a change survives the *real* input path. Least deterministic, highest fidelity. |
| `ramp` | Legacy `y += 24` per rAF — constant ~1440 CSS px/s, never settles. Against the shipped thresholds that is **100% checkerboard, 0% full-res**: it measures tiles that were never rasterized. | Reproducing pre-2026-07 numbers only. It prints a warning. |

**Every run reports the velocity it actually produced**, plus the tier occupancy
that implies:

```
· scroll stimulus actually produced:
  velocity      p50=250  p95=2750  max=18800 px/s
  tier occupancy   none 58%  low-res 36%  checkerboard 6%
```

If the run never reaches the full-res tier, `render` says so and tells you how to
disable the degradation for a paint-path measurement. This exists because the old
constant-velocity ramp sat permanently inside one tier, so it measured how well
tiles were *avoided* and silently could not observe a paint-path change.

Launch the browser with `WEBKIT_SCROLLTIER_LOG=1` and `render` additionally
reports the engine's *own* tier decisions and its `dt<0.2` gate rejection rate:

```sh
~/atldbg launch --env WEBKIT_SCROLLTIER_LOG=1 file:///home/defaultuser/light.html
~/atldbg render --scroll -s 12
```

Comparing the two blocks is the point: the in-page sampler is ground truth, the
engine block is the estimate the ladder acts on. On build 618 they disagree by
**3.0x** (the device pixel ratio) — see `INVESTIGATION.md` on the build host.

**Thresholds are read from the live WebProcess `/proc/<pid>/environ`, never
assumed**, and printed in both device and CSS px with their source. There are two
layers of defaults and they disagree: the binary falls back to 400/2500 device
px/s, but the shipped launcher (`runtime-common.sh`) exports 120/800, and the
wrapper wins. Reasoning from the C++ alone is wrong by 3-4x.

Note `WEBKIT_LOWRES_SCROLL_SPEED` arms the ladder even when
`WEBKIT_LOWRES_TILE_SCALE=1.0` has disabled low-res painting — so that flag alone
does not give a clean control arm for an A/B.

## How it works (and build-specific gotchas baked in)

- **No CDP sampling profiler.** `ENABLE_SAMPLING_PROFILER` is forced OFF in the
  Atlantic build, so `ScriptProfiler`/`Timeline` script records come back empty.
  `profile` therefore instruments the JS entry points itself.
- **Timeline timestamps are 0** in this build, so `render` measures frames with
  in-page `performance.now()` via `requestAnimationFrame`, not Timeline records.
- **rAF is compositor-driven**, so it only ticks while the page is visible *and*
  something is being rendered. `render` warns when the tab is hidden and
  `--scroll` provides the damage to measure against.

## Files

```
atldbg/
  __main__.py        CLI dispatch (python3 -m atldbg)
  device.py          ssh / dbus / screenshot / launch / inspector tunnel
  cdp.py             session, domain enable, event pump, tab selection
  scroll.py          scroll profiles (fling/touch/ramp), in-page velocity
                     sampler, WEBKIT_SCROLLTIER_LOG telemetry reader
  ui.py              terminal colour / tables / bars
  commands/          doctor, bug, cpu, profile, media, render, misc
../atldbg.sh         launcher (sets PYTHONPATH); ~/atldbg symlinks to it
```
