# Investigations

Concluded investigation logs. Each file opens with a **Status** line; read that
first — several of these document approaches that are dead, and the value is in
not retrying them.

The live log for work in progress is `INVESTIGATION.md` in the repo root. When it
concludes, add a status header and move it here.

## Rendering / scroll

| Doc | Status |
|---|---|
| [scroll-tier-velocity-metric.md](scroll-tier-velocity-metric.md) | shipped (625); the tier ladder compares device px against page-px thresholds — dpr=3 error still open |
| [scroll-lowres-tiles.md](scroll-lowres-tiles.md) | shipped — original design record for the low-res tile ladder |
| [scroll-freeze-decouple.md](scroll-freeze-decouple.md) | fix shipped; the wider decouple is abandoned |
| [load-perf-paint-storm.md](load-perf-paint-storm.md) | load-rendering throttle unfixable (compositor deadlock) — **do not retry**; repaint storm still open |
| [rendering-audit.md](rendering-audit.md) | stale (2026-05-28), early device facts only |
| [upstream-perf-roadmap.md](upstream-perf-roadmap.md) | **open roadmap** — what upstream already knows is slow in 2.52.5, ranked; the CPU-rendering crash check is done and negative |

## Video

| Doc | Status |
|---|---|
| [video-fullscreen-choppiness.md](video-fullscreen-choppiness.md) | resolved (607) — compositor futex-blocked on a main-thread-held layer lock; 8 other theories ruled out |
| [video-presentation-decoupling.md](video-presentation-decoupling.md) | shipped — handover for the same work |
| [video-playback.md](video-playback.md) | shipped — `droidvdec` hardware decode |

## Layout / input

| Doc | Status |
|---|---|
| [font-size-viewport-units-zoom.md](font-size-viewport-units-zoom.md) | shipped default-ON (630); `vw/vh`/`cqw` font-size double-zoom. VG web fonts still broken |
| [pinch-zoom-page-driven.md](pinch-zoom-page-driven.md) | shipped, verified (617) |
| [spa-back-history-skip.md](spa-back-history-skip.md) | shipped behind `ATLANTIC_STRICT_HISTORY_NAV` (default OFF), A/B verified (618) |

## Platform / features

| Doc | Status |
|---|---|
| [startup-splash-removal.md](startup-splash-removal.md) | shipped — the wrapper was forcing a 2 s runtime-load delay |
| [adblock-rust-integration.md](adblock-rust-integration.md) | shipped (462) — design record for the Brave/Rust engine |
| [sandbox-bubblewrap.md](sandbox-bubblewrap.md) | **superseded** — concludes bwrap is unworkable; that was later reversed and bwrap ships default-ON |
| [direct-composite-overlay.md](direct-composite-overlay.md) | parked — lipstick pins a Silica `ApplicationWindow` to the base layer |
| [chrome-blur.md](chrome-blur.md) | shipped — screen-fixed blurred chrome via `gl_FragCoord` |
