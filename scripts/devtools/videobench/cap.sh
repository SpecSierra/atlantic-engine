#!/bin/bash
# cap.sh <outfile> [seconds] — capture a window of /tmp/atl.log from the device and summarize
OUT="${1:?}"; W="${2:-20}"
SSH="sshpass -p root ssh -4 -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null defaultuser@localhost"
$SSH "S=\$(wc -c </tmp/atl.log); sleep $W; E=\$(wc -c </tmp/atl.log); tail -c \$((E-S)) /tmp/atl.log" > "$OUT" 2>/dev/null
python3 - "$OUT" <<'EOF'
import re,sys
L=open(sys.argv[1]).read().splitlines()
def ev(pat): return [float(m.group(1)) for l in L for m in [re.search(pat,l)] if m]
comp=ev(r'web composite t=([\d.]+)'); paint=ev(r'ui paint t=([\d.]+)')
req2=[float(re.search(r't=([\d.]+)',l).group(1)) for l in L if 'reqcomp r=2' in l]
tp=[(float(re.search(r't=([\d.]+)',l).group(1)),int(re.search(r'dirty=(\d+)',l).group(1))) for l in L if 'tilepaint' in l]
def d(a,label):
    if len(a)<3: print(f"{label}: too few ({len(a)})"); return
    x=sorted(a[i+1]-a[i] for i in range(len(a)-1)); n=len(x)
    span=a[-1]-a[0]
    print(f"{label}: {len(a)} ev, {len(a)/span*1000:.1f}/s  p50={x[n//2]:.1f} p90={x[int(n*.9)]:.1f} p95={x[int(n*.95)]:.1f} max={x[-1]:.1f}")
d(req2,"videoframe req (source)"); d(comp,"web composite"); d(paint,"ui paint   ")
big=[t for t,dd in tp if dd>=10]
freezes=[x for i,x in enumerate([comp[i+1]-comp[i] for i in range(len(comp)-1)]) if x>100]
print(f"full-viewport tilepaints (dirty>=10): {len(big)}   composite freezes >100ms: {len(freezes)} {['%.0f'%f for f in freezes]}")
EOF
