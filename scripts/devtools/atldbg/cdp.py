"""CDP / WebKit-inspector helpers built on the existing Inspector client.

The low-level Target-wrapped protocol plumbing already lives in wkinspector.py
(connect, target discovery, wrap/unwrap, evaluate).  This module adds the bits
the debugger needs on top of it: enabling domains, pumping the event stream for
a fixed duration, and a couple of convenience collectors.

connect_session() opens the SSH tunnel *and* the websocket and discovers the page
target in one step, so callers never have to think about either.
"""
from __future__ import annotations

import asyncio
import contextlib
import json
import re
import time
import urllib.request

import websockets  # noqa: F401  (ensures the dep is present with a clear error)
from wkinspector import DEFAULT_URL, MAX_SIZE, Inspector

from . import device


class Session:
    """A connected, target-discovered inspector session with event pumping."""

    def __init__(self, insp: Inspector):
        self.insp = insp
        self._handlers = []  # list of (predicate, callback)

    # -- domain control -------------------------------------------------------
    async def enable(self, *domains, **params_per_domain):
        """Enable one or more inspector domains on the page target.

        enable("Console", "Network")  or  enable("ScriptProfiler",
        ScriptProfiler={"includeSamples": True}) for per-domain params.
        """
        for d in domains:
            await self.insp.send_to_target(f"{d}.enable", params_per_domain.get(d))

    async def call(self, method, params=None, *, wait=False, timeout=8):
        """Send a page-level command.  wait=True returns the matching reply dict."""
        want = await self.insp.send_to_target(method, params)
        if wait:
            return await self.insp.await_inner_reply(want, timeout=timeout)
        return want

    async def evaluate(self, js, **kw):
        return await self.insp.evaluate(js, **kw)

    async def eval_value(self, js, default=None, **kw):
        """Runtime.evaluate and unwrap to the raw JS value (returnByValue)."""
        inner = await self.insp.evaluate(js, **kw)
        if not inner:
            return default
        res = inner.get("result", {}).get("result", {})
        return res.get("value", default)

    # -- event pump -----------------------------------------------------------
    def on(self, method_or_pred, callback):
        """Register a handler for inner events.

        method_or_pred is either an exact method string ("Console.messageAdded")
        or a predicate(method:str)->bool.  callback receives the inner params dict.
        """
        if callable(method_or_pred):
            pred = method_or_pred
        else:
            pred = lambda m, _w=method_or_pred: m == _w
        self._handlers.append((pred, callback))

    async def pump(self, duration: float, *, idle_timeout: float = 2.0):
        """Read frames for `duration` seconds, dispatching inner events to handlers.

        Returns the number of inner events dispatched.  Each inner event is
        unwrapped from Target.dispatchMessageFromTarget before dispatch.
        """
        deadline = time.monotonic() + duration
        n = 0
        while time.monotonic() < deadline:
            remaining = max(0.1, min(idle_timeout, deadline - time.monotonic()))
            m = await self.insp.recv(remaining)
            if m is None:
                continue
            if m.get("method") != "Target.dispatchMessageFromTarget":
                continue
            inner = json.loads(m["params"]["message"])
            method = inner.get("method")
            if method is None:
                continue
            params = inner.get("params", {})
            for pred, cb in self._handlers:
                if pred(method):
                    cb(params)
                    n += 1
        return n


def list_targets(port: int = device.INSPECTOR_PORT):
    """Inspectable tabs from the inspector HTTP index, as [{path,url,ws}].

    Each Atlantic tab is a *separate* websocket endpoint (e.g. /socket/1/1/WebPage),
    not a multiplexed target — so this index is the only way to enumerate tabs.
    Must be called with the tunnel open.
    """
    html = urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=6).read().decode(
        "utf-8", "replace")
    urls = re.findall(r'targeturl">([^<]*)', html)
    paths = re.findall(r"(/socket/\d+/\d+/WebPage)", html)
    out = []
    for path, url in zip(paths, urls):
        out.append({"path": path, "url": url.strip(),
                    "ws": f"ws://127.0.0.1:{port}{path}"})
    return out


async def _open(ws_url):
    ws = await websockets.connect(ws_url, max_size=MAX_SIZE)
    insp = Inspector(ws)
    tid, _ = await insp.discover_target(timeout=3)
    if tid:
        with contextlib.suppress(Exception):
            await insp.send("Target.resume", {"targetId": tid})
    return ws, insp, tid


async def _select(targets, prefer_visible, match):
    """Open the right tab's websocket; return (ws, Session, chosen dict).

    match: substring to require in the tab URL.  prefer_visible: pick the tab
    whose document is not hidden (the foreground one), else the first.
    """
    # WebExtension background pages are offscreen views that always report
    # document.hidden=false, so they would win the visible-tab race.
    if not match:
        targets = [t for t in targets if not t["url"].startswith("atlantic-extension://")] or targets
    cands = [t for t in targets if (match.lower() in t["url"].lower())] if match else targets
    if not cands:
        raise RuntimeError(f"no inspectable tab matches {match!r}; tabs: "
                           + ", ".join(t["url"] for t in targets))
    if not prefer_visible and len(cands) == 1:
        ws, insp, tid = await _open(cands[0]["ws"])
        if not tid:
            await ws.close()
            raise RuntimeError("tab announced no page target")
        return ws, Session(insp), cands[0]

    first = None
    for t in cands:
        ws, insp, tid = await _open(t["ws"])
        if not tid:
            await ws.close()
            continue
        if not prefer_visible:
            return ws, Session(insp), t
        try:
            inner = await insp.evaluate("document.hidden", timeout=4)
            hidden = inner and inner.get("result", {}).get("result", {}).get("value")
        except Exception:
            hidden = None
        if hidden is False:
            return ws, Session(insp), t
        if first is None:
            first = (ws, Session(insp), t)
        else:
            await ws.close()
    if first:
        return first
    raise RuntimeError("no inspectable tab responded")


@contextlib.asynccontextmanager
async def connect_session(url: str | None = None, *, manage_tunnel: bool = True,
                          discover_timeout: int = 4, prefer_visible: bool = True,
                          match: str | None = None):
    """Open tunnel, pick the right tab, yield a connected Session.

    By default selects the *visible* tab (background tabs are document.hidden=true
    under the engine's visibility throttling, which also suspends their rAF —
    debugging the wrong tab is a classic footgun).  Pass match="example.com" to
    target a specific tab by URL substring.
    """
    tun = device.tunnel() if manage_tunnel else contextlib.nullcontext()
    with tun:
        if url:  # explicit websocket URL override
            ws, insp, tid = await _open(url)
            if not tid:
                await ws.close()
                raise RuntimeError("no page target at " + url)
            try:
                yield Session(insp)
            finally:
                await ws.close()
            return
        targets = list_targets()
        if not targets:
            raise RuntimeError(
                "no inspectable tabs. Is the browser running with "
                "WEBKIT_INSPECTOR_HTTP_SERVER set?  (try: atldbg launch <url>)")
        ws, session, chosen = await _select(targets, prefer_visible, match)
        try:
            session.target = chosen
            yield session
        finally:
            await ws.close()
