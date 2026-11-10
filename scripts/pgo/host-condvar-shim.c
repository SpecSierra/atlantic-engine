/*
 * Build-host only: futex condition variables preloaded over glibc's while the
 * engine runs headless (train.sh, bench.sh). Never packaged.
 *
 * With the host's glibc 2.39 the engine deadlocks in JavaScriptCore's GC on
 * script-heavy pages: a thread parked on its own condition variable is
 * signalled (WTF::ParkingLot clears its address and calls
 * pthread_cond_signal) yet stays asleep, and the collector waits for it
 * forever. The condition variable's group bookkeeping is then seen counting
 * millions of long-gone timed waiters. About one BBC/Guardian session in two
 * hung; none in five with this shim.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <limits.h>
#include <linux/futex.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

struct cv { _Atomic unsigned seq; int clock; };
_Static_assert(sizeof(struct cv) <= sizeof(pthread_cond_t), "cv fits");

int pthread_cond_init(pthread_cond_t* c, const pthread_condattr_t* attr)
{
    struct cv* v = (struct cv*)c;
    clockid_t clock = CLOCK_REALTIME;
    if (attr)
        pthread_condattr_getclock(attr, &clock);
    __builtin_memset(c, 0, sizeof(*c));
    v->clock = clock;
    return 0;
}

int pthread_cond_destroy(pthread_cond_t* c) { (void)c; return 0; }

static int wait_on(struct cv* v, pthread_mutex_t* m, clockid_t clock, const struct timespec* abstime)
{
    unsigned seq = atomic_load(&v->seq);
    int result = 0;
    pthread_mutex_unlock(m);
    int op = FUTEX_WAIT_BITSET | FUTEX_PRIVATE_FLAG | (clock == CLOCK_REALTIME ? FUTEX_CLOCK_REALTIME : 0);
    for (;;) {
        long r = syscall(SYS_futex, &v->seq, op, seq, abstime, NULL, FUTEX_BITSET_MATCH_ANY);
        if (!r || errno == EAGAIN)
            break;
        if (errno == ETIMEDOUT) { result = ETIMEDOUT; break; }
        if (errno != EINTR)
            break;
        if (atomic_load(&v->seq) != seq)
            break;
    }
    pthread_mutex_lock(m);
    return result;
}

int pthread_cond_wait(pthread_cond_t* c, pthread_mutex_t* m)
{
    return wait_on((struct cv*)c, m, CLOCK_MONOTONIC, NULL);
}

int pthread_cond_timedwait(pthread_cond_t* c, pthread_mutex_t* m, const struct timespec* abstime)
{
    struct cv* v = (struct cv*)c;
    if (abstime->tv_nsec < 0 || abstime->tv_nsec >= 1000000000)
        return EINVAL;
    return wait_on(v, m, v->clock, abstime);
}

int pthread_cond_clockwait(pthread_cond_t* c, pthread_mutex_t* m, clockid_t clock, const struct timespec* abstime)
{
    if (abstime->tv_nsec < 0 || abstime->tv_nsec >= 1000000000)
        return EINVAL;
    return wait_on((struct cv*)c, m, clock, abstime);
}

static int wake(pthread_cond_t* c, int count)
{
    struct cv* v = (struct cv*)c;
    atomic_fetch_add(&v->seq, 1);
    syscall(SYS_futex, &v->seq, FUTEX_WAKE | FUTEX_PRIVATE_FLAG, count, NULL, NULL, 0);
    return 0;
}

int pthread_cond_signal(pthread_cond_t* c) { return wake(c, 1); }
int pthread_cond_broadcast(pthread_cond_t* c) { return wake(c, INT_MAX); }
