"""Device access layer for Atlantic Browser debugging.

Centralises every piece of "how to talk to the Xperia 10 II dev device" lore
that used to live scattered across the README and atl.sh: the sshpass invocation,
the lipstick session env, screenshots, the openUrl D-Bus method, (re)launching the
browser with the right env, process discovery, and the inspector SSH tunnel.

Everything here is host-side. Nothing in this module imports websockets or the
CDP layer, so it stays usable on its own (process sampling, log tailing, screen-
shots) even when the remote inspector is not in play.
"""
from __future__ import annotations

import contextlib
import shlex
import socket
import subprocess
import time

# ── Connection constants (see README "Device access") ────────────────────────
HOST = "localhost"
PORT = 2222
USER = "defaultuser"
PASSWORD = "root"
UID = 100000
INSPECTOR_PORT = 9224

# lipstick user-session env, needed for every dbus / wayland-aware command.
SESSION_ENV = (
    f"export XDG_RUNTIME_DIR=/run/user/{UID}; "
    f"export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{UID}/dbus/user_bus_socket; "
)

_SSH_BASE = [
    "sshpass", "-p", PASSWORD,
    "ssh", "-p", str(PORT),
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "LogLevel=ERROR",
    "-o", "ConnectTimeout=6",
]
_SCP_BASE = [
    "sshpass", "-p", PASSWORD,
    "scp", "-P", str(PORT),
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "LogLevel=ERROR",
]
_TARGET = f"{USER}@{HOST}"


class DeviceError(RuntimeError):
    pass


def ssh(cmd: str, *, session_env: bool = False, timeout: int = 60,
        check: bool = False) -> subprocess.CompletedProcess:
    """Run a shell command on the device.

    session_env=True prepends the lipstick session env (needed for dbus / the
    browser / screenshots).  Returns the CompletedProcess (stdout/stderr are
    captured text).  check=True raises DeviceError on non-zero exit.
    """
    payload = (SESSION_ENV + cmd) if session_env else cmd
    proc = subprocess.run(
        _SSH_BASE + [_TARGET, payload],
        capture_output=True, text=True, timeout=timeout,
    )
    if check and proc.returncode != 0:
        raise DeviceError(f"ssh failed ({proc.returncode}): {proc.stderr.strip()}")
    return proc


def scp_from(remote: str, local: str, timeout: int = 60) -> None:
    subprocess.run(_SCP_BASE + [f"{_TARGET}:{remote}", local],
                   capture_output=True, text=True, timeout=timeout, check=True)


def scp_to(local: str, remote: str, timeout: int = 60) -> None:
    subprocess.run(_SCP_BASE + [local, f"{_TARGET}:{remote}"],
                   capture_output=True, text=True, timeout=timeout, check=True)


def reachable() -> bool:
    try:
        return ssh("echo ok", timeout=8).stdout.strip() == "ok"
    except Exception:
        return False


# ── Process discovery ────────────────────────────────────────────────────────
# The browser runs as a UI process (atlantic-browser.bin, the Qt/Silica shell +
# WPE compositor) plus one or more WPEWebProcess children (the page engine).
def processes() -> dict:
    """Return {'ui': pid|None, 'web': [pid,...], 'network': [pid,...], 'raw': str}.

    Uses ps with full args so we can tell the WebProcess apart from the network
    process (both are 'WPEWebProcess' as comm; the cmdline differentiates).
    """
    out = ssh("ps -eo pid,args").stdout
    ui = None
    web, network, gpu = [], [], []
    for line in out.splitlines():
        line = line.strip()
        if not line or line.split()[0] == "PID":
            continue
        try:
            pid = int(line.split()[0])
        except ValueError:
            continue
        rest = line.split(None, 1)[1] if " " in line else ""
        if "atlantic-browser.bin" in rest:
            ui = pid
        elif "WPEWebProcess" in rest or "WebKitWebProcess" in rest:
            web.append(pid)
        elif "WPENetworkProcess" in rest or "NetworkProcess" in rest:
            network.append(pid)
        elif "GPUProcess" in rest:
            gpu.append(pid)
    return {"ui": ui, "web": web, "network": network, "gpu": gpu, "raw": out}


def is_running() -> bool:
    return processes()["ui"] is not None


# ── Launch / navigate ────────────────────────────────────────────────────────
def stop() -> None:
    ssh(
        "pkill -f 'atlantic-browser.bi[n]'; pkill -f 'WPEWebProces[s]'; "
        "pkill -x bwrap; pkill -x firejail 2>/dev/null; true",
        session_env=True,
    )


def launch(url: str | None = None, *, inspector: bool = True,
           gst_debug: str | None = None, extra_env: dict | None = None,
           logfile: str = "/tmp/atl.log", wait: float = 3.0) -> None:
    """(Re)start the browser detached, with optional inspector + extra env.

    The /usr/bin/atlantic-browser launcher passes the environment straight
    through to the engine, so enabling the remote inspector is just an env var.
    """
    stop()
    time.sleep(2)
    env = []
    if inspector:
        env.append(f"export WEBKIT_INSPECTOR_HTTP_SERVER=0.0.0.0:{INSPECTOR_PORT};")
    if gst_debug:
        env.append(f"export GST_DEBUG={shlex.quote(gst_debug)};")
    for k, v in (extra_env or {}).items():
        env.append(f"export {k}={shlex.quote(str(v))};")
    envstr = " ".join(env)
    ssh(
        f"{envstr} setsid /usr/bin/atlantic-browser "
        f">{logfile} 2>&1 </dev/null &",
        session_env=True,
    )
    time.sleep(wait)
    if url:
        # Wait for the name rather than firing blind: dbus-send to an activatable
        # name that nobody owns yet spawns a second browser (see wait_for_ui_name).
        if not wait_for_ui_name():
            raise DeviceError(
                "browser never claimed org.atlantic.browser.ui — refusing to "
                "openUrl (it would D-Bus-activate a second instance)")
        open_url(url)


def wait_for_ui_name(timeout: float = 25.0) -> bool:
    """Block until the running browser owns org.atlantic.browser.ui on the bus.

    MUST be called before open_url().  org.atlantic.browser.ui is D-Bus
    ACTIVATABLE (/usr/share/dbus-1/services/org.atlantic.browser.ui.service), so
    a dbus-send to it before the freshly-launched browser has claimed the name
    activates a SECOND browser instance: the first one is left minimized while
    the new one loads the page.  Two browsers then compete for CPU/GPU and one of
    them is suspended, which silently invalidates any measurement taken
    afterwards.  Polling NameHasOwner (rather than sleeping a fixed few seconds)
    keeps the launch to exactly one instance.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        r = ssh(
            "dbus-send --session --print-reply --dest=org.freedesktop.DBus "
            "/org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner "
            "string:org.atlantic.browser.ui",
            session_env=True,
        )
        if "true" in r.stdout:
            return True
        time.sleep(0.5)
    return False


def open_url(url: str) -> subprocess.CompletedProcess:
    """Navigate the running browser via its openUrl D-Bus method (array of str)."""
    return ssh(
        "dbus-send --session --print-reply "
        "--dest=org.atlantic.browser.ui --type=method_call "
        f"/ui org.atlantic.browser.ui.openUrl array:string:{shlex.quote(url)}",
        session_env=True,
    )


def log_tail(n: int = 60, logfile: str = "/tmp/atl.log") -> str:
    return ssh(f"tail -n {n} {shlex.quote(logfile)} 2>/dev/null").stdout


# ── Screenshot ───────────────────────────────────────────────────────────────
def screenshot(local_path: str = "/tmp/atldbg-shot.png") -> str:
    """Capture the device screen via lipstick's session D-Bus, pull it locally."""
    remote = f"/home/{USER}/atldbg-ss.png"
    ssh(
        f"rm -f {remote}; "
        "echo root | devel-su -p dbus-send --session --print-reply "
        "--dest=org.nemomobile.lipstick /org/nemomobile/lipstick/screenshot "
        f"org.nemomobile.lipstick.saveScreenshot string:{remote}",
        session_env=True,
    )
    scp_from(remote, local_path)
    return local_path


# ── Inspector SSH tunnel ─────────────────────────────────────────────────────
def _port_open(port: int) -> bool:
    with contextlib.closing(socket.socket(socket.AF_INET, socket.SOCK_STREAM)) as s:
        s.settimeout(0.5)
        return s.connect_ex(("127.0.0.1", port)) == 0


@contextlib.contextmanager
def tunnel(port: int = INSPECTOR_PORT):
    """Forward 127.0.0.1:port -> device:port for the duration of the block.

    If something is already listening on the local port (an existing tunnel),
    reuse it rather than fighting over the bind.
    """
    if _port_open(port):
        yield
        return
    proc = subprocess.Popen(
        _SSH_BASE + ["-N", "-L", f"{port}:127.0.0.1:{port}", _TARGET],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        for _ in range(40):
            if _port_open(port):
                break
            time.sleep(0.25)
        else:
            raise DeviceError(f"inspector tunnel to :{port} never came up "
                              "(is the browser launched with the inspector?)")
        yield
    finally:
        proc.terminate()
        with contextlib.suppress(Exception):
            proc.wait(timeout=3)
