#!/usr/bin/env python3
"""Sample a WebProcess thread's run-state at high rate, on CLOCK_MONOTONIC (the
same clock ATLANTIC_FRAME_TRACE stamps with), so stalls in the ftrace stream can
be classified as CPU-burning vs blocked-in-syscall without attaching a debugger.

Usage: tsample.py <comm-substring> <seconds> [interval_ms]
Output (stdout, one line per sample):  t_ms state utime stime wchan
"""
import os, sys, time, glob

comm_want = sys.argv[1]
dur = float(sys.argv[2])
iv = float(sys.argv[3]) / 1000.0 if len(sys.argv) > 3 else 0.020

pid = None
for p in glob.glob('/proc/[0-9]*/cmdline'):
    try:
        if b'WPEWebProcess' in open(p, 'rb').read():
            cand = p.split('/')[2]
            # pick the one with the most threads (the real content process)
            n = len(os.listdir('/proc/%s/task' % cand))
            if pid is None or n > pid[1]:
                pid = (cand, n)
    except Exception:
        pass
pid = pid[0]

tid = None
for t in os.listdir('/proc/%s/task' % pid):
    try:
        if comm_want in open('/proc/%s/task/%s/comm' % (pid, t)).read().strip():
            tid = t
            break
    except Exception:
        pass
if not tid:
    print('no thread matching %r in pid %s' % (comm_want, pid), file=sys.stderr)
    sys.exit(1)
print('# pid=%s tid=%s comm=%s' % (pid, tid, open('/proc/%s/task/%s/comm' % (pid, tid)).read().strip()))

stat_p = '/proc/%s/task/%s/stat' % (pid, tid)
wchan_p = '/proc/%s/task/%s/wchan' % (pid, tid)
end = time.time() + dur
out = []
while time.time() < end:
    t = time.clock_gettime(time.CLOCK_MONOTONIC) * 1000.0
    try:
        f = open(stat_p).read()
        # comm may contain spaces/parens; split after the last ')'
        rest = f[f.rindex(')') + 2:].split()
        state, utime, stime = rest[0], rest[11], rest[12]
        try:
            w = open(wchan_p).read().strip() or '-'
        except Exception:
            w = '-'
        out.append('%.1f %s %s %s %s' % (t, state, utime, stime, w))
    except Exception:
        pass
    time.sleep(iv)
print('\n'.join(out))
