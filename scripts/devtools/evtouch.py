#!/usr/bin/env python3
"""Shared raw-evdev touch primitives for the device touchscreen.

The touchscreen is found at runtime (Xperia 10 II: sec_touchscreen on event2;
Jolla Phone 2: hyn_ts on event5). Both are type-B multitouch devices whose ABS
range maps 1:1 to pixels, so the pixel size defaults to the ABS range. Used by
tap.py, swipe.py and pinch.py — it MUST be copied
to the device alongside them (they `import evtouch`).
"""
import struct
import fcntl


EV_SYN = 0
EV_KEY = 1
EV_ABS = 3
SYN_REPORT = 0
BTN_TOUCH = 0x14a
ABS_X = 0x00
ABS_Y = 0x01
ABS_MT_SLOT = 0x2f
ABS_MT_POSITION_X = 0x35
ABS_MT_POSITION_Y = 0x36
ABS_MT_TRACKING_ID = 0x39


def eviocgabs(fd, code):
    """Read EVIOCGABS(code); return (min, max) of the absolute axis."""
    nr = 0x40 + code
    num = (2 << 30) | (24 << 16) | (ord('E') << 8) | nr  # _IOR('E', 0x40+code, input_absinfo)
    buf = bytearray(24)
    fcntl.ioctl(fd, num, buf, True)
    _val, mn, mx, _fuzz, _flat, _res = struct.unpack('iiiiii', buf)
    return mn, mx


def emit(fd, etype, code, value):
    """Write one input_event (timeval zeroed)."""
    fd.write(struct.pack('llHHi', 0, 0, etype, code, value))


def find_touchscreen():
    """Return /dev/input/eventN of the first device reporting ABS_MT_POSITION_X."""
    name = None
    with open('/proc/bus/input/devices') as f:
        for line in f:
            if line.startswith('H: Handlers='):
                name = next((h for h in line.split('=', 1)[1].split()
                             if h.startswith('event')), None)
            elif line.startswith('B: ABS=') and name:
                if (int(line.split('=', 1)[1].replace(' ', ''), 16) >> ABS_MT_POSITION_X) & 1:
                    return '/dev/input/' + name
    raise OSError('no multitouch device in /proc/bus/input/devices')


class Touch:
    """Open the touchscreen and translate pixel coords to ABS device units.

    Use as a context manager so the device fd is always closed:
        with Touch() as t:
            t.down(x, y); ...; t.up()
    """

    def __init__(self, dev=None, screen_w=None, screen_h=None):
        dev = dev or find_touchscreen()
        self.fd = open(dev, 'wb', buffering=0)
        with open(dev, 'rb', buffering=0) as raw:
            self.xmin, self.xmax = eviocgabs(raw.fileno(), ABS_MT_POSITION_X)
            self.ymin, self.ymax = eviocgabs(raw.fileno(), ABS_MT_POSITION_Y)
        self.screen_w = screen_w or self.xmax - self.xmin + 1
        self.screen_h = screen_h or self.ymax - self.ymin + 1

    def ax(self, px):
        return self.xmin + (self.xmax - self.xmin) * px // (self.screen_w - 1)

    def ay(self, py):
        return self.ymin + (self.ymax - self.ymin) * py // (self.screen_h - 1)

    def _ev(self, etype, code, value):
        emit(self.fd, etype, code, value)

    def down(self, px, py):
        self._ev(EV_ABS, ABS_MT_SLOT, 0)
        self._ev(EV_ABS, ABS_MT_TRACKING_ID, 1)
        self._ev(EV_ABS, ABS_MT_POSITION_X, self.ax(px))
        self._ev(EV_ABS, ABS_MT_POSITION_Y, self.ay(py))
        self._ev(EV_KEY, BTN_TOUCH, 1)
        self._ev(EV_ABS, ABS_X, self.ax(px))
        self._ev(EV_ABS, ABS_Y, self.ay(py))
        self._ev(EV_SYN, SYN_REPORT, 0)

    def move(self, px, py):
        self._ev(EV_ABS, ABS_MT_SLOT, 0)
        self._ev(EV_ABS, ABS_MT_POSITION_X, self.ax(px))
        self._ev(EV_ABS, ABS_MT_POSITION_Y, self.ay(py))
        self._ev(EV_ABS, ABS_X, self.ax(px))
        self._ev(EV_ABS, ABS_Y, self.ay(py))
        self._ev(EV_SYN, SYN_REPORT, 0)

    def up(self):
        self._ev(EV_ABS, ABS_MT_SLOT, 0)
        self._ev(EV_ABS, ABS_MT_TRACKING_ID, -1)
        self._ev(EV_KEY, BTN_TOUCH, 0)
        self._ev(EV_SYN, SYN_REPORT, 0)

    def close(self):
        self.fd.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
