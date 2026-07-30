> **Status: SHIPPED** — Runtime loads on the first `afterRendering` plus a dlopen preload; UI is up in ~2.1 s instead of ~4 s. Root cause of every late trigger was `runtime-common.sh` forcing `DELAY_MS=2000` — the wrapper can override binary defaults.

# Remove launch splash / faster startup (A+B), 2026-07-26

## CONFIRMED
- Splash = `browser-silica-main-smoke.qml`; runtime staged behind a delay, then
  `atlanticBrowserRuntimeStart` swaps in browser.qml (~1.3 s, main thread).
- **ROOT CAUSE of every late/confusing trigger: `deploy/runtime-common.sh` (engine)
  defaulted `ATLANTIC_BROWSER_RUNTIME_DELAY_MS=2000`**, so all wrapper launches took the
  fixed-delay branch; the binary's first-frame code never ran until forced with a
  non-numeric env value. Proof: `[ATL-STARTUP]` trace on 615 showed `load-runtime-begin`
  with no trigger log line — only the fixed-delay call site doesn't log. Fixed in engine
  `10945f2` (delay no longer defaulted; explicit numeric still honored).
- First-frame branch traced on 615 (DELAY_MS=none): exec-enter 679 ms,
  emit-afterRendering 766 ms, emit-frameSwapped 770 ms, trigger delivered 815 ms,
  dlopen 0 ms (preloaded), UI ~2.1 s. Works exactly as designed.
- Preload dlopen costs only 6–87 ms on its thread and makes the GUI-thread load free
  (the 0.6 s "dlopen" measured earlier on 611 was QLibrary cold-load in-line; preload
  keeps it off the critical path). KEEP.
- Splash visible at 0.9–1.0 s in stock launches; stock UI-ready ~3.4–4 s.

## RULED OUT
- frameSwapped/afterRendering "blocked until lipstick launch animation ends" — direct
  render-thread probes show both fire ~90 ms after exec-enter and deliver promptly.
  (Earlier 2.65–2.87 s "trigger" times were the wrapper's 2000 ms timer.)
- GUI-thread stall in polishAndSync freezing timers — same evidence.
- Loader-lock contention from preload delaying startup — identical timings with
  `ATLANTIC_NO_RUNTIME_PRELOAD=1`.
- Safety-timer-as-trigger on 613 — cluster at 2.65–2.87 s ≠ armed+3000 ms (~3.26 s);
  it was the wrapper 2000 ms armed at ~0.75 s.

## OPEN
- Deploy engine build 616 (wrapper fix); verify wrapper launch takes first-frame branch
  (trace shows trigger-afterRendering-delivered).
- 5×5 interleaved A/B: new default vs stock (`ATLANTIC_BROWSER_RUNTIME_DELAY_MS=2000`),
  metric = [ATL-STARTUP] load-runtime-begin + "Browser runtime started" wall time;
  splash-duration screenshots for the user-visible story.
