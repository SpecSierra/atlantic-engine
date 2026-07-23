#!/usr/bin/env python3
"""Sample per-thread run state + CPU for a set of WebProcess threads at high rate
on CLOCK_MONOTONIC (same clock as ATLANTIC_FRAME_TRACE).

Usage: tsample2.py <seconds> [interval_ms]
Output: t_ms <tid:comm:state:utime:stime> ...  (one line per sample)
"""
import os, sys, time, glob

dur = float(sys.argv[1])
iv = (float(sys.argv[2]) / 1000.0) if len(sys.argv) > 2 else 0.020

pid = None
for p in glob.glob('/proc/[0-9]*/cmdline'):
    try:
        if b'WPEWebProcess' in open(p, 'rb').read():
            cand = p.split('/')[2]
            n = len(os.listdir('/proc/%s/task' % cand))
            if pid is None or n > pid[1]:
                pid = (cand, n)
    except Exception:
        pass
pid = pid[0]

WANT = ('WPEWebProcess', 'eadedCompositor', 'Skia', 'vqueue', 'droidvdec', 'DroidMedia')
tids = []
for t in sorted(os.listdir('/proc/%s/task' % pid)):
    try:
        c = open('/proc/%s/task/%s/comm' % (pid, t)).read().strip()
    except Exception:
        continue
    if any(w in c for w in WANT):
        tids.append((t, c, '/proc/%s/task/%s/stat' % (pid, t)))
print('# pid=%s tids=%s' % (pid, ','.join('%s:%s' % (t, c) for t, c, _ in tids)))

end = time.time() + dur
out = []
while time.time() < end:
    t = time.clock_gettime(time.CLOCK_MONOTONIC) * 1000.0
    parts = []
    for tid, comm, sp in tids:
        try:
            f = open(sp).read()
            rest = f[f.rindex(')') + 2:].split()
            parts.append('%s:%s:%s:%s:%s' % (tid, comm, rest[0], rest[11], rest[12]))
        except Exception:
            pass
    out.append('%.1f %s' % (t, ' '.join(parts)))
    time.sleep(iv)
print('\n'.join(out))
