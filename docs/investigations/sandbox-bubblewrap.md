> **Status: SUPERSEDED** — This document concludes bwrap is unworkable on hybris/Adreno and abandons it for sailjail. That conclusion was later reversed: the bwrap WebProcess sandbox ships default-ON (`ATLANTIC_ENABLE_SANDBOX`), and an in-process seccomp filter shipped in build 602. Kept for the device-proven namespace/GPU findings, not for its recommendation.
>
> Archived `BWRAP_PLAN.md` (build host `/root`), 2026-07-30.

# Bubblewrap Sandbox Enablement Plan — ABANDONED in favour of sailjail

## Decision (2026-06-05)

The bwrap-based WPE sandbox is **fundamentally incompatible** with the
libhybris/Adreno GPU stack on SFOS.  After extensive investigation (see
Phase 2 & 3 results below), the root cause is:

1. **User namespace strips supplementary groups** — the WebProcess loses
   `graphics` (gid 1003), `video` (gid 39) etc., which the Android GPU
   HAL (Binder, ION, KGSL) requires at the kernel-driver level.
   Fixing this requires modifying bwrap to call `newgidmap`, which adds
   attack surface.

2. **Mount namespace hides submounts** — `/odm` (Adreno GPU drivers) and
   `/vendor/firmware_mnt` (GPU firmware) are separate partitions not
   recursively included by `--dev-bind / /` on kernel 4.14.

3. **Even with both fixed** (build 227 + chmod + XDG fixes), the
   WebProcess never reaches GPU initialization — it loads libraries
   and enters its event loop without ever opening `/dev/kgsl-3d0`.

**Solution:** Application-layer confinement via sailjail/firejail.
Firejail preserves all supplementary groups and does not create a
mount namespace, so the GPU stack works normally.  The confinement
profile (`deploy/atlantic-browser.firejail.profile`) provides
`caps.drop all`, `seccomp`, `nonewprivs`, `ipc-namespace`, and
`private-tmp`.

## Implementation

| File | Change |
|------|--------|
| `deploy/atlantic-browser.firejail.profile` | Replaced bwrap-compatible profile (caps.keep sys_admin) with sailjail-only profile (caps.drop all) |
| `deploy/runtime-common.sh` | Updated comments; bwrap sandbox remains off by default; `ATLANTIC_ENABLE_SANDBOX=1` still available for debugging |
| `build-rpms-native.sh` | Changed `ATLANTIC_ENABLE_SAILJAIL` default from 0 to 1 in generated wrapper |
| `patches/webkit/webkit-bubblewrap-sfos-odm-fix.patch` | Removed (no longer needed) |

## Background (kept for reference)

## Goal
Enable the WPE bubblewrap sandbox so that rendering works on the Xperia 10 II (Adreno GPU via libhybris, kernel 4.14.264, Sailfish OS 5.1).

## Background

### Architecture (how frames flow)
```
WPEWebProcess (inside bwrap namespace)
  │  EGL render to FBO → EGLImage
  │  wl_surface.commit() → Wayland buffer (dmabuf or EGL wl_buffer)
  ▼  socketpair(AF_UNIX, SOCK_STREAM|CLOEXEC)  ← created by UI process, fd dup'd to remove CLOEXEC
WPEBackend-fdo in-process compositor (ws.cpp: ws-egl.cpp)
  │  surfaceCommit() → apiClient->exportLinuxDmabuf() / exportBufferResource()
  ▼  callback to WPEQtViewBackend
WPEQtViewBackend::displayImage()
  │  wpe_fdo_egl_exported_image → glEGLImageTargetTexture2DOES → GL texture
  ▼  QQuickWindow::update()
Qt Quick Scene Graph → Sailfish display
```

### Current bwrap args (from the SFOS patch)
```
--die-with-parent
--unshare-uts
--dev-bind / /          (full rootfs bind — pivot_root unsupported on kernel 4.14)
--proc /proc            (fresh procfs)
--tmpfs /tmp            (clean tmpfs)
--unsetenv TMPDIR
--dir /run/user/100000
--setenv XDG_RUNTIME_DIR /run/user/100000
+ D-Bus proxy via xdg-dbus-proxy (separate process, own namespace)
+ --seccomp <fd>        (syscall filter)
```

### What's already been ruled out (via bwrap shim on-device)
- `--unshare-uts` — NOT the cause
- `--unshare-pid` — NOT the cause
- `--unshare-ipc` — NOT the cause
- `--unshare-net` — NOT the cause (already shared by the patch)
- `--unshare-user` — NOT the cause
- `--unshare-cgroup` — NOT the cause
- `--seccomp <fd>` — NOT the cause
- **Conclusion: mount namespace itself (unavoidable in bwrap) is the trigger**

### Why the mount namespace matters
The mount namespace is bwrap's core mechanism — it cannot be removed. Even with no `--unshare-*` flags, bwrap always creates a new mount namespace. The question is what *inside* the new mount namespace breaks the frame export.

---

## Phase 2 Results (2026-06-05)

### Hypothesis tests — ALL BLANK
All screenshot comparisons confirmed blank content (92.5% transparent pixels, matching known-blank pattern):

| Test | Mod | Result |
|------|-----|--------|
| Baseline sandbox (no mods) | - | BLANK |
| Test 1: Real /tmp | `BWRAP_TEST_REAL_TMP=1` | BLANK |
| Test 2: No tmpfs | `BWRAP_TEST_NO_TMPFS=1` | BLANK |
| Test 3: No proc | `BWRAP_TEST_NO_PROC=1` | BLANK |
| Test 4: Share proc | `BWRAP_TEST_SHARE_PROC=1` | BLANK |
| Test 5: No dbus proxy | `BWRAP_TEST_NO_DBUS=1` | BLANK |
| Combo: No tmpfs + no proc + no dbus | All three | BLANK |

### strace comparison (definitive)
**Non-sandbox trace** (19,848 lines, rendering works):
- Opens `/dev/__properties__/` (Android property system — hybris dependency)
- Opens `/dev/ion` (ION memory allocator for GPU buffers)
- Opens `/dev/kgsl-3d0` with `O_RDWR|O_SYNC` (GPU device)
- Opens `/dev/hwbinder` (Android HAL binder)
- Loads `libbinder.so`, `libhwbinder.so`
- 529 `ioctl()` calls on GPU/ION fds
- Sends Wayland protocol messages via `sendmsg()`

**Sandbox trace** (1,506 lines, rendering fails):
- Loads the same libraries (libWPEWebKit, libepoxy, etc.)
- Creates threads ("ReceiveQueue" for Wayland)
- Sets up Wayland socket (fd 62) to non-blocking
- Enters ppoll-based event loop
- **NEVER opens `/dev/__properties__/`, `/dev/kgsl-3d0`, `/dev/ion`, or `/dev/hwbinder`**
- **ZERO ioctl calls** (0 vs 529 non-sandbox)
- **ZERO Wayland sendmsg/recvmsg** on the compositor socket
- Process runs for ~10 seconds then a thread exits

**Root cause:** The sandboxed WebProcess loads libraries and enters its event loop but **never reaches GPU initialization**. The libhybris/Android GPU stack requires access to Android system properties (`/dev/__properties__/`), HWBinder (`/dev/hwbinder`), ION (`/dev/ion`), and KGSL (`/dev/kgsl-3d0`) to discover and initialize the Adreno GPU. Inside the bwrap sandbox, one or more prerequisites for this initialization sequence are missing, causing the process to stall before GPU init.

### Candidate fix: `--dev-bind` the Android /dev nodes

The SFOS patch already uses `--dev-bind / /` (full rootfs bind), which should expose all of /dev. But the sandboxed process still doesn't access these nodes. Possible explanations:

1. **Android property filesystem (`/dev/__properties__/`) is a special filesystem (tmpfs/proc-like)** that isn't propagated through bind mounts. bwrap's `--dev-bind` might not handle it.
2. **SELinux labels on `/dev/__properties__/`** nodes may be lost or changed during bind mount, causing Android property library to reject them.
3. **The Android initialization path uses `/proc/self/exe` or `/proc/self/fd/`** to discover paths — the fresh procfs (`--proc /proc`) hides these.
4. **Binder namespace** — even though network namespace is shared, the binder ioctl path may depend on `/dev/binder` node being accessible with correct permissions/context.

Additional notes:
- `strace` fails inside the sandbox: `PTRACE_TRACEME` returns EPERM even with seccomp stripped and YAMA ptrace_scope=0. This suggests a deeper kernel restriction on ptrace within the sandbox context.
- The browser UI process detects "web-process-crashed" and creates an empty page (fallback path).

---

## Phase 1: Create the bwrap shim toolset (~45 min)

Create a Python shim at `/usr/bin/bwrap` on the device that intercepts bwrap args, modifies them, logs them, and delegates to the real bwrap at `/usr/bin/bwrap.real`. This is the fast path — no WebKit rebuild needed.

### 1a. Write the shim script
**File:** `/root/bwrap_shim.py` (to be scp'd to device as `/usr/bin/bwrap`)

Requirements:
- Parses args looking for `--args <fd>` (NUL-separated args on a file descriptor)
- Can strip/add/modify individual bwrap args based on env vars:
  - `BWRAP_TEST_NO_TMPFS=1` → strip `--tmpfs /tmp`
  - `BWRAP_TEST_NO_PROC=1` → strip `--proc /proc`
  - `BWRAP_TEST_SHARE_PROC=1` → replace `--proc /proc` with `--proc /proc` but bind-mount real /proc
  - `BWRAP_TEST_REAL_TMP=1` → replace `--tmpfs /tmp` with `--bind /tmp /tmp`
  - `BWRAP_TEST_NO_DBUS=1` → strip D-Bus proxy args + redirect
  - `BWRAP_TEST_LOG=1` → write args to `/tmp/bwrap-shim.log`
- Pass-through all other args unchanged to `bwrap.real`
- Handle NUL-separated fd args correctly (read from fd, modify, write to new fd, repos on fd 199)

### 1b. Deploy and verify the shim
```sh
scp /root/bwrap_shim.py device:/home/defaultuser/bwrap_shim.py
ssh device 'echo root | devel-su cp /usr/bin/bwrap /usr/bin/bwrap.real'
ssh device 'echo root | devel-su cp /home/defaultuser/bwrap_shim.py /usr/bin/bwrap'
ssh device 'echo root | devel-su chmod 755 /usr/bin/bwrap'
```

### 1c. Test the shim with sandbox ON
```sh
SSH="sshpass -p root ssh -p 2222 -o StrictHostKeyChecking=no defaultuser@localhost"
$SSH 'export XDG_RUNTIME_DIR=/run/user/100000
      export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/100000/dbus/user_bus_socket
      pkill -f "atlantic-browser.bi[n]"; pkill -f "WPEWebProces[s]"; pkill -x bwrap; sleep 2
      ATLANTIC_ENABLE_SANDBOX=1 ATLANTIC_ENABLE_SAILJAIL=0 ATLANTIC_IN_SAILJAIL=1 \
      BWRAP_TEST_LOG=1 \
      setsid /usr/bin/atlantic-browser >/tmp/atl.log 2>&1 </dev/null &'
```

---

## Phase 2: Test hypotheses via the shim (~2 hr, can be done in serial)

Each test: set the env var, launch browser with sandbox ON, navigate to a test page, check if content is visible.

### Test 1: Real /tmp instead of tmpfs
**Hypothesis:** `--tmpfs /tmp` hides shared memory files, Unix sockets, or FIFOs that the hybris GPU stack or libgbm/dri2 uses.

**Env:** `BWRAP_TEST_REAL_TMP=1`

**Why:** Adreno's KGSL driver communicates with the userspace via `/dev/kgsl-3d0`, but intermediate libraries (libgbm, libdrm, mesa3d adaptors) may create temp files in `/tmp` for buffer sharing or synchronization. A fresh tmpfs hides these.

**Verification:** If rendering works → add `--bind /tmp /tmp` or drop `--tmpfs /tmp` from the patch.

### Test 2: Strip --tmpfs entirely
**Hypothesis:** The mere presence of `--tmpfs /tmp` (even if we test above binds real /tmp) causes `TMPDIR` unsetting issues or other env complications.

**Env:** `BWRAP_TEST_NO_TMPFS=1`

### Test 3: Strip --proc /proc
**Hypothesis:** The fresh procfs hides `/proc/self/fd/*` entries that are needed to pass dmabuf file descriptors via Wayland protocol. When the compositor sends fd's via `wl_buffer`, the receiving side may need `/proc/self/fd/N` to validate or operate on them.

**Env:** `BWRAP_TEST_NO_PROC=1`

**Why:** Wayland fd-passing uses `SCM_RIGHTS` on Unix sockets. The receiving process may need to stat `/proc/self/fd/N` to determine the fd type. A fresh procfs inside the namespace won't show FDs created before the namespace transition.

### Test 4: Real /proc bind-mount
**Hypothesis:** The fresh procfs breaks something specific about the Adreno GPU stack (e.g., `/proc/self/pagemap`, `/proc/self/maps`, or GPU driver sysfs paths under `/proc`).

**Env:** `BWRAP_TEST_SHARE_PROC=1` (replaces `--proc /proc` with host `/proc` bind mount)

### Test 5: Strip D-Bus proxy/redirect
**Hypothesis:** The D-Bus session bus redirect (via xdg-dbus-proxy) interferes with the hybris/Android HAL communication. The Adreno GPU stack on SFOS may use the session D-Bus for HAL service discovery (android.hardware.graphics.* services proxied through libhybris to binder, potentially involving D-Bus).

**Env:** `BWRAP_TEST_NO_DBUS=1`

**Why:** While the GPU talks directly to `/dev/kgsl-3d0`, the Android HAL layer (libhybris → libandroid → binder) may have a D-Bus dependency for service discovery or licensing. The SFOS libhybris fork might route some HAL calls through D-Bus.

### Test 6: Combinatorial tests
If no single change fixes it, test combinations:
- No tmpfs + No dbus
- No proc + No dbus
- No tmpfs + No proc + No dbus
- All three stripped simultaneously

---

## Phase 3: strace the WebProcess (~1 hr)

If none of the shim-based tests fix rendering, strace is the definitive path.

### 3a. Modify shim to inject strace
Add `BWRAP_TEST_STRACE=1` mode: instead of exec'ing the real bwrap directly, insert `strace -f -o /tmp/wpe-strace.log` before the WebProcess binary.

### 3b. Collect traces
1. Launch WITHOUT sandbox → collect strace as baseline reference
2. Launch WITH sandbox (shim passthrough, no modifications) → collect strace

### 3c. Compare traces
Key syscalls to diff:
- `socketpair()` / `connect()` / `sendmsg()` — Wayland protocol communication
- `ioctl(KGSL_*)` — GPU command submission
- `open(/dev/kgsl*)` — GPU device access
- `ioctl(ION_*)` — ION memory allocator
- `mmap()` — dmabuf and shared memory mappings
- `bind()` / `sendto()` for abstract Unix sockets — binder IPC
- `fcntl()` with `F_DUPFD` — fd passing
- Any ENOENT, EACCES, ENODEV, ENOSYS, ENOTTY errors
- `write()` / `sendmsg()` on the WPE fdo socketpair fd

Look for the exact point where divergence occurs:
- Does the WebProcess connect to the compositor at all?
- Does it render (EGL calls succeed)?
- Does it submit buffers (wl_surface.commit)?
- Does the compositor receive the buffers?
- Does the compositor forward them via export*()?
- Does WPEQtViewBackend::displayImage() get called?

---

## Phase 4: Implement the fix (~1-3 hr depending on finding)

### Scenario A: Fixable via bwrap arg changes (tmpfs, proc, dbus)
If a shim test identifies the breaking arg:
1. Modify `patches/webkit/webkit-bubblewrap-sfos-sandbox.patch` to adjust the sandbox args
2. Trigger CI: `gh workflow run build-atlantic-packages.yml --ref master`
3. Deploy to device and verify

### Scenario B: Fixable via bind mounts (specific paths needed)
If the issue is missing paths (e.g., `/dev/ion` needs explicit exposure):
1. Add explicit `--bind` or `--dev-bind` for the missing paths in the patch
2. CI rebuild + deploy

### Scenario C: Fundamentally incompatible
If the mount namespace itself (not its contents) breaks the hybris stack:
- **Option C1 (keep bwrap, relax mount ns):** Modify WebKit to use bwrap with `--share-net --share-ipc` but keep filesystem namespace via `--dev-bind / /`. This gives us seccomp and mount isolation without breaking GPU.
- **Option C2 (skip mount ns for GPU processes):** Only sandbox the WebProcess's *network* access; keep the GPU compositing path un-namespaced. Do this by forking the GPU rendering into a non-sandboxed child.
- **Option C3 (use a different IPC for frame export):** Instead of the in-process Wayland compositor (socketpair-based), use shared memory (SHM) for frame export. The SHM segment would survive namespace transitions.
- **Option C4 (application-level sandboxing):** Use sailjail (SFOS-native, already setuid-configured) instead of bwrap. This is already partially in the codebase (`ATLANTIC_ENABLE_SAILJAIL`) and may be the most compatible option for hybris devices.

### Scenario D: strace reveals a specific syscall failure
If strace shows a specific point of failure:
1. If the compositor socketpair fd gets lost during bwrap exec → add `--inherit-fd` or pass the fd explicitly
2. If a GPU device node is unreachable → add `--dev-bind` for that node
3. If a kernel API is namespace-scoped (e.g., binder, ION) → evaluate if bwrap can be configured to share that namespace

---

## Files that may need modification

| File | Purpose |
|------|---------|
| `/release/workspace/atlantic-engine/patches/webkit/webkit-bubblewrap-sfos-sandbox.patch` | Sandbox args in BubblewrapLauncher.cpp |
| `/release/workspace/atlantic-engine/deploy/runtime-common.sh` | Sandbox env vars, enable default |
| `/release/workspace/atlantic-browser/apps/wpe/WPEWebContainer.cpp` | `configureSandboxPaths()` — path whitelisting |
| `/usr/bin/bwrap` (shim) | Test harness — never committed |

## Key constraints
- No WebKit rebuild for shim-based tests (fast: ~5 min per test)
- WebKit full CI rebuild takes 50-90 minutes
- Device tunnel is flaky — account for reconnection
- Device has 3.5 GB RAM — account for OOM when debugging
- `devel-su -c` does not parse pipes — use `echo root | devel-su <cmd>`
- Use `pkill -f "atlantic-browser.bi[n]"` to avoid killing the ssh session

## Success criteria
1. Web page content renders visibly on device with `ATLANTIC_ENABLE_SANDBOX=1`
2. Sandbox args preserve meaningful isolation (minimally: seccomp + some namespace)
3. No regression in rendering performance or stability
4. `runtime-common.sh` default flipped to `ATLANTIC_ENABLE_SANDBOX:-1` after on-device verification
