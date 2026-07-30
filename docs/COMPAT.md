# SFOS compatibility shims

Flags live in `versions.env`; sources in `shims/compat/`. The goal is a minimal
runtime closure, so every entry here needs a live reason to stay.

## Active on the 5.1.0.11 line

| Flag | Shim | Why it is still on |
|---|---|---|
| `USE_EGL_STUBS=1` | `libegl-stubs.c` | hybris EGL is short of symbols WebKit links against |
| `USE_SIGILL_SKIP=1` | `libsigill_skip.c` | the rebuilt 5.1 line still trips unsupported CPU-feature probes |
| `USE_SYNC_FENCE_SKIP=1` | `libsyncskip.c` | EGL native fences exist in the driver but libhybris-libEGL does not export them |
| — | `patches/engine/libepoxy-rtld-default-fallback.patch` | coupled to `libegl-stubs.so`; re-check together |
| — | `libgssapi_krb5_stub.c`, `libharfbuzz_icu_stub.c` | link-time stubs for libraries absent from the sysroot |

## Retired with SFOS 5.1

| Flag | Shim | Why it went |
|---|---|---|
| `USE_GLIBC_COMPAT=0` | `libglibc-compat.c` | 5.1 glibc provides `__libc_single_threaded` |
| `USE_GLIB_COMPAT=0` | `libglib_compat.c` | 5.1 GLib ABI is sufficient |
| `USE_COW_STRING_COMPAT=0` | — | on the rebuilt 5.1 runtime this shim makes `invoker` fail |
| `PATCH_GLIBC_VERSIONS=0` | `patch-glibc-versions.py` | the baseline matches runtime glibc; retagging is no longer needed |
| — | `libgetauxval_fix*`, `libexecve_wrap*` | tied to the old wrapped process-launch path |
| — | broad `LD_PRELOAD` stacks | replaced by explicit, individually justified shims |

Turning one back on is a decision, not a default: set the flag in `versions.env`
and record why here.

## Sandboxing

The bwrap WebProcess sandbox is **on by default** (`ATLANTIC_ENABLE_SANDBOX=1`,
`ENABLE_BUBBLEWRAP_SANDBOX=ON` plus `patches/webkit/webkit-bubblewrap-sfos-sandbox.patch`):
`--dev-bind / /` with no `pivot_root`/`--dev` masking of GPU nodes, a shared netns
for Web/GPU (hybris abstract sockets), and `flatpakInfoFd = -1` for the read-only
rootfs. An in-process seccomp filter (no namespaces) ships alongside it —
`ATLANTIC_ENABLE_SECCOMP`, verified from build 602.

Firejail/sailjail confinement is wired but **experimental and default-off**: it must
run via the booster (a direct `firejail --profile=` re-exec fails with `seteuid`),
and SFOS firejail replaces the inner bwrap with `fbwrap`, which cannot nest.
bwrap-only is the chosen posture. Toggle: `ATLANTIC_ENABLE_SAILJAIL`.

Background and the device-proven namespace/GPU findings:
[investigations/sandbox-bubblewrap.md](investigations/sandbox-bubblewrap.md).
