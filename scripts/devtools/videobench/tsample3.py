#!/usr/bin/env python3
"""What is the compositor thread actually blocked in?

Polls /proc/<tid>/syscall (+ /proc/<tid>/stack when readable) for the compositor
and main threads at high rate on CLOCK_MONOTONIC, so samples can be correlated
with ATLANTIC_FRAME_TRACE stall windows without attaching a debugger.

Needs root for syscall/stack (run under plain `devel-su`, not `-p`).

Usage: tsample3.py <seconds> [interval_ms]
Output: t_ms | comm state syscall_nr sp pc | ... ; and a '#stack' line per sample
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

WANT = ('eadedCompositor', 'WPEWebProcess')
tids = []
for t in sorted(os.listdir('/proc/%s/task' % pid)):
    try:
        c = open('/proc/%s/task/%s/comm' % (pid, t)).read().strip()
    except Exception:
        continue
    if c in WANT:
        tids.append((t, c))
        if len(tids) >= 4:
            break
print('# pid=%s tids=%s' % (pid, tids))

def rd(p):
    try:
        return open(p).read().strip()
    except Exception:
        return '?'

end = time.time() + dur
out = []
while time.time() < end:
    t = time.clock_gettime(time.CLOCK_MONOTONIC) * 1000.0
    fields = []
    for tid, comm in tids:
        base = '/proc/%s/task/%s/' % (pid, tid)
        st = rd(base + 'stat')
        state = st[st.rindex(')') + 2] if ')' in st else '?'
        sc = rd(base + 'syscall').split()
        # syscall file: "nr arg0..arg5 sp pc"  or "running"
        nr = sc[0] if sc else '?'
        fields.append('%s:%s:%s' % (comm[:6], state, nr))
        if comm == 'eadedCompositor':
            stk = rd(base + 'stack')
            if stk and stk != '?':
                top = ' | '.join(l.split(']')[-1].strip() for l in stk.splitlines()[:4])
                fields.append('STACK[%s]' % top)
    out.append('%.1f %s' % (t, ' '.join(fields)))
    time.sleep(iv)
print('\n'.join(out))
