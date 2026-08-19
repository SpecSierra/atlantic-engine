> **Status: PARTLY RESOLVED (2026-08-18)** — Lever 1 (preconnect) is implemented
> and its mechanism is **device-verified on build 646.2**; it stays default OFF
> because the benefit still has no instrument. Lever 5 (page interventions) was
> implemented, measured, found **inert**, and has been **removed** — the reasons
> are recorded below so it is not rebuilt the same way. The SoC input boost is
> now implemented too — its mechanism is proven but its benefit is not, so it
> ships default OFF. Two further levers are root-caused but unimplemented.
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

## Implemented and measured

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

**Device result (build 646.2, 2026-08-18): the mechanism works.** The probe
touches down on a link, holds, then drags away and releases, so the link is
never activated and no navigation can occur — any connection that appears is the
preconnect and nothing else.

| Arm | Link touched | New peer during touch-down |
|---|---|---|
| `=1` | pixelcluster.dev | `141.95.41.139:443` |
| `=1` | opensource.posit.co | `2a05:d01c:9e6:f102::443` |
| `=1` | pleated-jeans.com | `2606:4700:3030::681:443` |
| `=0` | the same three | **none** |

`141.95.41.139` reverse-resolves to `pixelcluster.dev`, and a real navigation to
another probed host later landed on exactly the peer its probe had opened.

Two harness traps, both worth knowing before re-running this:

- Sampling `netstat` a fixed delay after *starting* the touch script samples
  before the touch lands — `python3` + `devel-su` startup on device is hundreds
  of ms. Correlate against the down event, don't assume it.
- Picking a link point from `getBoundingClientRect()` centre is wrong for
  wrapped text: the union rect of a multi-line inline anchor has its centre in
  the whitespace between line boxes, and the touch lands on the enclosing `TD`.
  Use `getClientRects()[0]` and confirm with `elementFromPoint` before touching.
  (The device→CSS mapping itself is exact ×3, no chrome offset.)

**Still default OFF.** The mechanism working is not the mechanism paying:
tap-to-first-byte has no instrument (`render --scroll` measures the fling path).
Build that first, then A/B 5 off / 5 on with **cold DNS each run** — a second run
to the same host measures the resolver cache, not this lever.

### Lever 5 — page performance interventions — REMOVED, measured inert

Implemented as a rule file plus a document-start user script applying four
interventions (defer JS-inserted third-party tags, `loading=lazy` +
`decoding=async` on untagged images, `loading=lazy` on untagged iframes, pause
infinite offscreen CSS animations), then measured on `edition.cnn.com` on build
646.2 and **removed**. Every intervention was inert. Keeping the reasons because
each one is a trap that would be walked into again.

**DCL, interleaved, warm cache:**

| | n | mean | sd |
|---|---|---|---|
| OFF | 10 | 12701 ms | 2043 |
| ON | 10 | 12165 ms | 2411 |

536 ms (4.2%), Welch t = 0.54 against a pooled noise floor of ~2235 ms — no
effect. **The first 5 pairs showed −17% and looked like a clear win**; it
evaporated when n reached 10. Rule 0 earned its keep here: stopping at the
project's nominal 5-run A/B would have shipped a false positive.

Why each intervention did nothing:

1. **`deferScripts` had nothing to defer.** CNN loads 194 resources across 9
   hosts, all first-party plus stripe/piano.io. **Zero** matched the 40 curated
   defer patterns, because our own adblocker had already removed every tag
   manager and analytics host. On ad-heavy sites this intervention is redundant
   with a subsystem we already ship; it could only matter where trackers are
   first-party-proxied or the site is allowlisted.

2. **`lazyImages` / `lazyFrames` are a no-op, and the premise was wrong.** CNN
   sets no `loading` attribute itself (0 of 74 images); the script tagged all
   74 — and **74/74 were fetched anyway, including all 58 more than two
   viewports below the fold.** Resource counts were byte-identical across arms
   in 3/3 runs.

   The root cause is the one already documented for scripts, which was not
   carried over to images when this was written: **the load starts when the
   parser inserts the element**, so an attribute applied from a
   `MutationObserver` callback — even at document-start — arrives after the
   decision has been made. `loading=lazy` set after insertion is decorative.
   The engine is not at fault: `LazyImageLoadingEnabled` defaults true and
   `"loading" in HTMLImageElement.prototype` is true on device.

3. **`pauseAnims` did not pause.** Six infinite animations, all offscreen at
   y≈2600 against an 840 px viewport, all still `running` after 25 s. Not
   root-caused before removal; suspects are the bounded rescan window and
   `IntersectionObserver.observe()` on SVG `<g>` targets.

**If this is ever retried**, the lazy half belongs in the engine, not in JS:
a small patch making an absent `loading` attribute mean lazy behind a flag, in
`HTMLImageElement`, where the decision is actually taken at parser insertion.
The defer half needs a site corpus where the patterns actually match — measure
that before writing any more rules. And DCL is the wrong metric for lazy
loading in any case: it fires at DOM parse, while image loading is mostly
post-DCL. Measure bytes, decoded-image memory or post-load main-thread time.

## Root-caused; one implemented, two not

### The SoC's input boost — MOVED OUT to sfos-qcom-boost

**This no longer lives in Atlantic.** The implementation moved to a standalone
package, [sfos-qcom-boost](https://github.com/SpecSierra/sfos-qcom-boost), which
also carries the cpufreq governor repair and the GPU power floor — none of the
three is browser-specific, and two copies of the same sysfs writes would drift.
Atlantic now `Requires: sfos-qcom-boost`; both are published on OpenRepos. The
investigation below is kept because it is why the lever exists and what is known
about its value.

Probed on device (kernel 4.14.264, Xperia 10 II): Qualcomm's `cpu_boost` driver
is loaded and configured to do nothing — `input_boost_freq` 0 on all eight
cores, `sched_boost_on_input` 0. SFOS never populates it. `2fa56eb` rewrote
schedutil's *frequency* policy; this is a different, event-driven mechanism, and
no thread in the stack has ever had its scheduling class touched.

**Why the governor cannot substitute.** The governor repair (now `sfos-qcom-boost`, formerly `atlantic-cpu-governor.sh`) is a repair:
it rewrites a dead sugov instance so the cluster can ramp at all, then exits. On
device the repair holds — `policy4` reads `schedutil`, idles at 1 056 000, tops
at 2 016 000, `up_rate_limit_us=1000`. Once repaired schedutil is purely
reactive, so the order after a touch is always: finger down → browser wakes →
threads run *at the idle floor* → utilization accumulates (PELT, ~32 ms
half-life) → frequency rises. The governor's input is load that has not happened
yet. `cpu_boost` hooks the input event itself.

**Mechanism: proven.** Idle system, touch injected and frequency sampled from
one process so they share a clock:

| `input_boost_freq` | result |
|---|---|
| all zero (shipped) | 3/3 taps — `policy4` never left 1 056 000 within 350 ms |
| cpu4-7 = 1401600 | 3/3 taps — 1 401 600 reached **4-5 ms** after touch-down |

**Benefit: not demonstrated.** Shipped as `deploy/atlantic-input-boost.sh` +
`.service` (default OFF, opt-in via `/etc/atlantic/input-boost.conf`), then A/B'd
on `edition.cnn.com` by toggling the sysfs arm between trials — no relaunch, so
the arms alternate inside one browser session with no drift.

| metric | OFF (n=10) | ON (n=10) | diff | t |
|---|---|---|---|---|
| touch → next frame | 17.6 ms (median 14.0, sd 10.5) | 12.3 ms (median 11.5, sd 2.4) | 5.3 ms | 1.55 |
| touch → first scroll movement | 149.7 ms (sd 26.1) | 158.3 ms (sd 37.8) | −8.6 ms | −0.59 |

Neither clears the bar. The 5.3 ms on touch-to-frame rests almost entirely on a
single 46 ms OFF sample; drop it and OFF's mean falls to ~14.4 ms and the
difference is ~2 ms. Scroll onset shows nothing.

Two things stop this being written off as a flat negative — both say
"underpowered", not "absent":

- **The point estimate matches the a-priori physical prediction.** The boost
  raises the clock 1056 → 1401 MHz, so a CPU-bound wake path should scale by
  1056/1401 = 0.754 — predicting the 14.0 ms median becomes **10.6 ms**, against
  an observed ON median of 11.5 ms. Corroboration, not proof: it says the effect
  has the right size and sign *if* it exists.
- **n=10 could not have resolved it.** With the outlier-robust effect (2.1 ms)
  against a pooled sd of 3.1, 80% power at α=.05 needs **n ≈ 33 per arm**. The
  experiment was three times too small to conclude in either direction.

**Two reasons the experiment may not have been decisive**, both to fix before
retrying rather than after:

1. **No headroom in the metric.** Touch-to-next-frame is already 11-14 ms — under
   one 16 ms vsync interval. A lever that delivers frequency 4-5 ms after touch
   cannot show up in a number already sitting at the frame floor. Measure
   something with room: p95 rather than the mean, or time to first *painted*
   frame under real load.
2. **The precondition was never confirmed.** The boost only does anything if the
   cluster is actually at its floor when the finger lands. With CNN loaded and
   still working in the background it may well have been at 2 016 000 already,
   in which case the experiment measured a no-op by construction. Sampling
   `scaling_cur_freq` at touch time is the missing control — the tunnel dropped
   before it could be taken.

So: the driver works and is reachable, the packaging is done and safe (default
OFF, self-gating, auto-detects the big cluster), and there is **no evidence yet
that arming it makes anything faster**. It should not be enabled on that basis.

**Second A/B (n=30/arm) closes it: the boost does not buy latency here.**
The first attempt was invalid, and the way it was invalid is the useful part.
Two observer effects had to be removed before the experiment measured anything:

1. **The apparatus woke the CPU it was measuring.** Shelling out over ssh to
   start `python3` for each touch is real work on the device, and it lifted the
   big cluster off its floor immediately before the touch being timed — the
   exact state the boost exists to fix. Fixed by moving the whole A/B into one
   resident on-device process: no ssh, no interpreter startup, no `devel-su` in
   the critical window.
2. **Waiting for the idle state prevented it.** Polling `scaling_cur_freq` every
   100 ms until it read 1056 kept the cluster awake polling. Only 2 of 8 trials
   reached the floor. Exiting the wait early and letting a fixed settle elapse
   instead took it to **41 of 60**.

With the precondition actually met and the boost raised to the cluster's full
2 016 000 (so it can act from 1401 too, not only from the floor):

| subset | n/arm | OFF | ON | diff | t |
|---|---|---|---|---|---|
| all trials | 30 | 28.5 ms | 21.2 ms | 7.3 | 1.57 |
| boost could act (`f0` < 2016) | 29 | 24.3 ms | 21.2 ms | 3.1 | 1.46 |
| started at the floor (`f0` = 1056) | ~20 | 24.6 ms | 22.6 ms | 2.0 | 0.80 |

Nothing is significant, but the decisive point is not the p-values — it is the
**direction of the conditioning**. The at-floor subset is where the boost has
the most leverage (1056 → 2016 MHz, a 1.91× clock increase). If the effect were
real it would be *largest* there. It is the smallest. And a CPU-bound wake path
at the floor predicts 24.6 × 1056/2016 = **12.9 ms**, against 22.6 ms observed —
missing by ~10 ms. So touch-to-frame on this device is not bound by big-cluster
clock at that moment; the 2-3 ms is noise, and the earlier corroboration from
the 1401 MHz clock ratio was a coincidence of a small sample.

(The scroll-onset metric degenerated in this run — means ~2800 ms, sd ~1700,
medians ~3890 — because repeated flicks drove the page to the bottom where
`scrollY` stops changing and the probe ran to its 90-frame cap. Discard it;
only `toFrame` is meaningful here.)

**Shipped ON anyway (2026-08-19), as a product decision.** The measurement above
did not change: there is no demonstrated touch-to-frame benefit, and the effect
shrank as the boost gained leverage. It ships enabled via
`/etc/atlantic/input-boost.conf` (`ATLANTIC_INPUT_BOOST=1`, floor 2016000, 80 ms)
at the maintainer's direction. Recorded here so the next person reading a
frequency trace knows why the cluster jumps on touch, and so nobody mistakes the
default for evidence. The file is an rpm config file, so setting
`ATLANTIC_INPUT_BOOST=0` on a device survives upgrades. End-to-end verified with
the shipped config on 646.2: touch → 2 016 000 at +8 ms, held ~96 ms, back to
floor.

**What the measurement said: keep it off.** The driver works and is reachable in 4-5 ms, the
packaging is safe and self-gating, and there is now positive evidence that
arming it does *not* improve touch-to-frame on a heavy page. What has not been
tested is `sched_boost_on_input` (task placement), which is a different
mechanism and the only remaining reason to revisit this.

**One implementation detail worth not rediscovering:** the kernel param parser
rejects a trailing separator with `EINVAL`. A generated `"0:0 1:0 … 7:1401600 "`
spec fails the write while the identical string without the trailing space
succeeds — and since the write is a shell redirect, that failure is silent
unless checked. The script trims it and reports instead of no-opping.

**Scope caveat, unlike every other lever here**: `cpu_boost` is system-wide. It
fires on any touch anywhere in the OS, so arming it from a browser package
changes the whole phone — and would flatter a browser benchmark by speeding up
everything else too. Hence the opt-in file rather than a default.

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

Lever 1's *benefit* is still unmeasured. The mechanism is verified; the
200-500 ms handshake figure it is meant to recover is a general mobile-radio
number, not one measured on this device or network. Until `atldbg` can report
tap-to-first-byte, the flag stays off.

The lever 5 numbers are one site (`edition.cnn.com`), warm cache, one network.
The conclusion drawn from them is deliberately narrow — that the interventions
as implemented did nothing measurable there, and that two of the three have a
mechanical reason they could not have worked anywhere. It is not a claim that
deferring third-party script can never help a site that actually loads some.
