#!/usr/bin/env python3
"""Shared client for the WPE WebKit remote inspector.

The WPE inspector speaks a "Target-wrapped" flavour of the protocol: outer
commands target the inspector server, and page-level commands (Runtime.*,
Console.*) must be wrapped in Target.sendMessageToTarget and arrive back inside
Target.dispatchMessageFromTarget frames. This module centralises the connect,
target-discovery and wrap/unwrap boilerplate that wkeval/wkinspect/wkconsole/
wkdump used to each copy.

Needs a tunnel to the device:  ssh -L 9224:127.0.0.1:9224 ...
"""
import asyncio
import contextlib
import json

import websockets

DEFAULT_URL = "ws://127.0.0.1:9224/socket/1/1/WebPage"
MAX_SIZE = 50 * 1024 * 1024


class Inspector:
    def __init__(self, ws):
        self.ws = ws
        self._outer = 0
        self._inner = 0
        self.target_id = None

    async def recv(self, timeout=8):
        """Next decoded JSON frame, or None on timeout."""
        try:
            return json.loads(await asyncio.wait_for(self.ws.recv(), timeout))
        except asyncio.TimeoutError:
            return None

    async def send(self, method, params=None):
        """Send an outer (server-level) command; return its id."""
        self._outer += 1
        await self.ws.send(json.dumps({"id": self._outer, "method": method,
                                       "params": params or {}}))
        return self._outer

    async def send_to_target(self, method, params=None):
        """Send a page-level command wrapped for the discovered target; return inner id."""
        self._inner += 1
        msg = json.dumps({"id": self._inner, "method": method, "params": params or {}})
        await self.send("Target.sendMessageToTarget",
                        {"targetId": self.target_id, "message": msg})
        return self._inner

    async def discover_target(self, attempts=20, timeout=2):
        """Provoke and read Target.targetCreated announcements.

        Returns (target_id, {id: type}). Prefers the 'page' target, falling back
        to the first announced target. Stores the choice on self.target_id.
        """
        await self.send("Target.exists")
        targets = {}
        first = None
        for _ in range(attempts):
            m = await self.recv(timeout)
            if m is None:
                break
            if m.get("method") == "Target.targetCreated":
                ti = m["params"]["targetInfo"]
                targets[ti["targetId"]] = ti["type"]
                if first is None:
                    first = ti["targetId"]
                if ti["type"] == "page":
                    break
        tid = next((t for t, ty in targets.items() if ty == "page"), None) or first
        self.target_id = tid
        return tid, targets

    async def await_inner_reply(self, want_id, attempts=20, timeout=8):
        """Read frames until the wrapped reply with id == want_id; return its inner dict."""
        for _ in range(attempts):
            m = await self.recv(timeout)
            if m is None:
                return None
            if m.get("method") == "Target.dispatchMessageFromTarget":
                inner = json.loads(m["params"]["message"])
                if inner.get("id") == want_id:
                    return inner
        return None

    async def evaluate(self, js, by_value=True, user_gesture=False,
                       attempts=20, timeout=8):
        """Runtime.evaluate on the target; return the inner reply dict (or None)."""
        params = {"expression": js, "returnByValue": by_value}
        if user_gesture:
            params["emulateUserGesture"] = True
        want = await self.send_to_target("Runtime.evaluate", params)
        return await self.await_inner_reply(want, attempts, timeout)


@contextlib.asynccontextmanager
async def connect(url=DEFAULT_URL):
    async with websockets.connect(url, max_size=MAX_SIZE) as ws:
        yield Inspector(ws)
