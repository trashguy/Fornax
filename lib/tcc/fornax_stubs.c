/* Stubs for functions TCC references but Fornax doesn't support.
 * TCC auto-defines TCC_IS_NATIVE for x86_64-on-x86_64, enabling tccrun.c
 * (in-memory execution via -run). Fornax only uses tcc as a file compiler,
 * so these code paths are never reached at runtime. */

typedef unsigned long size_t;

/* --- semaphore stubs (TCC threading, not used on Fornax) --- */
typedef struct { int dummy; } sem_t;
int sem_init(sem_t *sem, int pshared, unsigned value) { (void)sem; (void)pshared; (void)value; return 0; }
int sem_wait(sem_t *sem) { (void)sem; return 0; }
int sem_post(sem_t *sem) { (void)sem; return 0; }

/* --- signal stubs (tccrun error handling, not used) --- */
typedef struct { unsigned long __bits[128/sizeof(unsigned long)]; } sigset_t_stub;
int sigemptyset(sigset_t_stub *set) { (void)set; return 0; }
int sigaddset(sigset_t_stub *set, int signum) { (void)set; (void)signum; return 0; }
int pthread_sigmask(int how, const void *set, void *oldset) { (void)how; (void)set; (void)oldset; return 0; }

/* --- sysconf stub --- */
long sysconf(int name) {
    (void)name;
    return 4096; /* _SC_PAGESIZE */
}

/* --- environ (tccrun uses 'environ', shim provides '__environ') ---
 * shim.c defines __environ; musl code and tcc use 'environ'.
 * Provide it as a separate global (both will be NULL on Fornax). */
char **environ = 0;

/* --- freopen stub (tccrun stdin redirection, not used) --- */
void *freopen(const char *path, const char *mode, void *stream) {
    (void)path; (void)mode; (void)stream;
    return (void*)0;
}

/* --- execvp stub (tcctools external linker, not used) --- */
int execvp(const char *file, char *const argv[]) {
    (void)file; (void)argv;
    return -1;
}

/* --- __assert_fail (tcc x86_64-gen.c assertions) --- */
void __attribute__((noreturn)) __assert_fail(const char *expr, const char *file, int line, const char *func) {
    /* Write a message to fd 1 (stdout) since we have no stderr fd guarantee */
    extern long __fornax_syscall(long, long, long, long, long, long, long);
    const char msg[] = "assertion failed\n";
    __fornax_syscall(1, 1, (long)msg, sizeof(msg) - 1, 0, 0, 0); /* SYS_WRITE */
    __fornax_syscall(25, 0, 0, 0, 0, 0, 0); /* SYS_EXIT */
    __builtin_unreachable();
}

/* --- musl hidden symbols (internal plumbing not available on Fornax) --- */
void *__mremap(void *old, size_t old_sz, size_t new_sz, int flags, ...) {
    (void)old; (void)old_sz; (void)new_sz; (void)flags;
    return (void*)-1; /* MAP_FAILED */
}
void *__vdsosym(const char *name, const char *ver) {
    (void)name; (void)ver;
    return (void*)0;
}
void *__map_file(const char *path, size_t *size) {
    (void)path; (void)size;
    return (void*)-1;
}
void __restore_rt(void) {}
void __block_all_sigs(void *set) { (void)set; }
void __restore_sigs(void *set) { (void)set; }

/* __abort_lock — musl sigaction.c references this as a volatile int */
volatile int __abort_lock[1];
