#!/usr/bin/env python3
"""Analyze ATLANTIC_FRAME_TRACE markers to localize scroll freezes.

Frame handoff stages (all CLOCK_MONOTONIC ms, same clock in both processes):
  web composite  - WebProcess ThreadedCompositor produced a frame
  ui recv        - qt5 plugin received the exported frame (displayImage)
  ui paint       - Qt sampled the frame texture into the scene graph
  ui ack         - qt5 plugin acked frame-complete back to the WebProcess

A screen freeze = a gap in the 'ui paint' stream (nothing new reached the
screen). For each freeze we ask what the OTHER stages did during the gap:
  composite stops           -> PRODUCTION stall (compositor not compositing)
  composite fires, no recv   -> HANDOFF/EXPORT stall (frame stuck in transit)
  recv fires, paint/ack lag  -> PRESENT stall (Qt not rendering/acking)

Usage:
  ftrace.py                       # pull /tmp/atl.log from device, analyze
  ftrace.py /path/to/log          # analyze a local log
  ftrace.py --freeze-ms 120       # gap threshold for "freeze" (default 100)
"""
import re, sys, subprocess

FREEZE_MS = 100.0
args = [a for a in sys.argv[1:]]
if "--freeze-ms" in args:
    i = args.index("--freeze-ms"); FREEZE_MS = float(args[i+1]); del args[i:i+2]
local = args[0] if args else None

if local:
    text = open(local).read()
else:
    SSH = ("sshpass -p root ssh -p 2222 -o StrictHostKeyChecking=no "
           "-o UserKnownHostsFile=/dev/null defaultuser@localhost")
    text = subprocess.run(SSH.split() + ["cat /tmp/atl.log"],
                          capture_output=True, text=True).stdout

# parse: [ftrace] <proc> <stage> t=<ms>
ev = []  # (t, stage)
pat = re.compile(r"\[ftrace\]\s+(\w+)\s+(\w+)\s+t=([\d.]+)")
for m in pat.finditer(text):
    proc, stage, t = m.group(1), m.group(2), float(m.group(3))
    ev.append((t, f"{proc}.{stage}"))
ev.sort()
if not ev:
    print("no [ftrace] markers found — is ATLANTIC_FRAME_TRACE=1 set on launch?")
    sys.exit(0)

streams = {}
for t, s in ev:
    streams.setdefault(s, []).append(t)

span = ev[-1][0] - ev[0][0]
print(f"trace span {span/1000:.1f}s, {len(ev)} events")
print("\n== per-stage rate + worst inter-event gap ==")
for s in sorted(streams):
    ts = streams[s]
    gaps = [b - a for a, b in zip(ts, ts[1:])]
    rate = len(ts) / (span/1000) if span else 0
    worst = max(gaps) if gaps else 0
    p95 = sorted(gaps)[int(len(gaps)*0.95)] if gaps else 0
    print(f"  {s:16s} {len(ts):5d} ev  {rate:5.1f}/s   gap p95={p95:6.1f}ms  worst={worst:7.1f}ms")

# freezes = gaps in ui.paint (fallback ui.recv) beyond threshold
# events carrying named numeric fields (w=, r=, p=, dirty=, new=, wait=)
evx = []  # (t, stage, num_for_reason, kv_dict)
pat2 = re.compile(r"\[ftrace\]\s+(\w+)\s+([\w-]+)(.*?)\s+t=([\d.]+)")
for m in pat2.finditer(text):
    kv = dict(re.findall(r"(\w+)=(\d+)", m.group(3)))
    kv = {k: int(v) for k, v in kv.items()}
    num = kv.get("r", kv.get("w"))
    evx.append((float(m.group(4)), f"{m.group(1)}.{m.group(2)}", num, kv))
evx.sort(key=lambda x: x[0])
def kvs_in_gap(stage, a, b): return [kv for t, s, n, kv in evx if s == stage and a < t <= b]
def in_gap(stage, a, b): return [(t, n) for t, s, n, kv in evx if s == stage and a < t <= b]

comp = streams.get("web.composite", [])
REASON = {0:"?0", 1:"RenderingUpdate", 2:"Animation", 3:"Scrolling",
          4:"TileDrain", 5:"Scene", 6:"?6", 7:"?7", 8:"?8"}

# The freeze is the ack->composite production gap. Anchor on web.composite gaps.
print(f"\n== production freezes (web-composite gap > {FREEZE_MS:.0f}ms) ==")
freezes = [(a, b) for a, b in zip(comp, comp[1:]) if b - a > FREEZE_MS]
if not freezes:
    print("  none")
freezes.sort(key=lambda p: p[1]-p[0], reverse=True)
from collections import Counter
tally = Counter()
for a, b in freezes[:14]:
    dur = b - a
    reqs = in_gap("web.reqcomp", a, b)
    scheds = in_gap("web.sched", a, b)
    rupds = in_gap("web.rupd", a, b)
    rupdEnds = in_gap("web.rupd-end", a, b)
    waiting = sum(1 for _, w in scheds if w == 1)
    scrolls = sum(1 for t, s, n, kv in evx if s == "web.scrollapply" and a < t <= b)
    # tile handshake: paint passes + pendingTiles trajectory during the gap
    tilepaints = kvs_in_gap("web.tilepaint", a, b)
    tilechanges = kvs_in_gap("web.tileschange", a, b)
    dirtySum = sum(kv.get("dirty", 0) for kv in tilepaints)
    pend = [kv.get("p") for kv in tilechanges if "p" in kv]
    pend_desc = f"{min(pend)}..{max(pend)}" if pend else "-"
    if tilepaints or (pend and min(pend) < max(pend)):
        v = "TILES PAINTING (genuinely slow/treadmill; pending decreasing or paint active)"
    elif not reqs and not scheds and not scrolls:
        v = "SCHEDULER STARVED"
    elif scheds and not rupds:
        v = "WAITING-FOR-RENDERER (isWaitingForTiles stuck, NO tile paint = handshake bug)"
    elif rupds:
        v = "MAIN-UPDATE GATE, no tile paint (stuck flag)"
    else:
        v = "mixed"
    tally[v.split(" (")[0]] += 1
    print(f"  {dur:7.0f}ms @ t={a:.0f}  sched={len(scheds)}(w1={waiting}) rupd={len(rupds)}/end={len(rupdEnds)} scroll={scrolls} tilepaint={len(tilepaints)}(dirty={dirtySum}) tileschg={len(tilechanges)} p[{pend_desc}]  -> {v}")
print("\n== verdict ==")
for k, n in tally.most_common():
    print(f"  {n:3d} freezes: {k}")
