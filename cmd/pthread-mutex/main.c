/*
 * pthread-mutex — Futex-based mutex correctness test for Fornax.
 *
 * Spawns 4 threads, each incrementing a shared counter 1000 times under
 * a futex-based mutex. Expected final counter = 4000.
 *
 * Uses raw clone/futex syscalls (no pthreads) to avoid musl threading deps.
 */
#include <stdio.h>

/* Fornax syscall numbers */
#define SYS_EXIT   14
#define SYS_CLONE  37
#define SYS_FUTEX  38
#define SYS_MMAP   32
#define SYS_SLEEP  24

static inline long __raw1(long nr, long a0)
{
    long ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a0)
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

static inline long __raw5(long nr, long a0, long a1, long a2, long a3, long a4)
{
    long ret;
    register long r10 __asm__("r10") = a3;
    register long r8 __asm__("r8") = a4;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a0), "S"(a1), "d"(a2), "r"(r10), "r"(r8)
        : "rcx", "r11", "memory");
    return ret;
}

/* Simple futex-based mutex */
static volatile int mutex = 0;

static void mutex_lock(void)
{
    while (__sync_lock_test_and_set(&mutex, 1))
        __raw4(SYS_FUTEX, (long)&mutex, 0 /* WAIT */, 1, 0);
}

static void mutex_unlock(void)
{
    __sync_lock_release(&mutex);
    __raw4(SYS_FUTEX, (long)&mutex, 1 /* WAKE */, 1, 0);
}

static volatile int counter = 0;
static volatile int done_count = 0;
#define ITERS 1000
#define NUM_THREADS 4

static void thread_func(void *arg)
{
    (void)arg;
    for (int i = 0; i < ITERS; i++) {
        mutex_lock();
        counter++;
        mutex_unlock();
    }
    __sync_fetch_and_add(&done_count, 1);
    __raw1(SYS_EXIT, 0);
    __builtin_unreachable();
}

static long spawn_thread(void (*func)(void *), void *arg)
{
    /* Allocate 64KB stack */
    long stack = __raw4(SYS_MMAP, 0, 65536, 3, 0x22);
    if (stack == 0 || (unsigned long)stack > 0xFFFFFFFFFFFF0000ULL)
        return -1;

    unsigned long *sp = (unsigned long *)(stack + 65536);
    *--sp = (unsigned long)arg;
    *--sp = (unsigned long)func;

    long ret = __raw5(SYS_CLONE, (long)sp, 0, 0, 0, 0);
    if (ret == 0) {
        /* Child: pop func+arg, call func(arg) */
        void (*f)(void *);
        void *a;
        __asm__ volatile ("pop %0\npop %1\n" : "=r"(f), "=r"(a));
        f(a);
        __raw1(SYS_EXIT, 0);
        __builtin_unreachable();
    }
    return ret;
}

int main(void)
{
    printf("mutex-test: starting %d threads x %d iters\n", NUM_THREADS, ITERS);

    for (int i = 0; i < NUM_THREADS; i++) {
        long pid = spawn_thread(thread_func, (void *)(long)i);
        if (pid <= 0) {
            printf("mutex-test: clone failed for thread %d\n", i);
            return 1;
        }
        printf("mutex-test: spawned thread %d (pid=%ld)\n", i, pid);
    }

    /* Wait for all threads to finish */
    int loops = 0;
    while (done_count < NUM_THREADS && loops < 500000) {
        __raw1(SYS_SLEEP, 1);
        loops++;
    }

    printf("mutex-test: counter=%d (expected %d)\n", counter, NUM_THREADS * ITERS);
    if (counter == NUM_THREADS * ITERS)
        printf("mutex-test: PASS\n");
    else
        printf("mutex-test: FAIL\n");

    return (counter == NUM_THREADS * ITERS) ? 0 : 1;
}
