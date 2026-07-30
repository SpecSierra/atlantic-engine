#!/usr/bin/env python3
"""Two-finger pinch on the device touchscreen (raw evdev, type-B multitouch).

Usage: pinch.py CX CY [START_GAP END_GAP [SECONDS]]

Pinch centered at (CX, CY): two fingers start START_GAP px apart (vertically)
and move to END_GAP px apart. END_GAP > START_GAP = zoom in (pinch out).
Defaults: 200 -> 700 over 0.4s (a zoom-in).

Must be copied to the device with evtouch.py alongside.
"""
import sys
import time

import evtouch
from evtouch import (EV_ABS, EV_KEY, EV_SYN, SYN_REPORT, BTN_TOUCH,
                     ABS_MT_SLOT, ABS_MT_POSITION_X, ABS_MT_POSITION_Y,
                     ABS_MT_TRACKING_ID, ABS_X, ABS_Y)

STEPS = 24


class PinchTouch(evtouch.Touch):
    """Extend the single-slot Touch with two-slot pinch primitives."""

    def slot_down(self, slot, tracking_id, px, py):
        self._ev(EV_ABS, ABS_MT_SLOT, slot)
        self._ev(EV_ABS, ABS_MT_TRACKING_ID, tracking_id)
        self._ev(EV_ABS, ABS_MT_POSITION_X, self.ax(px))
        self._ev(EV_ABS, ABS_MT_POSITION_Y, self.ay(py))

    def slot_move(self, slot, px, py):
        self._ev(EV_ABS, ABS_MT_SLOT, slot)
        self._ev(EV_ABS, ABS_MT_POSITION_X, self.ax(px))
        self._ev(EV_ABS, ABS_MT_POSITION_Y, self.ay(py))

    def slot_up(self, slot):
        self._ev(EV_ABS, ABS_MT_SLOT, slot)
        self._ev(EV_ABS, ABS_MT_TRACKING_ID, -1)

    def syn(self):
        self._ev(EV_SYN, SYN_REPORT, 0)

    def pinch(self, cx, cy, start_gap, end_gap, seconds):
        half0 = start_gap // 2
        # fingers land ~50ms apart like real ones — a same-report double-down
        # reads as a "two-finger tap" to some sites (zoom OUT on Google Maps)
        self.slot_down(0, 1, cx, cy - half0)
        self._ev(EV_KEY, BTN_TOUCH, 1)
        self._ev(EV_ABS, ABS_X, self.ax(cx))
        self._ev(EV_ABS, ABS_Y, self.ay(cy - half0))
        self.syn()
        time.sleep(0.05)
        self.slot_down(1, 2, cx, cy + half0)
        self.syn()
        time.sleep(0.05)

        for i in range(1, STEPS + 1):
            gap = start_gap + (end_gap - start_gap) * i / STEPS
            half = int(gap / 2)
            self.slot_move(0, cx, cy - half)
            self.slot_move(1, cx, cy + half)
            self.syn()
            time.sleep(seconds / STEPS)

        self.slot_up(0)
        self.slot_up(1)
        self._ev(EV_KEY, BTN_TOUCH, 0)
        self.syn()


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    cx, cy = int(sys.argv[1]), int(sys.argv[2])
    start_gap = int(sys.argv[3]) if len(sys.argv) > 4 else 200
    end_gap = int(sys.argv[4]) if len(sys.argv) > 4 else 700
    seconds = float(sys.argv[5]) if len(sys.argv) > 5 else 0.4
    with PinchTouch() as t:
        t.pinch(cx, cy, start_gap, end_gap, seconds)
    return 0


if __name__ == '__main__':
    sys.exit(main())
