/* libsyncskip.so: skip the per-frame Android sync-fence CPU wait on the
 * compositor render threads (env-gated, default OFF).
 *
 * On libhybris, eglSwapBuffers ends in WaylandNativeWindow::queueBuffer,
 * which sync_wait()s the buffer's GPU fence on the CALLING thread before
 * attaching/committing the wl_buffer (Wayland has no way to hand the Android
 * fence to the consumer, and libhybris-libEGL does not expose
 * EGL_ANDROID_native_fence_sync to convert it). That serializes CPU and GPU:
 * the WebKit ThreadedCompositor and the Qt QSGRenderThread each burn a full
 * GPU-frame-time blocked in sync_wait per frame. Device-measured on YouTube
 * 1080p (Xperia 10 II, build 543): video frames arrive at 30fps but composite
 * every ~74ms (~13fps); skipping the wait on both compositor threads brings
 * the cycle to ~42ms (~24fps), visually clean.
 *
 * Interposed via LD_PRELOAD (part of the wpe-compat preload set). Inert
 * unless ATLANTIC_SKIP_SWAP_FENCE=1: every call forwards to the real
 * sync_wait. When enabled, only threads whose comm matches the WebKit
 * ThreadedCompositor ("...Composi...", comm truncates the prefix) or Qt's
 * QSGRenderThread skip the wait — decoder/codec threads (droidmedia) always
 * keep their fences. The skipped wait means the consumer can sample a buffer
 * the GPU has not finished; on the Adreno 610 the same-GPU submission order
 * appears to make this benign, but it stays opt-in until broadly validated.
 * ATLANTIC_SYNCSKIP_LOG=1 logs the first few skips.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/prctl.h>

typedef int (*sync_wait_fn)(int, int);

static sync_wait_fn real_sync_wait(void)
{
    static sync_wait_fn real;
    if (!real) {
        real = (sync_wait_fn)dlsym(RTLD_NEXT, "sync_wait");
        if (!real) {
            /* Preload shims resolve ahead of libsync, so RTLD_NEXT can miss
             * it; load the real library explicitly. */
            void *h = dlopen("libsync.so.2", RTLD_LAZY | RTLD_LOCAL);
            if (!h)
                h = dlopen("/usr/lib64/libsync.so.2", RTLD_LAZY | RTLD_LOCAL);
            if (h)
                real = (sync_wait_fn)dlsym(h, "sync_wait");
        }
    }
    return real;
}

static int skip_enabled(void)
{
    static int enabled = -1;
    if (enabled < 0) {
        const char *v = getenv("ATLANTIC_SKIP_SWAP_FENCE");
        enabled = v && *v && *v != '0';
    }
    return enabled;
}

__attribute__((visibility("default")))
int sync_wait(int fd, int timeout)
{
    sync_wait_fn real = real_sync_wait();

    if (skip_enabled()) {
        char name[16] = { 0 };
        prctl(PR_GET_NAME, name);
        if (strstr(name, "Composi") || strstr(name, "QSGRenderThread")) {
            static int logged;
            const char *log = getenv("ATLANTIC_SYNCSKIP_LOG");
            if (log && *log && *log != '0' && logged < 5) {
                fprintf(stderr, "[syncskip] skipping fence wait on %s (fd=%d timeout=%d)\n", name, fd, timeout);
                ++logged;
            }
            return 0;
        }
    }

    if (!real) {
        static int warned;
        if (!warned) {
            fprintf(stderr, "[syncskip] real sync_wait not found, failing open\n");
            warned = 1;
        }
        return 0;
    }
    return real(fd, timeout);
}
