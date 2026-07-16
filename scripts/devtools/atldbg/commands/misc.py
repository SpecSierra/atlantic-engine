"""misc — small lifecycle / convenience commands: launch, open, eval, shot, log, ps."""
from __future__ import annotations

import asyncio
import json

from .. import cdp, device, ui


def _parse_env(pairs):
    """--env KEY=VAL … → dict, for A/B-ing the engine's env flags."""
    env = {}
    for pair in pairs or []:
        key, sep, value = pair.partition("=")
        if not sep or not key:
            raise SystemExit(f"--env expects KEY=VALUE, got {pair!r}")
        env[key] = value
    return env


def launch(args):
    ui.heading("launch")
    ui.info("(re)starting the browser with the remote inspector enabled…")
    extra_env = _parse_env(getattr(args, "env", None))
    for k, v in extra_env.items():
        ui.info(f"env {k}={v}")
    device.launch(args.url, inspector=not args.no_inspector,
                  gst_debug=args.gst_debug, extra_env=extra_env)
    procs = device.processes()
    if procs["ui"]:
        ui.ok(f"UI pid {procs['ui']}, WebProcess {procs['web']}")
        if not args.no_inspector:
            ui.info(f"inspector on device :{device.INSPECTOR_PORT} "
                    "(atldbg opens the tunnel automatically)")
    else:
        ui.err("browser did not come up — see device /tmp/atl.log")
        print(ui.c(device.log_tail(20), "grey"))
        return 1
    return 0


def open_url(args):
    device.open_url(args.url)
    ui.ok(f"navigated to {args.url}")
    return 0


def shot(args):
    path = device.screenshot(args.path)
    ui.ok(f"screenshot → {path}")
    return 0


def log(args):
    print(device.log_tail(args.n))
    return 0


def ps(args):
    procs = device.processes()
    ui.heading("processes")
    ui.kv("UIProcess", procs["ui"] or ui.c("not running", "red"))
    ui.kv("WebProcess", procs["web"] or "-")
    ui.kv("NetworkProcess", procs["network"] or "-")
    ui.kv("GPUProcess", procs["gpu"] or "-")
    return 0


def tabs(args):
    ui.heading("tabs (inspectable)")
    with device.tunnel():
        targets = cdp.list_targets()
    if not targets:
        ui.err("no inspectable tabs (browser not running with the inspector?)")
        return 1
    for i, t in enumerate(targets):
        print(f"  [{i}] {t['url']}  {ui.c(t['path'], 'grey')}")
    ui.info("commands target the visible tab by default; use --tab <substr> to pick one.")
    return 0


def _eval(args):
    async def go():
        async with cdp.connect_session(match=getattr(args, "tab", None)) as s:
            inner = await s.evaluate(args.js, user_gesture=args.gesture, timeout=20)
            if inner is None:
                ui.err("(timeout waiting for eval reply)")
                return 1
            res = inner.get("result", inner)
            print(json.dumps(res, indent=2)[:8000])
            return 0
    return asyncio.run(go())


def eval_js(args):
    return _eval(args)
