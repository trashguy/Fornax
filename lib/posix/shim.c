/*
 * shim.c — Linux syscall → Fornax syscall translation layer.
 *
 * musl libc emits Linux syscall numbers. This shim translates both the
 * number and semantics to Fornax's Plan 9 interface. All POSIX complexity
 * stays in userspace — the kernel remains Plan 9-pure.
 */

/* Fornax syscall numbers (must match src/syscall.zig SYS enum) */
#define FX_OPEN       0
#define FX_CREATE     1
#define FX_READ       2
#define FX_WRITE      3
#define FX_CLOSE      4
#define FX_STAT       5
#define FX_SEEK       6
#define FX_REMOVE     7
#define FX_RFORK     11
#define FX_EXIT      14
#define FX_BRK       16
#define FX_SYSINFO   23
#define FX_SLEEP     24
#define FX_GETPID    26
#define FX_RENAME    27
#define FX_TRUNCATE  28
#define FX_MMAP      32
#define FX_MUNMAP    33
#define FX_DUP       34
#define FX_DUP2      35
#define FX_ARCH_PRCTL 36
#define FX_CLONE     37
#define FX_FUTEX     38

/* Linux syscall numbers (x86_64 ABI) */
#define LNX_READ            0
#define LNX_WRITE           1
#define LNX_OPEN            2
#define LNX_CLOSE           3
#define LNX_STAT            4
#define LNX_FSTAT           5
#define LNX_LSTAT           6
#define LNX_LSEEK           8
#define LNX_MMAP            9
#define LNX_MPROTECT       10
#define LNX_MUNMAP         11
#define LNX_BRK            12
#define LNX_IOCTL          16
#define LNX_READV          19
#define LNX_WRITEV         20
#define LNX_ACCESS         21
#define LNX_DUP            32
#define LNX_DUP2           33
#define LNX_GETPID         39
#define LNX_FCNTL          72
#define LNX_GETCWD         79
#define LNX_RENAME         82
#define LNX_MKDIR          83
#define LNX_RMDIR          84
#define LNX_CREAT          85
#define LNX_UNLINK         87
#define LNX_READLINK       89
#define LNX_FCHMOD         91
#define LNX_FTRUNCATE      77
#define LNX_GETDENTS64    217
#define LNX_EXIT           60
#define LNX_UNAME         63
#define LNX_ARCH_PRCTL   158
#define LNX_CLOCK_GETTIME 228
#define LNX_EXIT_GROUP   231
#define LNX_OPENAT       257
#define LNX_MKDIRAT      258
#define LNX_NEWFSTATAT   262
#define LNX_UNLINKAT     263
#define LNX_RENAMEAT     264
#define LNX_RENAMEAT2    316
#define LNX_CLONE           56
#define LNX_FUTEX          202
#define LNX_GETTID         186
#define LNX_SET_TID_ADDRESS 218
#define LNX_SET_ROBUST_LIST 273
#define LNX_PRLIMIT64    302
#define LNX_GETRANDOM    318
#define LNX_MADVISE       28
#define LNX_SIGACTION      13
#define LNX_SIGPROCMASK    14
#define LNX_SIGRETURN      15
#define LNX_RT_SIGACTION   13
#define LNX_RT_SIGPROCMASK 14

/* Linux open flags */
#define O_RDONLY    0x0000
#define O_WRONLY    0x0001
#define O_RDWR      0x0002
#define O_CREAT     0x0040
#define O_TRUNC     0x0200
#define O_APPEND    0x0400
#define O_DIRECTORY 0x010000

/* AT_FDCWD for *at() syscalls */
#define AT_FDCWD (-100)
/* AT_REMOVEDIR for unlinkat */
#define AT_REMOVEDIR 0x200

/* ioctl constants */
#define TIOCGWINSZ  0x5413

/* fcntl constants */
#define F_DUPFD     0
#define F_GETFD     1
#define F_SETFD     2
#define F_GETFL     3
#define F_SETFL     4

/* Fornax stat struct (32 bytes) */
struct fx_stat {
    unsigned long long size;
    unsigned int       file_type;
    unsigned int       reserved0;
    unsigned long long mtime;
    unsigned int       mode;
    unsigned short     uid;
    unsigned short     gid;
};

/* Linux stat struct (x86_64, 144 bytes) */
struct linux_stat {
    unsigned long st_dev;
    unsigned long st_ino;
    unsigned long st_nlink;
    unsigned int  st_mode;
    unsigned int  st_uid;
    unsigned int  st_gid;
    unsigned int  __pad0;
    unsigned long st_rdev;
    long          st_size;
    long          st_blksize;
    long          st_blocks;
    unsigned long st_atime_sec;
    unsigned long st_atime_nsec;
    unsigned long st_mtime_sec;
    unsigned long st_mtime_nsec;
    unsigned long st_ctime_sec;
    unsigned long st_ctime_nsec;
    long          __unused[3];
};

/* iovec for writev */
struct iovec {
    void  *iov_base;
    unsigned long iov_len;
};

/* winsize for TIOCGWINSZ */
struct winsize {
    unsigned short ws_row;
    unsigned short ws_col;
    unsigned short ws_xpixel;
    unsigned short ws_ypixel;
};

/* utsname for uname */
struct utsname {
    char sysname[65];
    char nodename[65];
    char release[65];
    char version[65];
    char machine[65];
    char domainname[65];
};

/* Sysinfo structure (matches Fornax) */
struct fx_sysinfo {
    unsigned long long total_pages;
    unsigned long long free_pages;
    unsigned long long page_size;
    unsigned long long uptime_secs;
};

/* Current working directory buffer */
static char __cwd[256] = "/";
static int __cwd_len = 1;

/* ── Raw Fornax syscall (inline asm) ──────────────────────────────── */

static inline long __fx_raw1(long nr, long a0)
{
    long ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a0)
        : "rcx", "r11", "memory");
    return ret;
}

static inline long __fx_raw2(long nr, long a0, long a1)
{
    long ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a0), "S"(a1)
        : "rcx", "r11", "memory");
    return ret;
}

static inline long __fx_raw3(long nr, long a0, long a1, long a2)
{
    long ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a0), "S"(a1), "d"(a2)
        : "rcx", "r11", "memory");
    return ret;
}

static inline long __fx_raw4(long nr, long a0, long a1, long a2, long a3)
{
    long ret;
    register long r10 __asm__("r10") = a3;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a0), "S"(a1), "d"(a2), "r"(r10)
        : "rcx", "r11", "memory");
    return ret;
}

static inline long __fx_raw5(long nr, long a0, long a1, long a2, long a3, long a4)
{
    long ret;
    register long r10 __asm__("r10") = a3;
    register long r8 __asm__("r8") = a4;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a0), "S"(a1), "d"(a2), "r"(r10), "r"(r8)
        : "rcx", "r11", "memory");
    return ret;
}

/* ── Helpers ─────────────────────────────────────────────────────── */

static unsigned long __strlen(const char *s)
{
    unsigned long n = 0;
    while (s[n]) n++;
    return n;
}

static void __memset(void *dst, int c, unsigned long n)
{
    unsigned char *d = (unsigned char *)dst;
    while (n--) *d++ = (unsigned char)c;
}

static void __memcpy(void *dst, const void *src, unsigned long n)
{
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    while (n--) *d++ = *s++;
}

static void __strcpy(char *dst, const char *src)
{
    while ((*dst++ = *src++))
        ;
}

static int __strcmp(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return *(unsigned char *)a - *(unsigned char *)b;
}

/* Convert Fornax fx_stat → Linux stat struct */
static void fx_to_linux_stat(const struct fx_stat *fx, struct linux_stat *ls)
{
    __memset(ls, 0, sizeof(*ls));
    ls->st_size = (long)fx->size;
    ls->st_blksize = 4096;
    ls->st_blocks = (long)((fx->size + 511) / 512);

    /* Convert mode: Fornax uses octal mode with type bits */
    unsigned int m = fx->mode;
    if (fx->file_type == 1) /* directory */
        m |= 0040000; /* S_IFDIR */
    else
        m |= 0100000; /* S_IFREG */
    ls->st_mode = m;
    ls->st_uid = fx->uid;
    ls->st_gid = fx->gid;
    ls->st_nlink = 1;
    ls->st_ino = 1;
    ls->st_mtime_sec = fx->mtime;
    ls->st_atime_sec = fx->mtime;
    ls->st_ctime_sec = fx->mtime;
}

/* ── Linux → Fornax open flag translation ───────────────────────── */

static long translate_open(const char *path, int linux_flags, int mode)
{
    if (!path) return -14; /* EFAULT */

    unsigned long plen = __strlen(path);

    if (linux_flags & O_CREAT) {
        unsigned int fx_flags = 0;
        if (linux_flags & O_DIRECTORY) fx_flags |= 0x01;
        if (linux_flags & O_APPEND) fx_flags |= 0x02;
        return __fx_raw3(FX_CREATE, (long)path, plen, fx_flags);
    } else {
        long fd = __fx_raw2(FX_OPEN, (long)path, plen);
        if (fd < 0) return fd;
        if (linux_flags & O_TRUNC) {
            __fx_raw2(FX_TRUNCATE, fd, 0);
        }
        return fd;
    }
}

/* ── The main translation function ───────────────────────────────── */

long __fornax_syscall(long n, long a, long b, long c, long d, long e, long f)
{
    (void)f;

    switch (n) {

    /* ── I/O ─────────────────────────────────────────────────────── */
    case LNX_READ:
        return __fx_raw3(FX_READ, a, b, c);

    case LNX_WRITE:
        return __fx_raw3(FX_WRITE, a, b, c);

    case LNX_OPEN:
        return translate_open((const char *)a, (int)b, (int)c);

    case LNX_OPENAT: {
        /* openat(dirfd, path, flags, mode) — only support AT_FDCWD */
        const char *path = (const char *)b;
        if (a != AT_FDCWD) return -38; /* ENOSYS */
        return translate_open(path, (int)c, (int)d);
    }

    case LNX_CLOSE:
        return __fx_raw1(FX_CLOSE, a);

    case LNX_LSEEK:
        return __fx_raw3(FX_SEEK, a, b, c);

    case LNX_READV: {
        const struct iovec *iov = (const struct iovec *)b;
        int iovcnt = (int)c;
        long total = 0;
        for (int i = 0; i < iovcnt; i++) {
            if (iov[i].iov_len > 0) {
                long r = __fx_raw3(FX_READ, a, (long)iov[i].iov_base, (long)iov[i].iov_len);
                if (r < 0) return r;
                total += r;
                if ((unsigned long)r < iov[i].iov_len) break; /* short read */
            }
        }
        return total;
    }

    case LNX_WRITEV: {
        const struct iovec *iov = (const struct iovec *)b;
        int iovcnt = (int)c;
        long total = 0;
        for (int i = 0; i < iovcnt; i++) {
            if (iov[i].iov_len > 0) {
                long r = __fx_raw3(FX_WRITE, a, (long)iov[i].iov_base, (long)iov[i].iov_len);
                if (r < 0) return r;
                total += r;
            }
        }
        return total;
    }

    /* ── File metadata ───────────────────────────────────────────── */
    case LNX_STAT:
    case LNX_LSTAT: {
        /* stat(path, buf) → open + fstat + close */
        const char *path = (const char *)a;
        struct linux_stat *lbuf = (struct linux_stat *)b;
        long fd = __fx_raw2(FX_OPEN, (long)path, __strlen(path));
        if (fd < 0) return -2; /* ENOENT */
        struct fx_stat fxs;
        long r = __fx_raw2(FX_STAT, fd, (long)&fxs);
        __fx_raw1(FX_CLOSE, fd);
        if (r != 0) return -5; /* EIO */
        fx_to_linux_stat(&fxs, lbuf);
        return 0;
    }

    case LNX_FSTAT: {
        struct linux_stat *lbuf = (struct linux_stat *)b;
        struct fx_stat fxs;
        long r = __fx_raw2(FX_STAT, a, (long)&fxs);
        if (r != 0) return -5; /* EIO */
        fx_to_linux_stat(&fxs, lbuf);
        return 0;
    }

    case LNX_NEWFSTATAT: {
        /* newfstatat(dirfd, path, buf, flags) — only AT_FDCWD */
        const char *path = (const char *)b;
        struct linux_stat *lbuf = (struct linux_stat *)c;
        if (a != AT_FDCWD) return -38;
        long fd = __fx_raw2(FX_OPEN, (long)path, __strlen(path));
        if (fd < 0) return -2;
        struct fx_stat fxs;
        long r = __fx_raw2(FX_STAT, fd, (long)&fxs);
        __fx_raw1(FX_CLOSE, fd);
        if (r != 0) return -5;
        fx_to_linux_stat(&fxs, lbuf);
        return 0;
    }

    /* ── Memory management ───────────────────────────────────────── */
    case LNX_MMAP:
        return __fx_raw4(FX_MMAP, a, b, c, d);

    case LNX_MUNMAP:
        return __fx_raw2(FX_MUNMAP, a, b);

    case LNX_MPROTECT:
        return 0; /* No-op: single address space, no protection changes */

    case LNX_MADVISE:
        return 0; /* No-op */

    case LNX_BRK:
        return __fx_raw1(FX_BRK, a);

    /* ── File descriptors ────────────────────────────────────────── */
    case LNX_DUP:
        return __fx_raw1(FX_DUP, a);

    case LNX_DUP2:
        return __fx_raw2(FX_DUP2, a, b);

    case LNX_FCNTL: {
        int cmd = (int)b;
        if (cmd == F_DUPFD) return __fx_raw1(FX_DUP, a);
        if (cmd == F_GETFL) return 0;
        if (cmd == F_SETFL) return 0;
        if (cmd == F_GETFD) return 0;
        if (cmd == F_SETFD) return 0;
        return -38; /* ENOSYS */
    }

    /* ── File system operations ──────────────────────────────────── */
    case LNX_RENAME:
        return __fx_raw4(FX_RENAME, a, __strlen((const char *)a),
                         b, __strlen((const char *)b));

    case LNX_RENAMEAT:
    case LNX_RENAMEAT2: {
        if (a != AT_FDCWD || (n == LNX_RENAMEAT2 && c != AT_FDCWD))
            return -38;
        const char *oldp = (const char *)b;
        const char *newp = (n == LNX_RENAMEAT2) ? (const char *)d : (const char *)c;
        return __fx_raw4(FX_RENAME, (long)oldp, __strlen(oldp),
                         (long)newp, __strlen(newp));
    }

    case LNX_MKDIR:
        return __fx_raw3(FX_CREATE, a, __strlen((const char *)a), 0x01 /* O_DIR */);

    case LNX_MKDIRAT:
        if (a != AT_FDCWD) return -38;
        return __fx_raw3(FX_CREATE, b, __strlen((const char *)b), 0x01);

    case LNX_UNLINK:
    case LNX_RMDIR:
        return __fx_raw2(FX_REMOVE, a, __strlen((const char *)a));

    case LNX_UNLINKAT: {
        if (a != AT_FDCWD) return -38;
        return __fx_raw2(FX_REMOVE, b, __strlen((const char *)b));
    }

    case LNX_CREAT:
        return __fx_raw3(FX_CREATE, a, __strlen((const char *)a), 0);

    case LNX_FTRUNCATE:
        return __fx_raw2(FX_TRUNCATE, a, b);

    case LNX_ACCESS:
        /* Just check if the file can be opened */
        {
            long fd = __fx_raw2(FX_OPEN, a, __strlen((const char *)a));
            if (fd < 0) return -2;
            __fx_raw1(FX_CLOSE, fd);
            return 0;
        }

    case LNX_READLINK:
        return -22; /* EINVAL: no symlinks in Fornax */

    case LNX_FCHMOD:
        return 0; /* No-op for now */

    /* ── Process ─────────────────────────────────────────────────── */
    case LNX_EXIT:
    case LNX_EXIT_GROUP:
        __fx_raw1(FX_EXIT, a);
        __builtin_unreachable();

    case LNX_GETPID:
        return __fx_raw1(FX_GETPID, 0);

    case LNX_GETTID:
        return __fx_raw1(FX_GETPID, 0);

    case LNX_ARCH_PRCTL:
        return __fx_raw2(FX_ARCH_PRCTL, a, b);

    /* ── Threading ───────────────────────────────────────────────── */
    case LNX_CLONE: {
        /* Linux: clone(flags, stack, ptid, ctid, tls)
         *        a=flags b=stack c=ptid d=ctid e=tls
         * Fornax: clone(stack, tls, ctid, ptid, flags)
         */
        return __fx_raw5(FX_CLONE, b/*stack*/, e/*tls*/, d/*ctid*/, c/*ptid*/, a/*flags*/);
    }

    case LNX_FUTEX: {
        /* Linux: futex(addr, op, val, timeout, addr2, val3)
         *        a=addr b=op c=val d=timeout
         * Fornax: futex(addr, op, val, timeout)
         */
        return __fx_raw4(FX_FUTEX, a, b, c, d);
    }

    /* ── Signals (stubs) ─────────────────────────────────────────── */
    case LNX_RT_SIGACTION:
    case LNX_RT_SIGPROCMASK:
        return 0; /* No-op: no signal support */

    /* ── Terminal / ioctl ────────────────────────────────────────── */
    case LNX_IOCTL: {
        unsigned long req = (unsigned long)b;
        if (req == TIOCGWINSZ) {
            struct winsize *ws = (struct winsize *)c;
            if (ws) {
                ws->ws_row = 25;
                ws->ws_col = 80;
                ws->ws_xpixel = 0;
                ws->ws_ypixel = 0;
            }
            return 0;
        }
        return -25; /* ENOTTY */
    }

    /* ── Time ────────────────────────────────────────────────────── */
    case LNX_CLOCK_GETTIME: {
        /* clock_gettime(clk_id, tp) */
        struct { long tv_sec; long tv_nsec; } *tp = (void *)b;
        if (tp) {
            struct fx_sysinfo info;
            __fx_raw1(FX_SYSINFO, (long)&info);
            tp->tv_sec = (long)info.uptime_secs;
            tp->tv_nsec = 0;
        }
        return 0;
    }

    /* ── getcwd ──────────────────────────────────────────────────── */
    case LNX_GETCWD: {
        char *buf = (char *)a;
        long size = b;
        if (!buf || size < __cwd_len + 1) return -34; /* ERANGE */
        __memcpy(buf, __cwd, __cwd_len);
        buf[__cwd_len] = '\0';
        return (long)buf;
    }

    /* ── uname ───────────────────────────────────────────────────── */
    case LNX_UNAME: {
        struct utsname *u = (struct utsname *)a;
        if (!u) return -14;
        __memset(u, 0, sizeof(*u));
        __strcpy(u->sysname, "Fornax");
        __strcpy(u->nodename, "fornax");
        __strcpy(u->release, "0.1.0");
        __strcpy(u->version, "Phase 1000");
        __strcpy(u->machine, "x86_64");
        return 0;
    }

    /* ── Thread stubs ────────────────────────────────────────────── */
    case LNX_SET_TID_ADDRESS:
        return __fx_raw1(FX_GETPID, 0); /* return "tid" = pid */

    case LNX_SET_ROBUST_LIST:
        return 0; /* No-op */

    /* ── Resource limits ─────────────────────────────────────────── */
    case LNX_PRLIMIT64:
        return -38; /* ENOSYS */

    /* ── Random ──────────────────────────────────────────────────── */
    case LNX_GETRANDOM: {
        /* Read from /dev/random */
        long fd = __fx_raw2(FX_OPEN, (long)"/dev/random", 11);
        if (fd < 0) {
            /* Fallback: fill with something */
            __memset((void *)a, 0x42, (unsigned long)b);
            return b;
        }
        long r = __fx_raw3(FX_READ, fd, a, b);
        __fx_raw1(FX_CLOSE, fd);
        return r > 0 ? r : b;
    }

    case LNX_GETDENTS64:
        return -38; /* ENOSYS: not yet supported */

    default:
        return -38; /* ENOSYS */
    }
}

/*
 * Cancellation-point syscall wrapper.
 * In single-threaded mode (no POSIX threads), this is just a pass-through
 * to __fornax_syscall. musl's internal headers reference this symbol.
 */
long __syscall_cp(long n, long a, long b, long c, long d, long e, long f)
{
    return __fornax_syscall(n, a, b, c, d, e, f);
}

/*
 * TLS / threading stubs for single-threaded Fornax.
 * musl requires these symbols but we don't support threads.
 */

/* TLS setup: musl's __init_tls calls this to set the thread pointer.
 * On x86_64, this means setting FS_BASE via arch_prctl. */
int __set_thread_area(void *p)
{
    /* ARCH_SET_FS = 0x1002. Use raw Fornax syscall (NOT the Linux translation
     * shim), since FX_ARCH_PRCTL is a Fornax syscall number, not Linux. */
    return (int)__fx_raw2(FX_ARCH_PRCTL, 0x1002, (long)p);
}

/* Pointer to AT_SYSINFO_EHDR auxv value. Not relevant for Fornax. */
unsigned long __sysinfo = 0;

/* Default thread stack size. Only used in pthread_create which we don't support. */
unsigned long __default_stacksize = 131072;

/* Environment pointer. Our crt0 doesn't set up envp, so it's NULL. */
char **__environ = 0;

/* Thread-safe locks for musl's atexit/stdio locking.
 * Uses futex-assisted spinning: spin briefly, then futex wait. */
void __lock(volatile int *l)
{
    while (__sync_lock_test_and_set(l, 1))
        __fx_raw4(FX_FUTEX, (long)l, 0 /*FUTEX_WAIT*/, 1, 0);
}
void __unlock(volatile int *l)
{
    __sync_lock_release(l);
    __fx_raw4(FX_FUTEX, (long)l, 1 /*FUTEX_WAKE*/, 1, 0);
}

/* Internal calloc alias used by atexit. Forward to regular calloc. */
void *calloc(unsigned long, unsigned long);
void *__libc_calloc(unsigned long n, unsigned long s)
{
    return calloc(n, s);
}


/* _init stub. Normally provided by crti.o; musl's libc_start_init calls it. */
void _init(void) {}

