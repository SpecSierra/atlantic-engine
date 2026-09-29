#!/usr/bin/env python3
"""Tap-to-first-content latency, interleaved A/B.

Usage:  tapbench.py <spec.json>

spec = {
  "targets": ["https://example.org/", "https://en.wikipedia.org/wiki/Special:Search?search=x"],
  "reps": 5, "idle": 6, "tap": [515, 1100],
  "arms": [ {"label":"preconnect-OFF","env":{...}}, {"label":"preconnect-ON","env":{...}} ]
}

Each run: relaunch (cold browser, arms INTERLEAVED) -> open a local page that is one
full-viewport link -> idle `idle` s (governor drops, like a real first touch after
a pause) -> real touchscreen tap -> read the destination's Navigation/Paint Timing.

Everything is on the DEVICE wall clock (tap stamps from evtouch, performance.timeOrigin
from the browser), so no host<->device offset enters the numbers.
Metrics, all ms from touch-UP (the click fires on touchend):
  nav    touch-up -> navigation start   (UI/input/dispatch latency)
  ttfb   touch-up -> responseStart
  fp     touch-up -> first-paint
  fcp    touch-up -> first-contentful-paint   <- the headline
  conn   connectEnd - connectStart            (0 => connection was already open/preconnected)
Rule 0: put the same arm twice (A/A) to measure the noise floor before believing a delta.
"""
import asyncio
import json
import re
import statistics
import sys
import time

sys.path.insert(0, "/release/workspace/atlantic-engine/scripts/devtools")
from atldbg import cdp, device  # noqa: E402

PAGE = """<!doctype html><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<style>html,body{margin:0;height:100%%;background:#123}a{display:block;width:100%%;height:100vh;
color:#fff;font:32px sans-serif;text-align:center;line-height:100vh}</style>
<a href="%s">tap</a>"""

READ_JS = """(function(){
 var n=performance.getEntriesByType('navigation')[0]||{};
 var p={};performance.getEntriesByType('paint').forEach(function(e){p[e.name]=e.startTime});
 return JSON.stringify({origin:performance.timeOrigin,fp:p['first-paint'],fcp:p['first-contentful-paint'],
  rs:n.responseStart,cs:n.connectStart,ce:n.connectEnd,ds:n.domainLookupStart,de:n.domainLookupEnd,
  fe:n.fetchStart,dcl:n.domContentLoadedEventEnd,url:location.href})})()"""

TOUCH_FILES = ("/root/evtouch.py",
               "/release/workspace/atlantic-engine/scripts/devtools/scrollbench/tapstamp.py")


def host_of(url):
    return re.sub(r"^https?://([^/]+).*", r"\1", url)


async def read_dest(host, timeout=25):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        await asyncio.sleep(1.0)
        try:
            async with cdp.connect_session(match=host) as s:
                raw = await s.eval_value(READ_JS, default=None)
            if raw:
                d = json.loads(raw)
                last = d
                if d.get("fcp") is not None and host in d["url"]:
                    return d
        except Exception as e:  # tab mid-navigation / inspector reconnecting
            last = last or {"err": str(e)}
    return last


async def one_run(target, env, idle, tap):
    page = "/tmp/tapbench.html"
    # unique query per run: the disk cache survives a relaunch, and a cached
    # destination (deliveryType "cache") has zeroed connect timings + no network
    bust = ("&" if "?" in target else "?") + "tb=%d" % (time.time() * 1000)
    open("/tmp/tapbench.local.html", "w").write(PAGE % (target + bust))
    device.scp_to("/tmp/tapbench.local.html", page)
    device.launch("file://" + page, extra_env=env, wait=4.0)
    if device.processes()["ui"] is None:
        raise RuntimeError("no UI process")
    time.sleep(idle)
    out = device.ssh(f"echo root | devel-su -p python3 /tmp/tapstamp.py {tap[0]} {tap[1]}",
                     session_env=True, timeout=30).stdout
    m = re.search(r"down=([\d.]+) up=([\d.]+)", out)
    if not m:
        raise RuntimeError("no tap stamps: " + out.strip()[:120])
    up = float(m.group(2))
    d = await read_dest(host_of(target))
    if not d or d.get("fcp") is None:
        raise RuntimeError(f"no paint timing from destination: {d}")
    o = d["origin"] / 1000.0

    def ms(rel):
        return (o + rel / 1000.0 - up) * 1000.0 if rel is not None else None
    return {"nav": (o - up) * 1000.0, "ttfb": ms(d["rs"]), "fp": ms(d.get("fp")),
            "fcp": ms(d["fcp"]), "conn": (d["ce"] - d["cs"]) if d["ce"] and d["cs"] else 0.0}


def med(rows, k):
    v = [r[k] for r in rows if r.get(k) is not None]
    return statistics.median(v) if v else None


async def main():
    spec = json.load(open(sys.argv[1]))
    targets, reps = spec["targets"], spec.get("reps", 5)
    idle, tap, arms = spec.get("idle", 6), spec.get("tap", [515, 1100]), spec["arms"]
    for f in TOUCH_FILES:
        device.scp_to(f, "/tmp/")
    res = {(a["label"], t): [] for a in arms for t in targets}
    for rep in range(reps):
        for t in targets:
            for arm in arms:  # interleaved
                print(f"[{rep+1}/{reps}] {arm['label']} {host_of(t)} …", flush=True)
                try:
                    r = await one_run(t, arm.get("env", {}), idle, tap)
                except Exception as e:
                    print(f"   ! {e}"); continue
                res[(arm["label"], t)].append(r)
                print("   " + " ".join(f"{k}={r[k]:.0f}" for k in ("nav", "ttfb", "fp", "fcp", "conn")
                                       if r[k] is not None))
    keys = ("nav", "ttfb", "fp", "fcp", "conn")
    print("\n" + "=" * 78 + "\nmedian ms from touch-up\n")
    for t in targets:
        print(host_of(t))
        print(f"  {'arm':18s}" + "".join(f"{k:>9s}" for k in keys) + f"{'n':>4s}   fcp min…max")
        base = None
        for arm in arms:
            rows = res[(arm["label"], t)]
            if not rows:
                print(f"  {arm['label']:18s} (no data)"); continue
            line = f"  {arm['label']:18s}" + "".join(
                f"{med(rows,k):9.0f}" if med(rows, k) is not None else f"{'-':>9s}" for k in keys)
            f = sorted(r["fcp"] for r in rows)
            print(line + f"{len(rows):4d}   {f[0]:.0f}…{f[-1]:.0f}")
            if base is None:
                base = med(rows, "fcp")
            elif base:
                print(f"  {'':18s}  fcp vs first arm: {med(rows,'fcp')-base:+.0f} ms ({100*(med(rows,'fcp')-base)/base:+.1f}%)")


if __name__ == "__main__":
    asyncio.run(main())
