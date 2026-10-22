/*
 * SPDX-License-Identifier: MPL-2.0
 * libsigill_skip.so — installed via LD_PRELOAD before libpreloadpatchmanager.so
 * runs its init.  On aarch64, __builtin_trap() emits a 4-byte "brk"/"udf"
 * (on 32-bit ARM a 2-byte Thumb or 4-byte ARM "udf")
 * instruction.  We install a SIGILL handler that simply advances PC by 4
 * so execution continues past the trap.  After libpreloadpatchmanager's init
 * finishes we restore the default handler.
 *
 * Init-function ordering in glibc: libraries loaded later have their
 * constructors called FIRST — so our constructor (LD_PRELOAD, loaded after
 * /etc/ld.so.preload) runs before libpreloadpatchmanager's constructor.
 */
#define _GNU_SOURCE
#include <signal.h>
#include <ucontext.h>
#include <stdint.h>

static struct sigaction old_sa;

static void sigill_skip(int sig, siginfo_t *info, void *ctx)
{
    ucontext_t *uc = (ucontext_t *)ctx;
    /* Skip the illegal instruction and resume */
#if defined(__aarch64__)
    uc->uc_mcontext.pc += 4;
#elif defined(__arm__)
    /* 32-bit ARM: __builtin_trap() is a 2-byte udf in Thumb state (CPSR.T,
     * bit 5), a 4-byte one in ARM state. */
    uc->uc_mcontext.arm_pc += (uc->uc_mcontext.arm_cpsr & 0x20) ? 2 : 4;
#else
#error "libsigill_skip: unsupported architecture"
#endif
    /* Restore default handler so we don't suppress real ILLs later */
    sigaction(SIGILL, &old_sa, NULL);
}

__attribute__((constructor))
static void install_handler(void)
{
    struct sigaction sa;
    sa.sa_sigaction = sigill_skip;
    sa.sa_flags     = SA_SIGINFO | SA_RESTART;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGILL, &sa, &old_sa);
}
