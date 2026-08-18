> **Status: OPEN (2026-08-18)** — Two levers implemented and unbuilt, both
> default OFF pending the on-device A/B. Three more are root-caused here but
> unimplemented. Nothing in this file has been measured on the device yet;
> treat every number below as a cost model, not a result.

# Latency levers: the half of performance that is not frame production

## Why this file exists

Almost all shipped performance work has been **frame production**: the scroll
tier ladder, low-res tiles, the compositor futex, damage-limited compositing,
the texture pool, memory-pressure budgets, CPU rendering, the governor. That
seam is close to mined out — what is left in it is already ranked in
[upstream-perf-roadmap.md](upstream-perf-roadmap.md).

Meanwhile nothing has targeted the interval between **the user's finger and the
first pixel of new content**. A survey of both repos' history found:

| User moment | State before this work |
|---|---|
| Scrolling a loaded page | Solved-ish; the open bug is the dpr=3 tier threshold error |
| Tap a link → content | No speculation anywhere. DNS → TCP → TLS runs serially *after* touch-up |
| Press Back | Cold reload (see "bfcache" below) |
| First movement after idle | Reactive governor ramp; the SoC's per-touch boost is disabled |
| Second visit to a heavy site | Every byte of JS re-parsed and re-compiled |
| CNN / franceinfo class | Main-thread bound in style + script; every engine-side lever tried is inert or documented-dead |

## Implemented (default OFF, unbuilt, un-A/B'd)

### Lever 1 — speculative connections

`ATLANTIC_PRECONNECT`, engine patch `webkit-wpe-preconnect-api.patch`.

WebKit implements speculative connections end to end and our build has them
compiled in — `ENABLE_SERVER_PRECONNECT` is 1 for every glib port
(`PlatformEnableGlib.h:58`), `allowsServerPreconnect` defaults true
(`WebsiteDataStoreConfiguration.h:343`), and `WebPageProxy::preconnectTo()` is
public (`WebPageProxy.h:1905`). What was missing was any WPE API to reach them:
Cocoa drives this from WKWebView, GTK never exposed it, so there was nothing
in-tree to copy. The patch exports `wpe_sfos_preconnect()` in the same style as
`wpe_sfos_set_dark_mode()` / `wpe_sfos_set_page_scale()`.

Two predictors drive it:

* **`kPreconnectBridge`** — a document-start user script reports the anchor
  under the finger at `touchstart`, buying the ~80-150 ms the user spends
  completing the tap. Deliberately touch-down and not hover: there is no hover
  on this device, and a pointerdown hit test is the earliest signal that is
  still a *prediction* (the finger is on the link) rather than a guess.
  Single-finger only, so a pinch never speculates.
* **The URL bar** — `Overlay.qml` debounces 300 ms and preconnects the current
  completion. For a search query this warms the search engine and reveals
  nothing about the query, because only the origin is ever used.

What actually leaves the device is a DNS query, a TCP connect and a TLS SNI.
`PreconnectTask` runs with `PreconnectOnly::Yes`, so no request line is written
and the path/query/fragment never leave; the URL is reduced to scheme/host/port
in `WPEWebPage::preconnect()` and again in the engine. A wrong guess costs one
idle socket. Rate limit: one preconnect per origin per 10 s, ≤64 origins
tracked per page — the callers are cheap to fire (dragging a finger down a link
list, every keystroke in the URL bar), and without the limit the browser would
open sockets fastest on exactly the pages already struggling.

**A/B**: 5 off / 5 on, **cold DNS each run** — a second run to the same host
measures the resolver cache, not this. The metric is tap-to-first-byte, not fps.
Rule 0 applies: state the noise floor of the tap-to-first-byte measurement
before trusting a delta.

### Lever 5 — page performance interventions

`ATLANTIC_PERF_INTERVENTIONS`, rules in
`/usr/share/atlantic-browser/perf-interventions.json`, applied by
`kPerfInterventions`.

The adblock stack is a large, weekly-refreshed rule pipeline with a pre-paint
user stylesheet and document-start scriptlets — and it is aimed almost entirely
at *ads*, with `kRedditPerf` as the lone one-off performance script. This reuses
its shape against the other half of what makes a heavy page slow here: work the
page legitimately asks for and the user never sees.

Everything is **delayed, never dropped** — dropping is the adblocker's job and
it has a filter list behind it.

| Intervention | What it does |
|---|---|
| `deferScripts` | Holds JS-inserted third-party tags (40 curated patterns: tag managers, analytics, recommendation widgets) until the first user gesture or 2.5 s after load, whichever comes first |
| `lazyImages` | `loading=lazy` + `decoding=async` on `<img>` that declares neither, past the first `eagerImages` in document order |
| `lazyFrames` | `loading=lazy` on `<iframe>` that declares nothing |
| `pauseAnims` | Pauses infinite CSS animations while offscreen, via `document.getAnimations()` + an `IntersectionObserver` |

**The load-bearing constraint on `deferScripts`**: deferral is limited to
scripts the page creates from JS. By the time a `MutationObserver` sees a
**parser-inserted** `<script src>`, "prepare a script" has already run —
removing the node or rewriting its `type` cannot stop it, and WebKit has no
`beforescriptexecute`. The dynamic path is both reliably interceptable
(`document.createElement` + the `src` setter and `setAttribute`) and where the
loaders that matter actually live: GTM, and every analytics snippet that
injects its own tag. The `createElement` wrapper is un-hooked at release so it
is not on the hot path for the rest of the page's life.

This is the one untried direction for the CNN/franceinfo class. The engine-side
attempts there are documented dead: the load-rendering throttle deadlocks the
compositor handshake ([load-perf-paint-storm.md](load-perf-paint-storm.md), do
not retry) and `WEBKIT_STYLE_SMART_RECONSTRUCT` is byte-identical inert
(smart-reconstruct memory). Both profiles are main-thread bound in style and
script, not in raster.

Verified off-device with a DOM stub harness: tag-manager script held then
replayed on gesture; first-party script never held; author-set `loading`
preserved; per-site `eagerImages` resolution correct (`edition.cnn.com` matches
the `cnn.com` rule). **Not yet run in the engine.**

**A/B**: DCL and first paint, and watch for breakage — a deferred script the
page actually waits on shows up as a site that only finishes rendering when you
touch it. Per-site `disable` is the escape hatch; validate any new rule through
`wkinspect` before CI, as with the other user scripts.

## Root-caused, not implemented

### The SoC's input boost is present and switched off

Probed on device (kernel 4.14.264, Xperia 10 II):

```
/sys/module/cpu_boost/parameters/input_boost_freq     = 0:0 1:0 … 7:0
/sys/module/cpu_boost/parameters/sched_boost_on_input = 0
/sys/module/cpu_boost/parameters/input_boost_ms       = 40
```

Qualcomm's per-touch boost driver is loaded and configured to do nothing —
Sailfish never populates it. `2fa56eb` rewrote schedutil's *frequency* policy;
this is a different mechanism (event-driven boost off the input device), and no
thread in the stack has ever had its scheduling class or priority touched
(repo grep: no `input_boost`, `SCHED_FIFO`, `chrt`, `renice`). Kernel 4.14 has
no uclamp, so this driver *is* the lever.

Cheapest experiment in the whole file: it is runtime-tunable from the existing
boot oneshot, needs no rebuild, and attacks the "takes a moment to start moving"
feel that steady-state fps cannot.

### The back/forward cache is capacity 0 by our own configuration

`ATLANTIC_CACHE_MODEL` ships as **`viewer`** (`runtime-common.sh`), and
`CacheModel::DocumentViewer` hardcodes `backForwardCacheCapacity = 0`
(`CacheModel.cpp:44`). Every Back is therefore a full network + parse + layout +
paint, by design, as part of the OOM fix.

A second mechanism would bite even if the model changed: `WebProcess.cpp:516`
passes `MaintainBackForwardCache::No` whenever `m_allowExitOnMemoryPressure` is
true — and it defaults true (`WebProcess.h:921`) — which prunes the cache to
zero (`MemoryRelease.cpp:147`), on a poll that ships at 2-3 s against a 700-900
MB base threshold.

So the honest framing is a **trade already made**, not a bug: bfcache was given
up for footprint. Revisiting it means exempting one entry for the current tab
from the conservative tier the way the style resolver was exempted, and
measuring the RSS cost of exactly that one entry — not flipping the cache model
back, which is what caused the OOM in the first place. Instrument before
touching: log `BackForwardCache::pageCount()` at each purge and each `goBack`.

### No JS bytecode caching

`CachedBytecode` / `CodeCache` exist in JSC but are referenced **nowhere** in
`Source/WebCore` or `Source/WebKit` — the serialization machinery is compiled in
and used only by the JSC shell. The disk cache work (`e922303`, `2fa56eb`)
caches bytes, not compiled code, so a repeat visit re-parses and re-baseline-
compiles everything. Largest build of the five and the most likely to fight a
WPE bump; measure the JS parse/compile slice on a warm-cache reload before
starting, and drop it if it is under ~300 ms.

## What this file does not claim

No device measurement has been taken for either implemented lever. The cost
model for lever 1 (200-500 ms of handshake on a cold origin) is a general
mobile-radio figure, not one measured on this device or this network; the first
A/B should produce the real number before the flag is flipped.
