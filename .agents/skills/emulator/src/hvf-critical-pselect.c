/*
 * QEMU 9.1.2 ARM HVF waits for virtual timer interrupts with pselect().
 * macOS coalesces short pselect timeouts. A critical kqueue timer is more
 * precise, while pselect on its fd preserves QEMU's atomic SIG_IPI unmasking.
 */
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/event.h>
#include <sys/select.h>
#include <unistd.h>

static int (*system_pselect)(int, fd_set *, fd_set *, fd_set *,
                             const struct timespec *, const sigset_t *);
static _Thread_local int timer_queue = -1;

__attribute__((constructor)) static void resolve_pselect(void)
{
    void *lib = dlopen("/usr/lib/system/libsystem_kernel.dylib", RTLD_NOW);
    system_pselect = lib ? dlsym(lib, "__pselect") : NULL;
    if (!system_pselect) {
        fputs("vemu: macOS __pselect unavailable\n", stderr);
        _exit(127);
    }
}

static int critical_pselect(int n, fd_set *readfds, fd_set *writefds,
                            fd_set *exceptfds, const struct timespec *timeout,
                            const sigset_t *mask)
{
    if (n || readfds || writefds || exceptfds || !timeout || !mask ||
        timeout->tv_sec || timeout->tv_nsec <= 0 ||
        timeout->tv_nsec >= 2000000) {
        return system_pselect(n, readfds, writefds, exceptfds, timeout, mask);
    }

    if (timer_queue < 0) {
        timer_queue = kqueue();
    }
    if (timer_queue < 0 || timer_queue >= FD_SETSIZE) {
        return system_pselect(n, readfds, writefds, exceptfds, timeout, mask);
    }

    struct kevent event;
    EV_SET(&event, 1, EVFILT_TIMER, EV_ADD | EV_ENABLE | EV_ONESHOT,
           NOTE_NSECONDS | NOTE_CRITICAL, timeout->tv_nsec, NULL);
    if (kevent(timer_queue, &event, 1, NULL, 0, NULL) < 0) {
        return system_pselect(n, readfds, writefds, exceptfds, timeout, mask);
    }

    fd_set ready;
    FD_ZERO(&ready);
    FD_SET(timer_queue, &ready);
    int result = system_pselect(timer_queue + 1, &ready, NULL, NULL, NULL, mask);
    int saved_errno = errno;

    EV_SET(&event, 1, EVFILT_TIMER, EV_DELETE, 0, 0, NULL);
    kevent(timer_queue, &event, 1, NULL, 0, NULL);
    errno = saved_errno;
    return result > 0 ? 0 : result;
}

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} interpose_pselect __attribute__((section("__DATA,__interpose"))) = {
    (const void *)critical_pselect, (const void *)pselect
};
