"""Scroll drivers for benchmarking, and the scroll-tier telemetry reader.

Why this module exists
──────────────────────
`render --scroll` used to drive exactly one motion: `y += 24` every rAF, forever.
At 60 Hz that is a *constant* ~1440 px/s, which is a terrible benchmark stimulus
for anything velocity-gated:

  * it never accelerates, never decays and never settles, so it exercises no
    engage/disengage transition at all;
  * 1440 px/s sits permanently above WEBKIT_LOWRES_SCROLL_SPEED (400) and below
    WEBKIT_CHECKERBOARD_DURING_SCROLL (2500), so every run is pinned inside the
    low-res tier — a change to the tier logic is invisible to it, and a paint-path
    change is measured against tiles that were deliberately painted cheap;
  * real flings are the opposite shape: a high-velocity impulse that decays to
    zero, crossing every threshold on the way down.

So this module offers three profiles.  `ramp` is the old behaviour, kept only so
old numbers stay reproducible.  `fling` is the realistic one.  `touch` gives up
determinism to gain fidelity: it drives the real touchscreen, so the motion goes
through the UIProcess touch handler and the APZ scrolling thread exactly as a
finger does — the only profile that measures the path users actually hit.

Every profile also installs an in-page velocity sampler, because the cardinal sin
in this area is assuming what velocity you produced.  `velocity_stats()` reports
what actually happened, and `classify()` maps it onto the tier thresholds so a
run can state which tier it was in rather than guessing.
"""
from __future__ import annotations

import json
import re
import time

from . import device

# Tier thresholds.  These are read from the LIVE WebProcess environment, never
# assumed, because there are two layers of defaults and they disagree:
#
#   * the binary's compiled fallbacks (CoordinatedBackingStoreProxy.cpp): 400 / 2500
#   * the shipped launcher wrapper (/opt/wpe-sfos/libexec/atlantic/runtime-common.sh)
#     exports WEBKIT_LOWRES_SCROLL_SPEED=120 and
#     WEBKIT_CHECKERBOARD_DURING_SCROLL=800 as `${VAR:-default}`
#
# so on a stock device the effective thresholds are the wrapper's, and reasoning
# from the source alone is wrong by 3-4x.  (The wrapper comment claims the
# checkerboard rung "is DISABLED here (=0)" while the line below it sets 800 —
# do not trust the comments either.)  The values below are only a last-resort
# fallback for when the process cannot be read.
LOWRES_THRESHOLD_PXS = 120.0
CHECKERBOARD_THRESHOLD_PXS = 800.0

# The ladder measures dy in DEVICE pixels, but page-side velocity (window.scrollY)
# is in CSS pixels.  On this device dpr=3, so a threshold of 120 device px/s fires
# at 40 CSS px/s.  Reporting must state which unit it is in or the numbers are
# meaningless.
DEVICE_PIXEL_RATIO = 3.0


def read_thresholds() -> dict:
    """Read the tier thresholds actually in force from the live WebProcess.

    Returns {'lowres':px/s, 'checkerboard':px/s, 'scale':float, 'source':str} in
    DEVICE px/s.  Falls back to the shipped-wrapper defaults if the process env
    is unreadable.
    """
    out = {"lowres": LOWRES_THRESHOLD_PXS,
           "checkerboard": CHECKERBOARD_THRESHOLD_PXS,
           "scale": 0.3, "source": "fallback (wrapper defaults)"}
    try:
        r = device.ssh('P=$(pgrep -f "WPEWebProces[s]" | head -1); '
                       '[ -n "$P" ] && tr "\\0" "\\n" < /proc/$P/environ '
                       '| grep -E "^WEBKIT_(LOWRES|CHECKERBOARD)"')
        env = dict(l.split("=", 1) for l in r.stdout.splitlines() if "=" in l)
    except Exception:
        return out
    if not env:
        return out
    out["source"] = "live WebProcess env"
    scale = float(env.get("WEBKIT_LOWRES_TILE_SCALE", 0.3) or 0.3)
    out["scale"] = scale
    lowres_on = 0.25 <= scale < 1.0
    # Mirrors lowResScrollSpeedThreshold(): an explicitly-set speed wins even when
    # low-res tiles themselves are disabled -- so the tier still ARMS while nothing
    # is painted low-res.  That asymmetry made an earlier A/B look like the control
    # arm was degrading too; it was arming, not painting.
    spd = env.get("WEBKIT_LOWRES_SCROLL_SPEED")
    if spd and float(spd) > 1.0:
        out["lowres"] = float(spd)
    else:
        out["lowres"] = 400.0 if lowres_on else 0.0
    cb = env.get("WEBKIT_CHECKERBOARD_DURING_SCROLL")
    if cb is None:
        out["checkerboard"] = 2500.0
    elif cb == "" or cb == "0":
        out["checkerboard"] = 0.0
    else:
        v = float(cb)
        out["checkerboard"] = v if v > 1.0 else 800.0
    return out

# ── In-page velocity sampler ────────────────────────────────────────────────
# Records per-rAF scroll deltas so a run can report the velocity distribution it
# actually produced.  Independent of the driver, so it works for `touch` too,
# where the host has no idea what the fling did.
SAMPLER_JS = r"""
(function(){
  var st = window.__atl_scroll || (window.__atl_scroll = {});
  st.v = []; st.gen = (st.gen||0) + 1;
  var gen = st.gen, last = window.scrollY, lastT = performance.now();
  function tick(now){
    if (gen !== st.gen) return;
    var y = window.scrollY, dt = (now - lastT) / 1000;
    if (dt > 0 && dt < 1) st.v.push(Math.abs(y - last) / dt);
    last = y; lastT = now;
    requestAnimationFrame(tick);
  }
  requestAnimationFrame(tick);
  return 'sampling';
})()
"""

READ_SAMPLER_JS = "JSON.stringify((window.__atl_scroll && window.__atl_scroll.v) || [])"

# ── Profile: ramp (legacy) ──────────────────────────────────────────────────
RAMP_JS = r"""
(function(step){
  var dir=1, y=0, h=document.documentElement.scrollHeight-innerHeight;
  var st = window.__atl_scroll || (window.__atl_scroll = {});
  st.driveGen = (st.driveGen||0)+1; var g = st.driveGen;
  (function tick(){
    if (g !== st.driveGen) return;
    y+=dir*step; if(y>=h){y=h;dir=-1;} if(y<=0){y=0;dir=1;}
    window.scrollTo(0,y);
    requestAnimationFrame(tick);
  })();
  return h;
})(%STEP%)
"""

# ── Profile: fling ──────────────────────────────────────────────────────────
# Impulse + exponential decay, then a dwell at rest, repeated.  This is the
# shape of a real flick: it crosses the checkerboard threshold on the way up,
# the low-res threshold on the way down, and reaches true rest in between — so a
# run exercises engage, degrade, settle and sharpen, which the ramp never does.
#
# Position is a CLOSED-FORM function of wall-clock time, not an accumulation of
# v*dt per frame.  That distinction is the whole point: with per-frame
# accumulation a slow-rendering arm advances less per second, so the arms of an
# A/B receive *different* stimuli and scroll velocity becomes a dependent
# variable rather than a controlled one.  Measured on the heavy page that
# produced vel_p50 of 143 / 353 / 200 px/s across three arms of the same run —
# the fast arm did ~2.5x the scrolling work, which silently biases every
# comparison.  Anchoring to wall clock makes every arm traverse identical ground
# in identical time regardless of how well it renders.
#
#   v(t)    = peak * exp(-decay * t)
#   dist(t) = peak/decay * (1 - exp(-decay * t))     (total = peak/decay)
FLING_JS = r"""
(function(peak, decay, dwellMs){
  var st = window.__atl_scroll || (window.__atl_scroll = {});
  st.driveGen = (st.driveGen||0)+1; var g = st.driveGen;
  var h = document.documentElement.scrollHeight - innerHeight;
  var span = peak / decay;                     // distance covered by one flick
  var flickMs = Math.log(Math.max(peak, 2)) / decay * 1000;   // until v < 1 px/s
  var cycleMs = flickMs + dwellMs;
  var t0 = performance.now();
  var anchor = window.scrollY, dir = (anchor <= 4) ? 1 : -1, cycle = -1;
  (function tick(now){
    if (g !== st.driveGen) return;
    var elapsed = now - t0;
    var n = Math.floor(elapsed / cycleMs);
    if (n !== cycle) {                         // new flick: re-anchor, pick dir
      cycle = n;
      anchor = window.scrollY;
      if (anchor >= h - 4) dir = -1; else if (anchor <= 4) dir = 1;
    }
    var t = Math.min((elapsed - n * cycleMs) / 1000, flickMs / 1000);
    var dist = span * (1 - Math.exp(-decay * t));
    var y = anchor + dir * dist;
    if (y > h) y = h; if (y < 0) y = 0;
    window.scrollTo(0, y);
    requestAnimationFrame(tick);
  })(performance.now());
  return h;
})(%PEAK%, %DECAY%, %DWELL%)
"""

STOP_JS = "(function(){var s=window.__atl_scroll; if(s) s.driveGen=(s.driveGen||0)+1; return 1;})()"


def _fmt(js: str, **kw) -> str:
    for k, v in kw.items():
        js = js.replace(f"%{k}%", str(v))
    return js


async def start(session, profile: str, *, speed: float = 3500.0,
                step: int = 24, decay: float = 2.2, dwell_ms: int = 450):
    """Install the sampler and start the requested in-page scroll driver.

    Returns a short human description of the stimulus.  `touch` installs the
    sampler only — the motion is driven host-side by drive_touch().
    """
    await session.eval_value(f"({SAMPLER_JS})")
    if profile == "ramp":
        await session.eval_value(f"({_fmt(RAMP_JS, STEP=step)})")
        return f"ramp {step}px/rAF (~{step*60} px/s constant)"
    if profile == "fling":
        await session.eval_value(
            f"({_fmt(FLING_JS, PEAK=speed, DECAY=decay, DWELL=dwell_ms)})")
        return f"fling peak {speed:.0f} px/s, decay {decay}, dwell {dwell_ms}ms"
    if profile == "touch":
        return "real touchscreen flicks (APZ path)"
    raise ValueError(f"unknown scroll profile: {profile}")


async def stop(session):
    try:
        await session.eval_value(f"({STOP_JS})")
    except Exception:
        pass


async def read_velocities(session) -> list:
    raw = await session.eval_value(READ_SAMPLER_JS, default="[]")
    try:
        vals = json.loads(raw) if isinstance(raw, str) else (raw or [])
    except Exception:
        return []
    return [float(v) for v in vals if isinstance(v, (int, float)) and v > 0]


# ── Real touchscreen driver ─────────────────────────────────────────────────
_TOUCH_HELPERS = ("/root/swipe.py", "/root/evtouch.py")


def ensure_touch_helpers() -> None:
    """Copy swipe.py/evtouch.py to the device if they are not already there."""
    r = device.ssh("test -f /home/defaultuser/swipe.py && "
                   "test -f /home/defaultuser/evtouch.py && echo yes")
    if "yes" in r.stdout:
        return
    for f in _TOUCH_HELPERS:
        device.scp_to(f, f"/home/{device.USER}/")


def drive_touch(seconds: float, *, x: int = 540, y1: int = 1900, y2: int = 700,
                gap: float = 1.2) -> int:
    """Flick the real touchscreen for `seconds`; returns the number of flicks.

    Runs under `devel-su -p` (keeps the session env, runs as defaultuser, which
    is in the `input` group — real root is NOT needed to write /dev/input).
    """
    ensure_touch_helpers()
    deadline = time.monotonic() + seconds
    n = 0
    while time.monotonic() < deadline:
        device.ssh(
            f"echo root | devel-su -p python3 /home/{device.USER}/swipe.py "
            f"{x} {y1} {x} {y2}",
            session_env=True, timeout=30)
        n += 1
        time.sleep(gap)
    return n


# ── Scroll-tier telemetry (WEBKIT_SCROLLTIER_LOG=1) ─────────────────────────
_ARM_RE = re.compile(r"ARM dy=(-?\d+) dt=([\d.]+) speed=([\d.]+) tier=(\d)")
_SKIP_RE = re.compile(r"SKIP dy=(-?\d+) dt=([\d.]+)")
TIER_NAMES = {0: "none (full-res)", 1: "low-res", 2: "checkerboard"}


def log_mark() -> int:
    """Current line count of the browser log, to bound a telemetry window."""
    r = device.ssh("wc -l < /tmp/atl.log 2>/dev/null || echo 0")
    try:
        return int(r.stdout.strip() or 0)
    except ValueError:
        return 0


def read_tier_log(mark: int) -> dict | None:
    """Parse [scrolltier] lines written since `mark`.

    Returns None when the build/run has no telemetry (the browser was not
    launched with WEBKIT_SCROLLTIER_LOG=1), so callers can stay quiet.
    """
    r = device.ssh(f"tail -n +{mark + 1} /tmp/atl.log 2>/dev/null | grep scrolltier")
    lines = [l for l in r.stdout.splitlines() if "scrolltier" in l]
    if not lines:
        return None
    tiers, speeds, skips = {0: 0, 1: 0, 2: 0}, [], []
    for l in lines:
        m = _ARM_RE.search(l)
        if m:
            speeds.append(float(m.group(3)))
            tiers[int(m.group(4))] = tiers.get(int(m.group(4)), 0) + 1
            continue
        m = _SKIP_RE.search(l)
        if m:
            # The very first sample has an uninitialised timestamp and yields a
            # nonsense dt of ~1.4e5 s; it is a startup artefact, not a rejection.
            dt = float(m.group(2))
            if dt < 1000:
                skips.append(dt)
    armed = sum(tiers.values())
    return {
        "armed": armed, "tiers": tiers, "speeds": speeds, "skips": skips,
        "skip_frac": len(skips) / max(1, armed + len(skips)),
    }


def classify(speeds: list, thresholds: dict | None = None,
             *, css_px: bool = False) -> dict:
    """Fraction of samples falling in each tier.

    `speeds` in CSS px/s (the in-page sampler) must pass css_px=True so they are
    converted to the DEVICE px/s the engine compares against; engine-reported
    speeds are already device px/s and need no conversion.  Getting this wrong is
    a silent 3x error -- it is the bug this whole investigation turned on.
    """
    if not speeds:
        return {}
    t = thresholds or {"lowres": LOWRES_THRESHOLD_PXS,
                       "checkerboard": CHECKERBOARD_THRESHOLD_PXS}
    k = DEVICE_PIXEL_RATIO if css_px else 1.0
    lo = t.get("lowres") or float("inf")
    hi = t.get("checkerboard") or float("inf")
    n = len(speeds)
    cb = sum(1 for v in speeds if v * k >= hi)
    lr = sum(1 for v in speeds if lo <= v * k < hi)
    return {"none": (n - cb - lr) / n, "low-res": lr / n, "checkerboard": cb / n}


def pct(sorted_vals, p):
    if not sorted_vals:
        return 0.0
    i = min(len(sorted_vals) - 1, int(p / 100.0 * len(sorted_vals)))
    return sorted_vals[i]
