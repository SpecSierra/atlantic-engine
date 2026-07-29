#!/usr/bin/env python3
"""Realistic finger-scroll emulation for /dev/input (run on-device, devel-su -p).

Usage:
  scrollgesture.py [--duration SEC] [--speed PXS] [--distance PX]
                   [--x X] [--y-start Y] [--gap SEC] [--report]

Why this exists
───────────────
`swipe.py` performs 20 discrete moves over ~240 ms and releases. That is not a
finger, and the difference is not cosmetic: it changes how often the engine's
`visibleRect` is updated, which is precisely the signal the scroll ladder's
`dt < 0.2` sample gate keys on.

Measured against a real user scrolling reddit.com:

  stimulus            ARM    SKIP   verdict
  swipe.py              0     536   gate rejects 100% -> ladder never arms
  real finger         207      53   gate rejects 20%  -> ladder arms normally

That gap caused a wrong conclusion to be recorded and retracted (C11). A
benchmark that under-drives the input path measures a browser the user never
uses, so this emulates the real thing:

  * touch reports at ~120 Hz (8 ms) rather than 12 ms, matching the panel rate;
  * SUSTAINED CONTACT through the whole stroke, so visibleRect updates arrive
    continuously instead of in one burst followed by a fling;
  * an ease-in / sustain velocity profile, released while still moving so APZ
    gets a genuine fling hand-off;
  * repeated strokes with a realistic inter-flick pause, because a user scrolls
    for seconds, not once.

Calibrate with --report and compare ARM/SKIP against the numbers above before
trusting any measurement built on it.
"""
import argparse
import math
import sys
import time

from evtouch import Touch

REPORT_HZ = 120.0
STEP_S = 1.0 / REPORT_HZ


def one_flick(t, x, y_start, distance, speed_pxs):
    """One finger stroke: ease-in, sustain, release while still moving."""
    total_s = max(distance / max(speed_pxs, 1.0), STEP_S * 4)
    steps = max(4, int(total_s / STEP_S))
    accel_frac = 0.25  # first quarter ramps up, like a real finger

    t.down(x, y_start)
    time.sleep(STEP_S)
    travelled = 0.0
    for i in range(1, steps + 1):
        f = i / steps
        # Ease-in then linear: integral of the velocity ramp, normalised to 1.
        if f < accel_frac:
            covered = (f * f) / (2 * accel_frac)
        else:
            covered = accel_frac / 2 + (f - accel_frac)
        covered /= (accel_frac / 2 + (1 - accel_frac))
        travelled = covered * distance
        t.move(x, int(round(y_start - travelled)))
        time.sleep(STEP_S)
    # Release WHILE MOVING so the scrolling thread starts a fling, as a flick does.
    t.up()
    return steps


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--duration", type=float, default=15.0, help="total seconds")
    p.add_argument("--speed", type=float, default=2400.0,
                   help="stroke speed, device px/s (real reddit scroll p50 ~2460)")
    p.add_argument("--distance", type=int, default=900, help="stroke length, px")
    p.add_argument("--x", type=int, default=540)
    p.add_argument("--y-start", type=int, default=1900)
    p.add_argument("--gap", type=float, default=0.45,
                   help="pause between strokes (lets the page settle)")
    p.add_argument("--report", action="store_true")
    a = p.parse_args()

    deadline = time.monotonic() + a.duration
    flicks = moves = 0
    with Touch() as t:
        while time.monotonic() < deadline:
            moves += one_flick(t, a.x, a.y_start, a.distance, a.speed)
            flicks += 1
            time.sleep(a.gap)
    if a.report:
        print(f"flicks={flicks} moves={moves} "
              f"({moves / max(a.duration, 1e-9):.0f} touch reports/s)")


if __name__ == "__main__":
    main()
