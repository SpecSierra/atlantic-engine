#!/usr/bin/env python3
"""
Bubblewrap sandbox argument shim.

Replaces /usr/bin/bwrap on the device. Intercepts bwrap invocations from
WebKit's BubblewrapLauncher, reads the NUL-separated sandbox args from the
file descriptor passed via --args <fd>, modifies them according to
BWRAP_TEST_* environment variables, then delegates to the real bwrap at
/usr/bin/bwrap.real.

Usage:
    # Backup the real bwrap first (one-time):
    #   echo root | devel-su cp /usr/bin/bwrap /usr/bin/bwrap.real
    #   echo root | devel-su cp bwrap_shim.py /usr/bin/bwrap
    #   echo root | devel-su chmod 755 /usr/bin/bwrap

    # Test with sandbox ON:
    #   BWRAP_TEST_LOG=1 BWRAP_TEST_NO_TMPFS=1 ATLANTIC_ENABLE_SANDBOX=1 \
    #     setsid /usr/bin/atlantic-browser >/tmp/atl.log 2>&1 </dev/null &

Env vars:
    BWRAP_TEST_NO_TMPFS=1       Strip --tmpfs /tmp entirely
    BWRAP_TEST_NO_PROC=1        Strip --proc /proc entirely
    BWRAP_TEST_REAL_TMP=1       Replace --tmpfs /tmp with --bind /tmp /tmp
    BWRAP_TEST_SHARE_PROC=1     Replace --proc /proc with --bind /proc /proc
    BWRAP_TEST_NO_DBUS=1        Strip D-Bus proxy redirect (real session bus)
    BWRAP_TEST_LOG=1            Write intercepted args to /tmp/bwrap-shim.log
    BWRAP_TEST_NO_SECCOMP=1     Strip --seccomp <fd> (needed for strace)
    BWRAP_TEST_BIND_ANDROID_DEV=1  Add explicit --dev-bind for Android /dev paths
    BWRAP_TEST_DEV_PROBE=1      Replace child with "ls /dev && mount" probe
    BWRAP_TEST_STRACE=1         Insert strace before the child process
    BWRAP_STRACE_FILE=<path>    Strafe output file (default /tmp/wpe-strace.log)
"""

import os
import sys
import errno
import fcntl
import time

BWRAP_REAL = "/usr/bin/bwrap.real"


def _create_memfd(name="bwrap-shim-args"):
    """Create a memfd, write data, seek to start, return fd. Portable fallbacks."""
    data = b""  # placeholder, caller will write

    if hasattr(os, "memfd_create"):
        fd = os.memfd_create(name, os.MFD_CLOEXEC)
    else:
        try:
            import ctypes
            libc = ctypes.CDLL(None, use_errno=True)
            MFD_CLOEXEC = 0x0001
            libc.memfd_create.restype = ctypes.c_int
            libc.memfd_create.argtypes = [ctypes.c_char_p, ctypes.c_uint]
            fd = libc.memfd_create(name.encode(), MFD_CLOEXEC)
            if fd == -1:
                e = ctypes.get_errno()
                raise OSError(e, os.strerror(e))
        except Exception:
            import tempfile
            tmp = tempfile.NamedTemporaryFile(prefix="bwrap-shim-", suffix=".args", delete=False)
            fd = os.open(tmp.name, os.O_RDWR | os.O_CLOEXEC)
            os.unlink(tmp.name)

    return fd


def read_fd_all(fd):
    """Read all available data from a file descriptor."""
    chunks = []
    while True:
        try:
            chunk = os.read(fd, 65536)
        except OSError as e:
            if e.errno == errno.EAGAIN:
                continue
            raise
        if not chunk:
            break
        chunks.append(chunk)
    return b"".join(chunks)


def split_nul(data):
    """Split NUL-separated bytes into a list of strings."""
    parts = data.split(b"\0")
    if parts and parts[-1] == b"":
        parts.pop()
    return [p.decode("utf-8", errors="replace") for p in parts]


def join_nul(args):
    """Join a list of strings into NUL-separated bytes with trailing NUL."""
    return b"\0".join(a.encode("utf-8") for a in args) + b"\0"


def find_arg_index(argv, opt):
    """Return index of --args <fd> in argv, or (None, None) if not found."""
    for i, arg in enumerate(argv):
        if arg == opt and i + 1 < len(argv):
            try:
                int(argv[i + 1])
            except ValueError:
                continue
            return i, int(argv[i + 1])
    return None, None


def strip_kv_arg(args, opt, takes_value=True):
    """Remove an option and its value from args."""
    result = []
    skip = False
    for a in args:
        if skip:
            skip = False
            continue
        if a == opt:
            if takes_value:
                skip = True
            continue
        result.append(a)
    return result


def replace_opt_value(args, old_opt, new_opt, new_arg1, new_arg2):
    """Replace --old_opt value with --new_opt new_arg1 new_arg2."""
    result = []
    skip = False
    for a in args:
        if skip:
            skip = False
            continue
        if a == old_opt:
            result.append(new_opt)
            result.append(new_arg1)
            result.append(new_arg2)
            skip = True
            continue
        result.append(a)
    return result


def strip_dbus_redirect(args):
    """Remove xdg-dbus-proxy and D-Bus session bus redirect args.

    Strips:
      --ro-bind <src> <dest>          (both paths contain /wpe/bus)
      --setenv DBUS_SESSION_BUS_ADDRESS unix:path=<...>/wpe/bus
    """
    result = []
    i = 0
    while i < len(args):
        a = args[i]

        if a == "--setenv" and i + 1 < len(args) and args[i + 1] == "DBUS_SESSION_BUS_ADDRESS":
            i += 3  # skip --setenv + DBUS_SESSION_BUS_ADDRESS + value
            continue

        if a in ("--ro-bind", "--bind", "--dev-bind", "--symlink") and i + 2 < len(args):
            src = args[i + 1]
            dst = args[i + 2]
            if "/wpe/bus" in src or "/wpe/bus" in dst:
                i += 3  # skip option + src + dst
                continue

        result.append(a)
        i += 1

    return result


def modify_args(args):
    """Apply argument modifications based on BWRAP_TEST_* env vars."""
    modified = list(args)

    if os.environ.get("BWRAP_TEST_NO_TMPFS") == "1":
        modified = strip_kv_arg(modified, "--tmpfs")

    if os.environ.get("BWRAP_TEST_NO_PROC") == "1":
        modified = strip_kv_arg(modified, "--proc")

    if os.environ.get("BWRAP_TEST_REAL_TMP") == "1":
        modified = replace_opt_value(modified, "--tmpfs", "--bind", "/tmp", "/tmp")

    if os.environ.get("BWRAP_TEST_SHARE_PROC") == "1":
        modified = replace_opt_value(modified, "--proc", "--bind", "/proc", "/proc")

    if os.environ.get("BWRAP_TEST_NO_DBUS") == "1":
        modified = strip_dbus_redirect(modified)

    if os.environ.get("BWRAP_TEST_NO_SECCOMP") == "1":
        modified = strip_kv_arg(modified, "--seccomp")

    if os.environ.get("BWRAP_TEST_BIND_ANDROID_DEV") == "1":
        for path in ["/dev/__properties__", "/dev/kgsl-3d0", "/dev/ion", "/dev/hwbinder", "/odm"]:
            modified.extend(["--dev-bind", path, path])

    return modified


def log_to_file(args, original_args):
    """Write intercepted args to /tmp/bwrap-shim.log if BWRAP_TEST_LOG=1."""
    if os.environ.get("BWRAP_TEST_LOG") != "1":
        return
    try:
        with open("/tmp/bwrap-shim.log", "a") as f:
            f.write("\n{} PID={} PPID={}\n".format("=" * 60, os.getpid(), os.getppid()))
            f.write("  {}".format(time.strftime("%Y-%m-%d %H:%M:%S")))
            f.write("\nEnv:\n")
            for k in sorted(os.environ):
                if k.startswith("BWRAP_") or k.startswith("ATLANTIC_"):
                    f.write("  {}={}\n".format(k, os.environ[k]))
            f.write("\nOriginal args ({} entries):\n".format(len(original_args)))
            for a in original_args:
                f.write("  {}\n".format(a))
            f.write("\nModified args ({} entries):\n".format(len(args)))
            for a in args:
                f.write("  {}\n".format(a))
            f.write("\n")
    except Exception:
        pass


def inject_strace(argv):
    """Insert strace -f -o <file> before the child process (after --)."""
    if os.environ.get("BWRAP_TEST_STRACE") != "1":
        return argv
    strace_file = os.environ.get("BWRAP_STRACE_FILE", "/tmp/wpe-strace.log")
    try:
        dash_idx = argv.index("--")
    except ValueError:
        return argv
    return argv[: dash_idx + 1] + ["strace", "-f", "-o", strace_file] + argv[dash_idx + 1 :]


def inject_dev_probe(argv):
    """Replace child command with a diagnostic probe (ls /dev, mount)."""
    if os.environ.get("BWRAP_TEST_DEV_PROBE") != "1":
        return argv
    try:
        dash_idx = argv.index("--")
    except ValueError:
        return argv
    probe_script = (
        "ls -laR /dev/ >/home/defaultuser/dev-probe.log 2>&1; "
        "mount >>/home/defaultuser/dev-probe.log 2>&1; "
        "ls -laR /dev/__properties__/ >>/home/defaultuser/dev-probe.log 2>&1; "
        "stat /dev/kgsl* /dev/ion /dev/hwbinder >>/home/defaultuser/dev-probe.log 2>&1; "
        "stat -f /dev/__properties__/ >>/home/defaultuser/dev-probe.log 2>&1; "
        "echo PID=$$ >>/home/defaultuser/dev-probe.log 2>&1"
    )
    return argv[: dash_idx + 1] + ["sh", "-c", probe_script]


def main():
    argv = sys.argv[1:]

    if not os.path.exists(BWRAP_REAL):
        sys.stderr.write("bwrap-shim: {0} not found, exiting\n".format(BWRAP_REAL))
        sys.exit(1)

    args_idx, args_fd = find_arg_index(argv, "--args")

    if args_idx is None:
        os.execv(BWRAP_REAL, [BWRAP_REAL] + argv)
        sys.exit(1)

    try:
        raw = read_fd_all(args_fd)
    except OSError as e:
        sys.stderr.write("bwrap-shim: failed to read fd {0}: {1}\n".format(args_fd, e))
        os.execv(BWRAP_REAL, [BWRAP_REAL] + argv)
        sys.exit(1)

    os.close(args_fd)

    original_args = split_nul(raw)
    modified_args = modify_args(original_args)

    log_to_file(modified_args, original_args)

    new_data = join_nul(modified_args)
    new_fd = _create_memfd("bwrap-shim-args")
    os.write(new_fd, new_data)
    os.lseek(new_fd, 0, os.SEEK_SET)

    # Build the final argv for bwrap.real, replacing the original fd with our new one.
    # Also inject strace between -- and the child process.
    child_argv = (
        argv[:args_idx]
        + ["--args", str(new_fd)]
        + argv[args_idx + 2 :]  # skip the old --args and its fd value
    )
    child_argv = inject_strace(child_argv)
    child_argv = inject_dev_probe(child_argv)

    # Ensure the new fd is inherited by the child (strip CLOEXEC).
    try:
        flags = fcntl.fcntl(new_fd, fcntl.F_GETFD)
        fcntl.fcntl(new_fd, fcntl.F_SETFD, flags & ~fcntl.FD_CLOEXEC)
    except OSError:
        pass

    os.execv(BWRAP_REAL, [BWRAP_REAL] + child_argv)
    sys.exit(1)


if __name__ == "__main__":
    main()
