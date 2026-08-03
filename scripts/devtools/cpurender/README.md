# cpurender — CPU-rendering crash harness

The eight layout tests that crash upstream WPE test bots when
`WEBKIT_SKIA_ENABLE_CPU_RENDERING=1` is set, plus a runner that survives a
WebProcess death and names the test that caused it.

We set that variable from `atlantic-browser.bin` whenever the GPU-conservative
probe trips, so this is our default configuration, not an exotic one. Upstream
closed [bug 287572](https://bugs.webkit.org/show_bug.cgi?id=287572)
procedurally without fixing the failures — this harness is how we check whether
they reproduce on our engine build and GPU.

Last result: **all 8 survived**, build 636 (`wpewebkit2-2.52.5-636.1`), Xperia
10 II / Adreno 610. Details and what the run does *not* cover:
`docs/investigations/upstream-perf-roadmap.md`.

## Running it

```bash
scp -P 2222 -r scripts/devtools/cpurender defaultuser@localhost:/home/defaultuser/
ssh -p 2222 defaultuser@localhost \
  'cd ~/cpurender && (setsid nohup python3 -m http.server 8099 --bind 127.0.0.1 >/tmp/httpd.log 2>&1 &)'
./atldbg launch http://127.0.0.1:8099/index.html
```

Serve it over loopback HTTP rather than `file://` — sailjail blocks the paths and
the tests behave differently off a null origin.

The page auto-runs, dwelling 2.5 s per test. Poll it with:

```bash
./atldbg eval 'localStorage.getItem("cpurender.idx")'
```

`idx` reaching 8 means every test survived. Append `#manual` to the URL to step
by hand.

## Reading a crash

The runner writes its index to `localStorage` **before** loading each test and
only advances **after** the dwell. So if the WebProcess dies, `idx` still points
at the test that killed it — reload and read it, or just look at the status line.

Confirm the configuration was actually active before trusting any result. The
probe can pick GPU painting, which silently makes the whole run meaningless:

```bash
tr '\0' '\n' < /proc/$(pgrep -f WPEWebProcess | head -1)/environ | grep SKIA
```

You want `WEBKIT_SKIA_ENABLE_CPU_RENDERING=1`. Corroborate a suspected crash
against the WebProcess PIDs (`pgrep -a WPEWebProcess`) before and after — a
respawn with a new PID is the unambiguous signal.

## Scope

Crashes only. The other ~130 upstream failures under this flag are
ImageOnlyFailures — pixel diffs needing reference renders we do not have on
device. A clean run here does not mean the CPU path renders correctly.
