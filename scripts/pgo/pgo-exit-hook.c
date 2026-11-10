/* SPDX-License-Identifier: MPL-2.0
 *
 * Linked into every binary of the INSTRUMENTED (ATLANTIC_PGO=generate) WebKit
 * build, together with -Wl,--wrap=_exit. Never part of a shipped build.
 *
 * The LLVM profile runtime writes its counters from an atexit() handler, and
 * WebKit's helper processes — where nearly all of the engine's time goes —
 * often do not get that far:
 *   - the NetworkProcess, and any process whose main thread is busy when the
 *     UI process goes away, leave through _exit();
 *   - a WebProcess that has not wound down 10 s after its connection closed is
 *     aborted by WebKit's own watchdog (WebProcess.cpp, crashAfter10Seconds);
 *   - and a crash or a kill loses everything.
 * So the profile is flushed here instead: every few seconds from a thread, and
 * once more on _exit().
 *
 * Each flush MERGES into the file named by LLVM_PROFILE_FILE (the %m pattern),
 * so the counters are reset after every flush — otherwise each one would add
 * the whole history again. Counts that land between the write and the reset
 * are lost; that is noise.
 *
 * The runtime is a static archive linked into each instrumented binary with
 * hidden visibility, so every binary carries, and flushes, its own copy.
 */
#include <pthread.h>
#include <stdlib.h>
#include <unistd.h>

extern int __llvm_profile_write_file(void) __attribute__((weak, visibility("hidden")));
extern void __llvm_profile_reset_counters(void) __attribute__((weak, visibility("hidden")));
void __real__exit(int) __attribute__((noreturn));

static pthread_mutex_t flush_lock = PTHREAD_MUTEX_INITIALIZER;

static void flush(void)
{
    if (!__llvm_profile_write_file || !__llvm_profile_reset_counters)
        return;
    pthread_mutex_lock(&flush_lock);
    __llvm_profile_write_file();
    __llvm_profile_reset_counters();
    pthread_mutex_unlock(&flush_lock);
}

static void* flush_thread(void* arg)
{
    unsigned seconds = (unsigned)(unsigned long)arg;
    for (;;) {
        sleep(seconds);
        flush();
    }
    return NULL;
}

/* Weak: CMake can repeat linker flags, and this object with them. */
__attribute__((weak, visibility("hidden"), constructor))
void atlantic_pgo_start_flusher(void)
{
    /* Only under a training run: the build itself also executes instrumented
     * binaries, which have no business writing profiles. */
    if (!getenv("LLVM_PROFILE_FILE"))
        return;
    const char* interval = getenv("ATLANTIC_PGO_FLUSH_SECONDS");
    unsigned long seconds = interval ? strtoul(interval, NULL, 10) : 15;
    if (!seconds)
        return;
    pthread_t thread;
    if (!pthread_create(&thread, NULL, flush_thread, (void*)seconds))
        pthread_detach(thread);
}

__attribute__((weak, visibility("hidden"), noreturn, used))
void __wrap__exit(int status)
{
    flush();
    __real__exit(status);
}
