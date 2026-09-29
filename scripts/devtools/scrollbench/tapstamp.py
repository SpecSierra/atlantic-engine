#!/usr/bin/env python3
"""Tap (X, Y) and print device wall-clock epoch seconds of touch-down and touch-up.

Usage: tapstamp.py X Y [hold_seconds]   (run on-device under `devel-su -p`)
Needs evtouch.py alongside. Prints:  down=<epoch> up=<epoch>
The stamps share a clock with the page's performance.timeOrigin, which is what
tapbench.py subtracts.
"""
import sys
import time

from evtouch import Touch

px, py = int(sys.argv[1]), int(sys.argv[2])
hold = float(sys.argv[3]) if len(sys.argv) > 3 else 0.06
with Touch() as t:
    d = time.time()
    t.down(px, py)
    time.sleep(hold)
    u = time.time()
    t.up()
print("down=%.6f up=%.6f" % (d, u))
