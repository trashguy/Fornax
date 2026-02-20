/*
 * fornax.h — Freestanding C syscall interface for Fornax
 *
 * Native C programs include this to call Fornax Plan 9 syscalls directly.
 * No libc, no POSIX — raw kernel interface.
 */

#ifndef FORNAX_H
#define FORNAX_H

typedef unsigned char      uint8_t;
typedef unsigned short     uint16_t;
typedef unsigned int       uint32_t;
typedef unsigned long long uint64_t;
typedef long long          int64_t;
typedef int                int32_t;
typedef unsigned long      size_t;

/* Syscall numbers (must match lib/syscall.zig SYS enum) */
#define SYS_OPEN      0
#define SYS_CREATE    1
#define SYS_READ      2
#define SYS_WRITE     3
#define SYS_CLOSE     4
#define SYS_STAT      5
#define SYS_SEEK      6
#define SYS_REMOVE    7
#define SYS_RFORK     11
#define SYS_EXIT      14
#define SYS_PIPE      15
#define SYS_BRK       16
#define SYS_SPAWN     19
#define SYS_KLOG      22
#define SYS_SYSINFO   23
#define SYS_SLEEP     24
#define SYS_SHUTDOWN  25
#define SYS_GETPID    26
#define SYS_RENAME    27
#define SYS_TRUNCATE  28
#define SYS_WSTAT     29
#define SYS_SETUID    30
#define SYS_GETUID    31
#define SYS_MMAP      32
#define SYS_MUNMAP    33
#define SYS_DUP       34
#define SYS_DUP2      35
#define SYS_ARCH_PRCTL 36
#define SYS_CLONE     37
#define SYS_FUTEX     38

/* Open flags */
#define FX_O_DIR    0x01
#define FX_O_APPEND 0x02

/* rfork flags */
#define RFNAMEG 0x01

/* wstat masks */
#define WSTAT_MODE 0x01
#define WSTAT_UID  0x02
#define WSTAT_GID  0x04

/* ARGV_BASE: where argc/argv are placed by the kernel */
#define FX_ARGV_BASE ((void *)0x7FFFFFEFF000ULL)

/* Error sentinel (high bit set = error) */
#define FX_IS_ERROR(r) ((r) > 0xFFFFFFFFFFFF0000ULL)

/* Stat structure (32 bytes, matches lib/syscall.zig Stat) */
struct fx_stat {
    uint64_t size;
    uint32_t file_type;
    uint32_t reserved0;
    uint64_t mtime;
    uint32_t mode;
    uint16_t uid;
    uint16_t gid;
};

/* SysInfo structure */
struct fx_sysinfo {
    uint64_t total_pages;
    uint64_t free_pages;
    uint64_t page_size;
    uint64_t uptime_secs;
};

/* ── Inline syscall wrappers ─────────────────────────────────────── */

static inline long __fx_syscall1(long nr, long a0) {
    long ret;
    __asm__ volatile ("syscall"
        : "=a"(ret)
        : "a"(nr), "D"(a0)
        : "rcx", "r11", "memory");
    return ret;
}

static inline long __fx_syscall2(long nr, long a0, long a1) {
    long ret;
    __asm__ volatile ("syscall"
        : "=a"(ret)
        : "a"(nr), "D"(a0), "S"(a1)
        : "rcx", "r11", "memory");
    return ret;
}

static inline long __fx_syscall3(long nr, long a0, long a1, long a2) {
    long ret;
    __asm__ volatile ("syscall"
        : "=a"(ret)
        : "a"(nr), "D"(a0), "S"(a1), "d"(a2)
        : "rcx", "r11", "memory");
    return ret;
}

static inline long __fx_syscall4(long nr, long a0, long a1, long a2, long a3) {
    long ret;
    register long r10 __asm__("r10") = a3;
    __asm__ volatile ("syscall"
        : "=a"(ret)
        : "a"(nr), "D"(a0), "S"(a1), "d"(a2), "r"(r10)
        : "rcx", "r11", "memory");
    return ret;
}

static inline long __fx_syscall5(long nr, long a0, long a1, long a2, long a3, long a4) {
    long ret;
    register long r10 __asm__("r10") = a3;
    register long r8 __asm__("r8") = a4;
    __asm__ volatile ("syscall"
        : "=a"(ret)
        : "a"(nr), "D"(a0), "S"(a1), "d"(a2), "r"(r10), "r"(r8)
        : "rcx", "r11", "memory");
    return ret;
}

/* ── Typed syscall functions ─────────────────────────────────────── */

static inline int fx_open(const char *path, uint32_t flags) {
    return (int)__fx_syscall2(SYS_OPEN, (long)path, (long)flags);
}

static inline int fx_create(const char *path, uint32_t flags, uint32_t perm) {
    return (int)__fx_syscall3(SYS_CREATE, (long)path, (long)flags, (long)perm);
}

static inline long fx_read(int fd, void *buf, size_t count) {
    return __fx_syscall3(SYS_READ, (long)fd, (long)buf, (long)count);
}

static inline long fx_write(int fd, const void *buf, size_t count) {
    return __fx_syscall3(SYS_WRITE, (long)fd, (long)buf, (long)count);
}

static inline int fx_close(int fd) {
    return (int)__fx_syscall1(SYS_CLOSE, (long)fd);
}

static inline int fx_stat(int fd, struct fx_stat *st) {
    return (int)__fx_syscall2(SYS_STAT, (long)fd, (long)st);
}

static inline long fx_seek(int fd, uint64_t offset, uint32_t whence) {
    return __fx_syscall3(SYS_SEEK, (long)fd, (long)offset, (long)whence);
}

static inline int fx_remove(const char *path, uint32_t flags) {
    return (int)__fx_syscall2(SYS_REMOVE, (long)path, (long)flags);
}

static inline void __attribute__((noreturn)) fx_exit(int status) {
    __fx_syscall1(SYS_EXIT, (long)status);
    __builtin_unreachable();
}

static inline int fx_pipe(void *result_ptr) {
    return (int)__fx_syscall1(SYS_PIPE, (long)result_ptr);
}

static inline long fx_brk(uint64_t addr) {
    return __fx_syscall1(SYS_BRK, (long)addr);
}

static inline int fx_rename(const char *old_path, uint32_t old_len,
                            const char *new_path, uint32_t new_len) {
    return (int)__fx_syscall4(SYS_RENAME, (long)old_path, (long)old_len,
                              (long)new_path, (long)new_len);
}

static inline int fx_truncate(int fd, uint64_t size) {
    return (int)__fx_syscall2(SYS_TRUNCATE, (long)fd, (long)size);
}

static inline int fx_sleep(uint32_t ms) {
    return (int)__fx_syscall1(SYS_SLEEP, (long)ms);
}

static inline uint32_t fx_getpid(void) {
    return (uint32_t)__fx_syscall1(SYS_GETPID, 0);
}

static inline int fx_sysinfo(struct fx_sysinfo *info) {
    return (int)__fx_syscall1(SYS_SYSINFO, (long)info);
}

static inline long fx_spawn(const void *elf, size_t elf_len,
                            const void *fd_map, size_t fd_map_len,
                            const void *argv) {
    return __fx_syscall5(SYS_SPAWN, (long)elf, (long)elf_len,
                         (long)fd_map, (long)fd_map_len, (long)argv);
}

static inline int fx_rfork(uint32_t flags) {
    return (int)__fx_syscall1(SYS_RFORK, (long)flags);
}

static inline long fx_mmap(void *addr, size_t length, int prot, int flags) {
    return __fx_syscall4(SYS_MMAP, (long)addr, (long)length, (long)prot, (long)flags);
}

static inline int fx_munmap(void *addr, size_t length) {
    return (int)__fx_syscall2(SYS_MUNMAP, (long)addr, (long)length);
}

static inline int fx_dup(int fd) {
    return (int)__fx_syscall1(SYS_DUP, (long)fd);
}

static inline int fx_dup2(int old_fd, int new_fd) {
    return (int)__fx_syscall2(SYS_DUP2, (long)old_fd, (long)new_fd);
}

static inline long fx_clone(uint64_t stack_top, uint64_t tls,
                            uint64_t ctid_ptr, uint64_t ptid_ptr, uint64_t flags) {
    return __fx_syscall5(SYS_CLONE, (long)stack_top, (long)tls,
                         (long)ctid_ptr, (long)ptid_ptr, (long)flags);
}

static inline long fx_futex(volatile int *addr, int op, int val) {
    return __fx_syscall4(SYS_FUTEX, (long)addr, (long)op, (long)val, 0);
}

/* ── Convenience helpers ─────────────────────────────────────────── */

/* Get argc from ARGV_BASE */
static inline uint64_t fx_argc(void) {
    return *(uint64_t *)0x7FFFFFEFF000ULL;
}

/* Get pointer to argv[0] */
static inline char **fx_argv(void) {
    return (char **)(0x7FFFFFEFF000ULL + 8);
}

/* Simple strlen */
static inline size_t fx_strlen(const char *s) {
    size_t n = 0;
    while (s[n]) n++;
    return n;
}

/* Write string to fd */
static inline long fx_puts(int fd, const char *s) {
    return fx_write(fd, s, fx_strlen(s));
}

#endif /* FORNAX_H */
