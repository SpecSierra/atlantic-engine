# Working with the device

Dev device: **Xperia 10 II**, SFOS 5.1.0.11, on a local tunnel at port 2222.
Password for both `defaultuser` ssh and `devel-su` is **`root`** (not
"sailfishos", despite older notes).

```sh
SSH="sshpass -p root ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null defaultuser@localhost"
```

Prefer **`atldbg`** for everyday work — it wraps everything below. The raw recipes
are what you fall back to when `atldbg` itself is the thing that's broken.

## `devel-su` has two modes, neither obvious

| Form | uid | Env | Use for |
|---|---|---|---|
| `echo root \| devel-su <cmd>` | 0 | **reset** (loses `XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS`) | root-only file writes, e.g. under `/opt/wpe-sfos` |
| `echo root \| devel-su -p <cmd>` | 100000 | **preserved** | screenshots, touch — need the session bus / `input` group, not root |
| `devel-su -c <cmd>` | — | — | **always fails** ("Failed to exec"). Never use. |

`devel-su <cmd>` also does not shell-parse pipes.

Logs: `journalctl -f`; `/tmp/wpe-debug.log` (subprocess debug); `/tmp/atl.log`
(where the launch recipe below redirects).

## Deploy a CI build

```sh
# on device, as root
echo root | devel-su zypper --non-interactive ref atlantic-ci-v2
echo root | devel-su zypper --non-interactive up \
    wpewebkit2 wpewebkit2-qt5 atlantic-browser \
    wpebackend-fdo libwpe libepoxy wpe-sfos-compat bubblewrap xdg-dbus-proxy firejail
rpm -q atlantic-browser wpewebkit2      # confirm the iteration installed
```

RPMs come from GitHub Pages (`gh-pages` branch):
`https://specsierra.github.io/atlantic-engine/aarch64/`. The `.aio` bundle needs an
explicit `zypper install`, not `up`.

## Confirm a patch is really in the shipped engine

busybox `grep` is unreliable on the 167 MB `libWPEWebKit-2.0.so.1`: `grep -c -F`
returns 0 for strings that are present, and `grep -ao` with a character class
silently misses matches — both give a convincing false negative. Split into short
lines first:

```sh
$SSH 'L=$(readlink -f /usr/lib64/libWPEWebKit-2.0.so.1)
      tr -c "\40-\176" "\n" < "$L" | grep "^WEBKIT_" | sort -u'
```

This lists every engine env var the build actually reads — do it before trusting
any A/B against a gated patch.

## Launch and navigate

The browser needs the session env and must be detached. Cleanup must not contain
the literal `atlantic-browser.bin` in the same remote command (it matches the ssh
shell's own cmdline) — bracket-escape it:

```sh
$SSH 'export XDG_RUNTIME_DIR=/run/user/100000
      export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/100000/dbus/user_bus_socket
      pkill -f "atlantic-browser.bi[n]"; pkill -f "WPEWebProces[s]"; pkill -x bwrap; sleep 2
      setsid /usr/bin/atlantic-browser >/tmp/atl.log 2>&1 </dev/null &'
```

The command-line URL argument is **ignored** (`initialUrl=""`). Navigate over
D-Bus; the signature is an **array** of strings:

```sh
$SSH 'export XDG_RUNTIME_DIR=/run/user/100000
      export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/100000/dbus/user_bus_socket
      dbus-send --session --print-reply --dest=org.atlantic.browser.ui --type=method_call \
        /ui org.atlantic.browser.ui.openUrl array:string:"https://example.com"'
```

`openUrl` sent before the browser owns the bus name activates a **second**
browser. Assert one instance before trusting any measurement.

## Screenshots

```sh
$SSH 'export XDG_RUNTIME_DIR=/run/user/100000
      export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/100000/dbus/user_bus_socket
      echo root | devel-su -p dbus-send --session --print-reply \
        --dest=org.nemomobile.lipstick /org/nemomobile/lipstick/screenshot \
        org.nemomobile.lipstick.saveScreenshot string:/home/defaultuser/ss.png
      echo root | devel-su -p chmod 644 /home/defaultuser/ss.png'

sshpass -p root scp -P 2222 -o StrictHostKeyChecking=no \
    defaultuser@localhost:/home/defaultuser/ss.png /tmp/device-ss.png
```

- `saveScreenshot` **refuses to overwrite** and writes asynchronously — the D-Bus
  reply lands before the PNG is flushed, so a fixed filename plus an immediate
  `scp` silently pulls the *previous* frame. Use a fresh name and poll until the
  size stops changing (`atldbg` and `scripts/devtools/atl.sh shot` do this).
- **Prove freshness**: print the timestamp, capture again ~2 s later, confirm the
  two differ. Identical captures mean a stale capture path, not a static screen.
- Direct-composited subsurfaces never appear in screenshots.

## Touch input

No `evdev`/`evemu` on device, so touch is raw-written to `/dev/input/event2`
(`sec_touchscreen`, type-B multitouch, ABS range maps 1:1 to pixels: X 0–1079,
Y 0–2519). Helpers in `scripts/devtools/`:

| Script | Does |
|---|---|
| `tap.py X Y [hold]` | tap at pixel (X, Y), default hold 0.08 s |
| `swipe.py X1 Y1 X2 Y2` | drag/flick over ~20 steps |
| `pinch.py` | two-finger pinch — **stagger the finger-downs**; same-report downs read as a two-finger tap (Maps zooms out) |
| `evtouch.py` | shared module; must be copied alongside the others (`import evtouch`) |

They run on the device under `devel-su -p` (`defaultuser` is in `input`; root is
not needed):

```sh
sshpass -p root scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    scripts/devtools/{tap.py,swipe.py,evtouch.py} defaultuser@localhost:/home/defaultuser/

$SSH 'echo root | devel-su -p python3 /home/defaultuser/tap.py 1000 120
      echo root | devel-su -p python3 /home/defaultuser/swipe.py 540 1900 540 700'
```

Scroll-then-screenshot catches transient UI (overlay scrollbar, repaint glitches);
a flick ending in the overscroll area captures a blank frame, so keep the end Y
inside content.

**Scripted touch cannot reproduce a real finger's cadence** — for anything timing
dependent (fling velocity, gesture latching) ask the user to scroll by hand. A
scripted flick has measured 0 where a real one measured 207.

## Remote Web Inspector

Developer-extras is on in the qt5 plugin. Read the target list from the device — a
reverse tunnel is fragile:

```sh
# launch with: WEBKIT_INSPECTOR_HTTP_SERVER=0.0.0.0:9224 setsid /usr/bin/atlantic-browser … &
$SSH 'curl -s http://127.0.0.1:9224/ | grep -oiE "targeturl\">[^<]*"'
```

`scripts/devtools/wkinspect.py "<js>"` and `wkconsole.py` drive the WebSocket
protocol (need `-L 9224:127.0.0.1:9224`; Target-wrapped flavour), sharing the
boilerplate in `wkinspector.py` alongside `wkeval.py`, `wkdump.py`, `wkprobe.py`.
Validate user scripts here before pushing them through CI.

## `atldbg`

Lives at `scripts/devtools/atldbg/` (`~/atldbg` symlinks the launcher). Opens its
own inspector tunnel — kill any manual `-L 9224` first — and targets the visible
tab by default (`--tab <substr>` to pick another).

| Command | Answers |
|---|---|
| `launch <url>` | (re)start the browser with the inspector; `--env K=V` repeatable |
| `doctor` | is everything healthy? procs, memory, CPU, page state, JS errors, media — run this first |
| `bug` | console errors, uncaught exceptions with stacks, failed loads, WebProcess crashes |
| `cpu -s 5` | per-thread native CPU across UI/Web/Net/GPU processes |
| `profile -s 15` | JS self-time with `file:line:col` (instrumented — the JSC sampling profiler is compiled out) |
| `media -w 5` | element state, dropped/decoded frames, GStreamer decode threads and ranks |
| `render --scroll` | fps / p95 / jank (in-page rAF meter), render-thread CPU, screenshot, plus the velocity actually produced and the tier it landed in |
| `tabs` | list inspectable tabs |

Full docs: `scripts/devtools/atldbg/README.md`. Dev-only — not in any build or RPM.

## Preflight before any measurement

1. ssh tunnel alive;
2. device unlocked, display on;
3. installed build number printed and matching the commit under test.

Never report numbers from a build you have not verified. Measurement rules:
[BENCHMARKING.md](BENCHMARKING.md).
