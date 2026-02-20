/*
 * thread-test — Raw clone test for Fornax (no pthreads).
 *
 * Creates a thread using the raw clone syscall via the POSIX shim.
 * The child thread writes a message and exits.
 * Main thread busy-waits on a shared variable.
 *
 * Expected output:
 *   thread-test: starting
 *   thread-test: child running
 *   thread-test: done, flag=1
 */
#include <stdio.h>

/* Raw Fornax syscall (same as shim.c) */
static inline long __raw1(long nr, long a0)
{
    long ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a0)
        : "rcx", "r11", "memory");
    return ret;
}

static inline long __raw5(long nr, long a0, long a1, long a2, long a3, long a4)
{
    long ret;
    register long r10 __asm__("r10") = a3;
    register long r8 __asm__("r8") = a4;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a0), "S"(a1), "d"(a2), "r"(r10), "r"(r8)
        : "rcx", "r11", "memory");
    return ret;
}

static inline long __raw4(long nr, long a0, long a1, long a2, long a3)
{
    long ret;
    register long r10 __asm__("r10") = a3;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a0), "S"(a1), "d"(a2), "r"(r10)
        : "rcx", "r11", "memory");
    return ret;
}

#define SYS_EXIT   14
#define SYS_CLONE  37
#define SYS_MMAP   32
#define SYS_SLEEP  24

static volatile int flag = 0;

/* Thread entry function — called by the clone asm stub */
static void thread_func(void *arg)
{
    (void)arg;
    printf("thread-test: child running\n");
    flag = 1;
    __raw1(SYS_EXIT, 0);
    __builtin_unreachable();
}

/*
 * Clone wrapper mimicking musl's __clone asm:
 * Push func+arg onto new stack, syscall clone, child pops and calls func(arg).
 */
static long do_clone(void (*func)(void *), void *arg, void *stack_top)
{
    /* Set up child stack: push arg and func (x86_64 stack grows down) */
    unsigned long *sp = (unsigned long *)stack_top;
    *--sp = (unsigned long)arg;
    *--sp = (unsigned long)func;

    /* Clone syscall: child gets RAX=0, parent gets child pid.
     * Fornax: clone(stack, tls, ctid, ptid, flags) */
    long ret = __raw5(SYS_CLONE, (long)sp, 0, 0, 0, 0);

    if (ret == 0) {
        /* Child path: pop func and arg from stack, call func(arg).
         * BUT: the child resumes at the instruction after the syscall
         * in do_clone, with RAX=0. So we need to manually recover. */
        void (*f)(void *);
        void *a;
        __asm__ volatile (
            "pop %0\n"
            "pop %1\n"
            : "=r"(f), "=r"(a)
        );
        f(a);
        __raw1(SYS_EXIT, 0);
        __builtin_unreachable();
    }

    return ret; /* parent: child pid */
}

int main(void)
{
    printf("thread-test: starting\n");

    /* Allocate 64KB stack via mmap */
    long stack = __raw4(SYS_MMAP, 0, 65536, 3 /* RW */, 0x22 /* ANON|PRIVATE */);
    if (stack == 0 || (unsigned long)stack > 0xFFFFFFFFFFFF0000ULL) {
        printf("thread-test: mmap failed: %lx\n", (unsigned long)stack);
        return 1;
    }

    void *stack_top = (void *)(stack + 65536);

    long child_pid = do_clone(thread_func, (void *)0, stack_top);
    if (child_pid <= 0) {
        printf("thread-test: clone failed: %ld\n", child_pid);
        return 1;
    }

    printf("thread-test: child pid=%ld\n", child_pid);

    /* Busy-wait for child to set flag (no futex join yet) */
    int loops = 0;
    while (flag == 0 && loops < 100000) {
        __raw1(SYS_SLEEP, 1); /* 1ms sleep */
        loops++;
    }

    printf("thread-test: done, flag=%d\n", flag);
    return 0;
}
