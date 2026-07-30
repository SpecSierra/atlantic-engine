# devtools — on-device debugging helpers

Host-side helper scripts used during browser development on the build server.
They are **not** part of any build or RPM — purely manual debugging aids.

## `atldbg` — the unified debugger (start here)

For day-to-day debugging use **`atldbg`** (`./atldbg.sh`, or the `~/atldbg`
symlink): one tool to find bugs, find CPU/exec hotspots, find slow JS functions,
and debug media & rendering. It opens the inspector tunnel automatically and
targets the visible tab. See [`atldbg/README.md`](atldbg/README.md).

```sh
~/atldbg doctor          # health snapshot
~/atldbg cpu | profile | bug | media | render | tabs | eval "<js>"
```

The raw scripts below are the lower-level primitives `atldbg` is built on, kept
for ad-hoc use.

## Touch input simulation

The device has no `evdev`/`evemu` tools, so touch is simulated by raw-writing
events to `/dev/input/event2` (the `sec_touchscreen`, a type-B multitouch device
whose ABS range maps 1:1 to pixels). These run **on the device** (`devel-su -p`,
which keeps the session env and runs as `defaultuser`, already in the `input`
group — no real root needed).

| Script | Usage |
|--------|-------|
| `tap.py X Y [hold_seconds]` | single tap at pixel (X, Y); default hold 0.08s |
| `swipe.py X1 Y1 X2 Y2` | drag/flick over ~20 steps |
| `pinch.py` | two-finger pinch — stagger the finger-downs, or Maps reads it as a two-finger tap |
| `scrollgesture.py` | scripted scroll gesture profiles |
| `evtouch.py` | shared module (constants + `Touch` class) |

Scripted touch cannot reproduce a real finger's cadence; for anything that depends
on gesture timing, ask the user to scroll by hand.

> **Copy `evtouch.py` to the device alongside `tap.py`/`swipe.py`** — they
> `import evtouch`, so all three must land in the same directory.

## Remote Web Inspector (Target-wrapped protocol)

These run on the **build host** and drive the WPE inspector WebSocket. They need
a tunnel to the device: `ssh -L 9224:127.0.0.1:9224 ...`, and the browser must be
launched with `WEBKIT_INSPECTOR_HTTP_SERVER=0.0.0.0:9224`.

| Script | Purpose |
|--------|---------|
| `wkinspector.py` | shared client: connect, target discovery, wrap/unwrap |
| `wkeval.py "<js>"` | evaluate JS on the page target, print the result |
| `wkinspect.py "<js>" [--gesture]` | same, with optional user-gesture emulation |
| `wkconsole.py` | dump buffered console messages |
| `wkdump.py "<js>"` | enable Runtime, evaluate, dump all frames for a few seconds |
| `wkprobe.py "<js>"` | low-level raw-frame probe (direct vs wrapped protocol) |

`wkeval`/`wkinspect`/`wkconsole`/`wkdump` build on the `Inspector` class in
`wkinspector.py`; `wkprobe.py` works with raw frames and only shares the
connection constants.

## Other helpers

| Script | Purpose |
|--------|---------|
| `atl.sh restart\|open\|shot\|push` | thin ssh/D-Bus wrapper: relaunch, navigate, screenshot (poll-until-stable), push a QML file |
| `ftrace.py` | frame-trace parser for `ATLANTIC_FRAME_TRACE` output |
| `scrollbench/` | scroll A/B harness — bench-page generator, interleaved runner, velocity-estimate check |
| `videobench/` | fullscreen video arms, frame-trace capture, RSS slope, decode-rank bake-off (`vidtest.sh`) |
| `sandbox/bwrap_shim.py` | one-off device shim that intercepts WebKit's bwrap args (`BWRAP_TEST_*`) to bisect sandbox failures |

Benchmark methodology and the traps these harnesses exist to avoid:
[`docs/BENCHMARKING.md`](../../docs/BENCHMARKING.md).
