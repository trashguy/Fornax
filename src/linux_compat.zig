/// Linux syscall compatibility layer for Fornax containers.
///
/// Translates Linux syscall numbers and conventions to Fornax equivalents.
/// Per-arch syscall numbers: x86_64 uses legacy numbers, riscv64/aarch64
/// use the generic Linux ABI (no legacy syscalls like open/stat/pipe).
///
/// Detection: Process.compat == 1 (set via container config or ELF detection).
/// Dispatch: syscall.dispatch() routes here before Fornax SYS enum lookup.
const process = @import("process.zig");
const ipc = @import("ipc.zig");
const builtin = @import("builtin");
const klog = @import("klog.zig");
const namespace = @import("namespace.zig");

/// Resolve linuxd channel via namespace lookup (Plan 9 style).
fn getLinuxdChannel() ?ipc.ChannelId {
    const root_ns = namespace.getRootNamespace();
    const res = root_ns.resolve("/linux/") orelse return null;
    return res.channel_id;
}

// ── Linux syscall numbers (per-arch) ──────────────────────────────────────
// x86_64 has legacy syscalls (open=2, stat=4, pipe=22, etc.)
// riscv64/aarch64 use the generic Linux ABI (openat=56, fstatat=79, pipe2=59, etc.)
// Some syscalls share numbers across all arches (e.g. clone=220 on generic).

const is_x86_64 = builtin.cpu.arch == .x86_64;
const is_generic = builtin.cpu.arch == .riscv64 or builtin.cpu.arch == .aarch64;

// I/O
const LNX_READ: u64 = if (is_x86_64) 0 else 63;
const LNX_WRITE: u64 = if (is_x86_64) 1 else 64;
const LNX_CLOSE: u64 = if (is_x86_64) 3 else 57;
const LNX_FSTAT: u64 = if (is_x86_64) 5 else 80;
const LNX_LSEEK: u64 = if (is_x86_64) 8 else 62;
const LNX_MMAP: u64 = if (is_x86_64) 9 else 222;
const LNX_MPROTECT: u64 = if (is_x86_64) 10 else 226;
const LNX_MUNMAP: u64 = if (is_x86_64) 11 else 215;
const LNX_BRK: u64 = if (is_x86_64) 12 else 214;
const LNX_RT_SIGACTION: u64 = if (is_x86_64) 13 else 134;
const LNX_RT_SIGPROCMASK: u64 = if (is_x86_64) 14 else 135;
const LNX_IOCTL: u64 = if (is_x86_64) 16 else 29;
const LNX_READV: u64 = if (is_x86_64) 19 else 65;
const LNX_WRITEV: u64 = if (is_x86_64) 20 else 66;
const LNX_MADVISE: u64 = if (is_x86_64) 28 else 233;
const LNX_DUP: u64 = if (is_x86_64) 32 else 23;
const LNX_GETPID: u64 = if (is_x86_64) 39 else 172;
const LNX_CLONE: u64 = if (is_x86_64) 56 else 220;
const LNX_EXECVE: u64 = if (is_x86_64) 59 else 221;
const LNX_EXIT: u64 = if (is_x86_64) 60 else 93;
const LNX_WAIT4: u64 = if (is_x86_64) 61 else 260;
const LNX_UNAME: u64 = if (is_x86_64) 63 else 160;
const LNX_FCNTL: u64 = if (is_x86_64) 72 else 25;
const LNX_FTRUNCATE: u64 = if (is_x86_64) 77 else 46;
const LNX_GETCWD: u64 = if (is_x86_64) 79 else 17;
const LNX_FCHMOD: u64 = if (is_x86_64) 91 else 52;
const LNX_GETPPID: u64 = if (is_x86_64) 110 else 173;
const LNX_SETPGID: u64 = if (is_x86_64) 109 else 154;
const LNX_SETSID: u64 = if (is_x86_64) 112 else 157;
const LNX_GETTID: u64 = if (is_x86_64) 186 else 178;
const LNX_FUTEX: u64 = if (is_x86_64) 202 else 98;
const LNX_GETDENTS64: u64 = if (is_x86_64) 217 else 61;
const LNX_SET_TID_ADDRESS: u64 = if (is_x86_64) 218 else 96;
const LNX_CLOCK_GETTIME: u64 = if (is_x86_64) 228 else 113;
const LNX_EXIT_GROUP: u64 = if (is_x86_64) 231 else 94;
const LNX_OPENAT: u64 = if (is_x86_64) 257 else 56;
const LNX_MKDIRAT: u64 = if (is_x86_64) 258 else 34;
const LNX_NEWFSTATAT: u64 = if (is_x86_64) 262 else 79;
const LNX_UNLINKAT: u64 = if (is_x86_64) 263 else 35;
const LNX_SET_ROBUST_LIST: u64 = if (is_x86_64) 273 else 99;
const LNX_PIPE2: u64 = if (is_x86_64) 293 else 59;
const LNX_PRLIMIT64: u64 = if (is_x86_64) 302 else 261;
const LNX_RENAMEAT2: u64 = if (is_x86_64) 316 else 276;
const LNX_GETRANDOM: u64 = if (is_x86_64) 318 else 278;

// x86_64-only legacy syscalls. On generic arches, each gets a unique
// high sentinel value that never matches real syscall numbers, so the
// switch arms compile but never fire.
const LNX_OPEN: u64 = if (is_x86_64) 2 else 0x8000_0001;
const LNX_STAT: u64 = if (is_x86_64) 4 else 0x8000_0002;
const LNX_LSTAT: u64 = if (is_x86_64) 6 else 0x8000_0003;
const LNX_ACCESS: u64 = if (is_x86_64) 21 else 0x8000_0004;
const LNX_PIPE: u64 = if (is_x86_64) 22 else 0x8000_0005;
const LNX_DUP2: u64 = if (is_x86_64) 33 else 0x8000_0006;
const LNX_FORK: u64 = if (is_x86_64) 57 else 0x8000_0007;
const LNX_VFORK: u64 = if (is_x86_64) 58 else 0x8000_0008;
const LNX_RENAME: u64 = if (is_x86_64) 82 else 0x8000_0009;
const LNX_MKDIR: u64 = if (is_x86_64) 83 else 0x8000_000A;
const LNX_RMDIR: u64 = if (is_x86_64) 84 else 0x8000_000B;
const LNX_CREAT: u64 = if (is_x86_64) 85 else 0x8000_000C;
const LNX_UNLINK: u64 = if (is_x86_64) 87 else 0x8000_000D;
const LNX_READLINK: u64 = if (is_x86_64) 89 else 0x8000_000E;
const LNX_ARCH_PRCTL: u64 = if (is_x86_64) 158 else 0x8000_000F;
const LNX_RENAMEAT: u64 = if (is_x86_64) 264 else 0x8000_0010;

// Generic-only syscalls (riscv64/aarch64). On x86_64, unique sentinels.
const LNX_DUP3: u64 = if (is_x86_64) 0x8000_0011 else 24;
const LNX_FACCESSAT: u64 = if (is_x86_64) 0x8000_0012 else 48;

// Socket syscalls
const LNX_SOCKET: u64 = if (is_x86_64) 41 else 198;
const LNX_CONNECT: u64 = if (is_x86_64) 42 else 203;
const LNX_ACCEPT: u64 = if (is_x86_64) 43 else 202;
const LNX_SENDTO: u64 = if (is_x86_64) 44 else 206;
const LNX_RECVFROM: u64 = if (is_x86_64) 45 else 207;
const LNX_SENDMSG: u64 = if (is_x86_64) 46 else 211;
const LNX_RECVMSG: u64 = if (is_x86_64) 47 else 212;
const LNX_SHUTDOWN: u64 = if (is_x86_64) 48 else 210;
const LNX_BIND: u64 = if (is_x86_64) 49 else 200;
const LNX_LISTEN: u64 = if (is_x86_64) 50 else 201;
const LNX_GETSOCKNAME: u64 = if (is_x86_64) 51 else 204;
const LNX_GETPEERNAME: u64 = if (is_x86_64) 52 else 205;
const LNX_SOCKETPAIR: u64 = if (is_x86_64) 53 else 199;
const LNX_SETSOCKOPT: u64 = if (is_x86_64) 54 else 208;
const LNX_GETSOCKOPT: u64 = if (is_x86_64) 55 else 209;
const LNX_ACCEPT4: u64 = if (is_x86_64) 288 else 242;

// Poll/select/nanosleep
const LNX_POLL: u64 = if (is_x86_64) 7 else 0x8000_0017;
const LNX_SELECT: u64 = if (is_x86_64) 23 else 0x8000_0018;
const LNX_PPOLL: u64 = if (is_x86_64) 271 else 73;
const LNX_PSELECT6: u64 = if (is_x86_64) 270 else 72;
const LNX_NANOSLEEP: u64 = if (is_x86_64) 35 else 101;
const LNX_GETRUSAGE: u64 = if (is_x86_64) 98 else 165;
const LNX_TKILL: u64 = if (is_x86_64) 200 else 0x8000_0013;
const LNX_TGKILL: u64 = if (is_x86_64) 234 else 131;

// ── Wave 0: Identity & Credentials ──────────────────────────────────────
const LNX_GETUID: u64 = if (is_x86_64) 102 else 174;
const LNX_GETEUID: u64 = if (is_x86_64) 107 else 175;
const LNX_GETGID: u64 = if (is_x86_64) 104 else 176;
const LNX_GETEGID: u64 = if (is_x86_64) 108 else 177;
const LNX_SETUID: u64 = if (is_x86_64) 105 else 146;
const LNX_SETGID: u64 = if (is_x86_64) 106 else 144;
const LNX_SETREUID: u64 = if (is_x86_64) 113 else 145;
const LNX_SETREGID: u64 = if (is_x86_64) 114 else 143;
const LNX_SETRESUID: u64 = if (is_x86_64) 117 else 147;
const LNX_SETRESGID: u64 = if (is_x86_64) 119 else 149;
const LNX_GETRESUID: u64 = if (is_x86_64) 118 else 148;
const LNX_GETRESGID: u64 = if (is_x86_64) 120 else 150;
const LNX_SETFSUID: u64 = if (is_x86_64) 122 else 151;
const LNX_SETFSGID: u64 = if (is_x86_64) 123 else 152;
const LNX_GETGROUPS: u64 = if (is_x86_64) 115 else 158;
const LNX_SETGROUPS: u64 = if (is_x86_64) 116 else 159;
const LNX_CAPGET: u64 = if (is_x86_64) 125 else 90;
const LNX_CAPSET: u64 = if (is_x86_64) 126 else 91;
const LNX_GETPGRP: u64 = if (is_x86_64) 111 else 0x8000_0030;
const LNX_GETPGID: u64 = if (is_x86_64) 121 else 155;
const LNX_GETSID: u64 = if (is_x86_64) 124 else 156;

// ── Wave 0: Time & Info ─────────────────────────────────────────────────
const LNX_GETTIMEOFDAY: u64 = if (is_x86_64) 96 else 169;
const LNX_SYSINFO: u64 = if (is_x86_64) 99 else 179;
const LNX_GETRLIMIT: u64 = if (is_x86_64) 97 else 0x8000_0031;
const LNX_SETRLIMIT: u64 = if (is_x86_64) 160 else 0x8000_0032;
const LNX_TIMES: u64 = if (is_x86_64) 100 else 153;
const LNX_TIME: u64 = if (is_x86_64) 201 else 0x8000_0033;
const LNX_UMASK: u64 = if (is_x86_64) 95 else 166;
const LNX_PRCTL: u64 = if (is_x86_64) 157 else 167;
const LNX_PERSONALITY: u64 = if (is_x86_64) 135 else 0x8000_0034;

// ── Wave 0: Scheduling ──────────────────────────────────────────────────
const LNX_SCHED_YIELD: u64 = if (is_x86_64) 24 else 124;
const LNX_SCHED_GETAFFINITY: u64 = if (is_x86_64) 204 else 123;
const LNX_SCHED_SETAFFINITY: u64 = if (is_x86_64) 203 else 122;
const LNX_SCHED_GETPARAM: u64 = if (is_x86_64) 143 else 121;
const LNX_SCHED_SETPARAM: u64 = if (is_x86_64) 142 else 118;
const LNX_SCHED_GETSCHEDULER: u64 = if (is_x86_64) 145 else 120;
const LNX_SCHED_SETSCHEDULER: u64 = if (is_x86_64) 144 else 119;
const LNX_SCHED_GET_PRIORITY_MAX: u64 = if (is_x86_64) 146 else 125;
const LNX_SCHED_GET_PRIORITY_MIN: u64 = if (is_x86_64) 147 else 126;
const LNX_GETPRIORITY: u64 = if (is_x86_64) 140 else 141;
const LNX_SETPRIORITY: u64 = if (is_x86_64) 141 else 140;
const LNX_GETCPU: u64 = if (is_x86_64) 309 else 168;

// ── Wave 0: Signals (extended noops) ────────────────────────────────────
const LNX_KILL: u64 = if (is_x86_64) 62 else 129;
const LNX_ALARM: u64 = if (is_x86_64) 37 else 0x8000_0035;
const LNX_SIGALTSTACK: u64 = if (is_x86_64) 131 else 132;
const LNX_RT_SIGRETURN: u64 = if (is_x86_64) 15 else 139;
const LNX_RT_SIGPENDING: u64 = if (is_x86_64) 127 else 136;
const LNX_RT_SIGTIMEDWAIT: u64 = if (is_x86_64) 128 else 137;
const LNX_RT_SIGSUSPEND: u64 = if (is_x86_64) 130 else 133;
const LNX_RT_SIGQUEUEINFO: u64 = if (is_x86_64) 129 else 138;
const LNX_PAUSE: u64 = if (is_x86_64) 34 else 0x8000_0036;

// ── Wave 0: Time Extensions ─────────────────────────────────────────────
const LNX_CLOCK_GETRES: u64 = if (is_x86_64) 229 else 114;
const LNX_CLOCK_NANOSLEEP: u64 = if (is_x86_64) 230 else 115;
const LNX_SETITIMER: u64 = if (is_x86_64) 38 else 103;
const LNX_GETITIMER: u64 = if (is_x86_64) 36 else 102;

// ── Wave 0: Ownership/Permissions (noops) ───────────────────────────────
const LNX_CHOWN: u64 = if (is_x86_64) 92 else 0x8000_0037;
const LNX_FCHOWN: u64 = if (is_x86_64) 93 else 55;
const LNX_LCHOWN: u64 = if (is_x86_64) 94 else 0x8000_0038;
const LNX_FCHOWNAT: u64 = if (is_x86_64) 260 else 54;
const LNX_CHMOD: u64 = if (is_x86_64) 90 else 0x8000_0039;
const LNX_FCHMODAT: u64 = if (is_x86_64) 268 else 53;
const LNX_CHDIR: u64 = if (is_x86_64) 80 else 49;
const LNX_FCHDIR: u64 = if (is_x86_64) 81 else 50;

// ── Wave 0: Misc Stubs ─────────────────────────────────────────────────
const LNX_MEMBARRIER: u64 = if (is_x86_64) 324 else 283;
const LNX_CHROOT: u64 = if (is_x86_64) 161 else 51;
const LNX_SYNC: u64 = if (is_x86_64) 162 else 81;
const LNX_MKNOD: u64 = if (is_x86_64) 133 else 0x8000_003A;
const LNX_MKNODAT: u64 = if (is_x86_64) 259 else 33;
const LNX_VHANGUP: u64 = if (is_x86_64) 153 else 58;
const LNX_CLOSE_RANGE: u64 = if (is_x86_64) 436 else 436;

// ── Wave 1: File I/O ────────────────────────────────────────────────────
const LNX_PREAD64: u64 = if (is_x86_64) 17 else 67;
const LNX_PWRITE64: u64 = if (is_x86_64) 18 else 68;
const LNX_TRUNCATE: u64 = if (is_x86_64) 76 else 45;
const LNX_FSYNC: u64 = if (is_x86_64) 74 else 82;
const LNX_FDATASYNC: u64 = if (is_x86_64) 75 else 83;
const LNX_FSTATFS: u64 = if (is_x86_64) 138 else 44;
const LNX_STATFS: u64 = if (is_x86_64) 137 else 43;
const LNX_FALLOCATE: u64 = if (is_x86_64) 285 else 47;
const LNX_FLOCK: u64 = if (is_x86_64) 73 else 32;
const LNX_READAHEAD: u64 = if (is_x86_64) 187 else 213;
const LNX_FADVISE64: u64 = if (is_x86_64) 221 else 223;
const LNX_SENDFILE: u64 = if (is_x86_64) 40 else 71;
const LNX_COPY_FILE_RANGE: u64 = if (is_x86_64) 326 else 285;
const LNX_LINK: u64 = if (is_x86_64) 86 else 0x8000_003B;
const LNX_LINKAT: u64 = if (is_x86_64) 265 else 37;
const LNX_SYMLINK: u64 = if (is_x86_64) 88 else 0x8000_003C;
const LNX_SYMLINKAT: u64 = if (is_x86_64) 266 else 36;
const LNX_READLINKAT: u64 = if (is_x86_64) 267 else 78;
const LNX_UTIME: u64 = if (is_x86_64) 132 else 0x8000_003D;
const LNX_UTIMES: u64 = if (is_x86_64) 235 else 0x8000_003E;
const LNX_UTIMENSAT: u64 = if (is_x86_64) 280 else 88;

// ── Wave 2: Socket extensions ───────────────────────────────────────────
const LNX_SENDMMSG: u64 = if (is_x86_64) 307 else 269;
const LNX_RECVMMSG: u64 = if (is_x86_64) 299 else 243;

// ── Wave 3: Epoll/Eventfd/Timerfd ───────────────────────────────────────
const LNX_EPOLL_CREATE1: u64 = if (is_x86_64) 291 else 20;
const LNX_EPOLL_CTL: u64 = if (is_x86_64) 233 else 21;
const LNX_EPOLL_WAIT: u64 = if (is_x86_64) 232 else 0x8000_0040;
const LNX_EPOLL_PWAIT: u64 = if (is_x86_64) 281 else 22;
const LNX_EVENTFD: u64 = if (is_x86_64) 284 else 0x8000_0041;
const LNX_EVENTFD2: u64 = if (is_x86_64) 290 else 19;
const LNX_TIMERFD_CREATE: u64 = if (is_x86_64) 283 else 85;
const LNX_TIMERFD_SETTIME: u64 = if (is_x86_64) 286 else 86;
const LNX_TIMERFD_GETTIME: u64 = if (is_x86_64) 287 else 87;

// ── Wave 4: Memory extensions ───────────────────────────────────────────
const LNX_MREMAP: u64 = if (is_x86_64) 25 else 216;
const LNX_MLOCK: u64 = if (is_x86_64) 149 else 228;
const LNX_MUNLOCK: u64 = if (is_x86_64) 150 else 229;
const LNX_MLOCK2: u64 = if (is_x86_64) 325 else 284;
const LNX_MLOCKALL: u64 = if (is_x86_64) 151 else 230;
const LNX_MUNLOCKALL: u64 = if (is_x86_64) 152 else 231;
const LNX_MSYNC: u64 = if (is_x86_64) 26 else 227;
const LNX_MINCORE: u64 = if (is_x86_64) 27 else 232;
const LNX_MEMFD_CREATE: u64 = if (is_x86_64) 319 else 279;

// ── Wave 5: Process lifecycle ───────────────────────────────────────────
const LNX_WAITID: u64 = if (is_x86_64) 247 else 95;
const LNX_CLONE3: u64 = if (is_x86_64) 435 else 435;
const LNX_EXECVEAT: u64 = if (is_x86_64) 322 else 281;
const LNX_GETDENTS: u64 = if (is_x86_64) 78 else 0x8000_0042;

// ── Wave 6: Extended ioctl/fcntl/statx ──────────────────────────────────
const LNX_STATX: u64 = if (is_x86_64) 332 else 291;

// ── Explicit ENOSYS: architecturally impossible ─────────────────────────
const LNX_IO_URING_SETUP: u64 = if (is_x86_64) 425 else 425;
const LNX_IO_URING_ENTER: u64 = if (is_x86_64) 426 else 426;
const LNX_IO_URING_REGISTER: u64 = if (is_x86_64) 427 else 427;
const LNX_IO_SETUP: u64 = if (is_x86_64) 206 else 0;
const LNX_IO_SUBMIT: u64 = if (is_x86_64) 209 else 2;
const LNX_IO_GETEVENTS: u64 = if (is_x86_64) 208 else 4;
const LNX_IO_CANCEL: u64 = if (is_x86_64) 210 else 3;
const LNX_IO_DESTROY: u64 = if (is_x86_64) 207 else 1;
const LNX_INOTIFY_INIT: u64 = if (is_x86_64) 253 else 0x8000_0050;
const LNX_INOTIFY_INIT1: u64 = if (is_x86_64) 294 else 26;
const LNX_INOTIFY_ADD_WATCH: u64 = if (is_x86_64) 254 else 27;
const LNX_INOTIFY_RM_WATCH: u64 = if (is_x86_64) 255 else 28;
const LNX_FANOTIFY_INIT: u64 = if (is_x86_64) 300 else 262;
const LNX_FANOTIFY_MARK: u64 = if (is_x86_64) 301 else 263;
const LNX_SECCOMP: u64 = if (is_x86_64) 317 else 277;
const LNX_PTRACE: u64 = if (is_x86_64) 101 else 117;
const LNX_MOUNT: u64 = if (is_x86_64) 165 else 40;
const LNX_UMOUNT2: u64 = if (is_x86_64) 166 else 39;
const LNX_PIVOT_ROOT: u64 = if (is_x86_64) 155 else 41;
const LNX_UNSHARE: u64 = if (is_x86_64) 272 else 97;
const LNX_SETNS: u64 = if (is_x86_64) 308 else 268;
const LNX_PIDFD_OPEN: u64 = if (is_x86_64) 434 else 434;
const LNX_PIDFD_GETFD: u64 = if (is_x86_64) 438 else 438;
const LNX_PIDFD_SEND_SIGNAL: u64 = if (is_x86_64) 424 else 424;
const LNX_USERFAULTFD: u64 = if (is_x86_64) 323 else 282;
const LNX_PKEY_ALLOC: u64 = if (is_x86_64) 330 else 289;
const LNX_PKEY_FREE: u64 = if (is_x86_64) 331 else 290;
const LNX_PKEY_MPROTECT: u64 = if (is_x86_64) 329 else 288;
const LNX_MSGGET: u64 = if (is_x86_64) 68 else 186;
const LNX_MSGSND: u64 = if (is_x86_64) 69 else 189;
const LNX_MSGRCV: u64 = if (is_x86_64) 70 else 188;
const LNX_MSGCTL: u64 = if (is_x86_64) 71 else 187;
const LNX_SEMGET: u64 = if (is_x86_64) 64 else 190;
const LNX_SEMOP: u64 = if (is_x86_64) 65 else 193;
const LNX_SEMCTL: u64 = if (is_x86_64) 66 else 191;
const LNX_SEMTIMEDOP: u64 = if (is_x86_64) 220 else 192;
const LNX_SHMGET: u64 = if (is_x86_64) 29 else 194;
const LNX_SHMAT: u64 = if (is_x86_64) 30 else 196;
const LNX_SHMDT: u64 = if (is_x86_64) 67 else 197;
const LNX_SHMCTL: u64 = if (is_x86_64) 31 else 195;
const LNX_MQ_OPEN: u64 = if (is_x86_64) 240 else 180;
const LNX_MQ_UNLINK: u64 = if (is_x86_64) 241 else 181;
const LNX_MQ_TIMEDSEND: u64 = if (is_x86_64) 242 else 182;
const LNX_MQ_TIMEDRECEIVE: u64 = if (is_x86_64) 243 else 183;
const LNX_MQ_NOTIFY: u64 = if (is_x86_64) 244 else 184;
const LNX_MQ_GETSETATTR: u64 = if (is_x86_64) 245 else 185;
const LNX_SPLICE: u64 = if (is_x86_64) 275 else 76;
const LNX_TEE: u64 = if (is_x86_64) 276 else 77;
const LNX_VMSPLICE: u64 = if (is_x86_64) 278 else 75;
const LNX_PROCESS_VM_READV: u64 = if (is_x86_64) 310 else 270;
const LNX_PROCESS_VM_WRITEV: u64 = if (is_x86_64) 311 else 271;
const LNX_BPF: u64 = if (is_x86_64) 321 else 280;
const LNX_RSEQ: u64 = if (is_x86_64) 334 else 293;
const LNX_OPENAT2: u64 = if (is_x86_64) 437 else 437;
const LNX_ADD_KEY: u64 = if (is_x86_64) 248 else 217;
const LNX_REQUEST_KEY: u64 = if (is_x86_64) 249 else 218;
const LNX_KEYCTL: u64 = if (is_x86_64) 250 else 219;
const LNX_SWAPON: u64 = if (is_x86_64) 167 else 224;
const LNX_SWAPOFF: u64 = if (is_x86_64) 168 else 225;
const LNX_REBOOT: u64 = if (is_x86_64) 169 else 142;
const LNX_QUOTACTL: u64 = if (is_x86_64) 179 else 60;
const LNX_SYSLOG: u64 = if (is_x86_64) 103 else 116;
const LNX_ACCT: u64 = if (is_x86_64) 163 else 89;
const LNX_KCMP: u64 = if (is_x86_64) 312 else 272;
// xattr family
const LNX_SETXATTR: u64 = if (is_x86_64) 188 else 5;
const LNX_LSETXATTR: u64 = if (is_x86_64) 189 else 6;
const LNX_FSETXATTR: u64 = if (is_x86_64) 190 else 7;
const LNX_GETXATTR: u64 = if (is_x86_64) 191 else 8;
const LNX_LGETXATTR: u64 = if (is_x86_64) 192 else 9;
const LNX_FGETXATTR: u64 = if (is_x86_64) 193 else 10;
const LNX_LISTXATTR: u64 = if (is_x86_64) 194 else 11;
const LNX_LLISTXATTR: u64 = if (is_x86_64) 195 else 12;
const LNX_FLISTXATTR: u64 = if (is_x86_64) 196 else 13;
const LNX_REMOVEXATTR: u64 = if (is_x86_64) 197 else 14;
const LNX_LREMOVEXATTR: u64 = if (is_x86_64) 198 else 15;
const LNX_FREMOVEXATTR: u64 = if (is_x86_64) 199 else 16;
const LNX_SETHOSTNAME: u64 = if (is_x86_64) 170 else 161;
const LNX_SETDOMAINNAME: u64 = if (is_x86_64) 171 else 162;
const LNX_ADJTIMEX: u64 = if (is_x86_64) 159 else 171;
const LNX_IOPL: u64 = if (is_x86_64) 172 else 0x8000_0051;
const LNX_IOPERM: u64 = if (is_x86_64) 173 else 0x8000_0052;
const LNX_SIGNALFD: u64 = if (is_x86_64) 282 else 0x8000_0053;
const LNX_SIGNALFD4: u64 = if (is_x86_64) 289 else 74;
const LNX_TIMER_CREATE: u64 = if (is_x86_64) 222 else 107;
const LNX_TIMER_SETTIME: u64 = if (is_x86_64) 223 else 110;
const LNX_TIMER_GETTIME: u64 = if (is_x86_64) 224 else 108;
const LNX_TIMER_GETOVERRUN: u64 = if (is_x86_64) 225 else 109;
const LNX_TIMER_DELETE: u64 = if (is_x86_64) 226 else 111;

// Linux constants
const AT_FDCWD: u64 = @bitCast(@as(i64, -100));
const O_CREAT: u64 = 0o100;
const O_DIRECTORY: u64 = 0o200000;
const O_APPEND: u64 = 0o2000;
const O_TRUNC: u64 = 0o1000;
const F_DUPFD: u64 = 0;
const F_GETFD: u64 = 1;
const F_SETFD: u64 = 2;
const F_GETFL: u64 = 3;
const F_SETFL: u64 = 4;
const TIOCGWINSZ: u64 = 0x5413;
const FIONREAD: u64 = 0x541B;
const FIONBIO: u64 = 0x5421;
const TCGETS: u64 = 0x5401;
const TIOCGSID: u64 = 0x5429;
const F_DUPFD_CLOEXEC: u64 = 1030;
const F_GETPIPE_SZ: u64 = 1032;
const F_SETPIPE_SZ: u64 = 1031;

// prctl constants
const PR_SET_NAME: u64 = 15;
const PR_GET_NAME: u64 = 16;
const PR_SET_TIMERSLACK: u64 = 29;
const PR_GET_TIMERSLACK: u64 = 30;

// rlimit resource types
const RLIMIT_NOFILE: u64 = 7;
const RLIMIT_NPROC: u64 = 6;
const RLIMIT_AS: u64 = 9;
const RLIMIT_STACK: u64 = 3;
const RLIMIT_FSIZE: u64 = 1;
const RLIMIT_DATA: u64 = 2;

// Fornax rfork flags (from lib/root.zig)
const RFPROC: u64 = 0x01;
const RFFDG: u64 = 0x04;

// Import Fornax syscall handlers
const syscall = @import("syscall.zig");
const linux_socket = @import("linux_socket.zig");

// Error constants (same as Fornax — already Linux-compatible negative values)
const ENOSYS: u64 = @bitCast(@as(i64, -38)); // Linux ENOSYS = 38
const ENOENT: u64 = @bitCast(@as(i64, -2));
const EFAULT: u64 = @bitCast(@as(i64, -14));
const EBADF: u64 = @bitCast(@as(i64, -9));
const EINVAL: u64 = @bitCast(@as(i64, -22));
const EIO: u64 = @bitCast(@as(i64, -5));
const ENOMEM: u64 = @bitCast(@as(i64, -12));
const ENOTTY: u64 = @bitCast(@as(i64, -25));
const ERANGE: u64 = @bitCast(@as(i64, -34));
const EINTR: u64 = @bitCast(@as(i64, -4));
const EPERM: u64 = @bitCast(@as(i64, -1));
const ESRCH: u64 = @bitCast(@as(i64, -3));
const ENOTSUP: u64 = @bitCast(@as(i64, -95));

// ── Main dispatch ─────────────────────────────────────────────────────────

/// Translates a Linux syscall to Fornax equivalents.
/// Called from syscall.dispatch() when proc.compat == 1.
/// Handles both x86_64 legacy and riscv64/aarch64 generic ABI numbers.
pub fn linuxDispatch(nr: u64, a: u64, b: u64, c: u64, d: u64, e: u64) u64 {
    return switch (nr) {
        // ── I/O ───────────────────────────────────────────────────
        LNX_READ => syscall.sysRead(a, b, c),
        LNX_WRITE => syscall.sysWrite(a, b, c),
        LNX_OPEN => linuxOpen(a, b, c),
        LNX_OPENAT => linuxOpenat(a, b, c, d),
        LNX_CLOSE => linux_socket.linuxClose(a),
        LNX_LSEEK => syscall.sysSeek(a, b, c),
        LNX_READV => linuxReadv(a, b, c),
        LNX_WRITEV => linuxWritev(a, b, c),
        LNX_PREAD64 => linuxPread64(a, b, c, d),
        LNX_PWRITE64 => linuxPwrite64(a, b, c, d),
        LNX_SENDFILE => linuxSendfile(a, b, c),
        LNX_COPY_FILE_RANGE => linuxCopyFileRange(a, b, c, d, e),

        // ── File metadata ─────────────────────────────────────────
        LNX_STAT, LNX_LSTAT => linuxPathStat(a, b),
        LNX_FSTAT => linuxFstat(a, b),
        LNX_NEWFSTATAT => linuxNewfstatat(a, b, c, d),
        LNX_STATX => linuxStatx(a, b, c, e),
        LNX_FSTATFS => linuxFstatfs(a, b),
        LNX_STATFS => linuxStatfs(a, b),

        // ── Memory management ─────────────────────────────────────
        LNX_MMAP => linuxMmap(a, b, c, d),
        LNX_MUNMAP => syscall.sysMunmap(a, b),
        LNX_MPROTECT => 0, // no-op
        LNX_MADVISE => 0, // no-op
        LNX_BRK => syscall.sysBrk(a),
        LNX_MREMAP => linuxMremap(a, b, c, d),
        LNX_MLOCK, LNX_MUNLOCK, LNX_MLOCK2, LNX_MLOCKALL, LNX_MUNLOCKALL => 0,
        LNX_MSYNC => 0,
        LNX_MINCORE => linuxMincore(a, b, c),
        LNX_MEMFD_CREATE => linuxMemfdCreate(),

        // ── File descriptors ──────────────────────────────────────
        LNX_DUP => syscall.sysDup(a),
        LNX_DUP2 => syscall.sysDup2(a, b),
        LNX_DUP3 => syscall.sysDup2(a, b), // dup3 flags ignored
        LNX_PIPE => syscall.sysPipe(a),
        LNX_PIPE2 => syscall.sysPipe(a),
        LNX_FCNTL => linuxFcntl(a, b),
        LNX_CLOSE_RANGE => linuxCloseRange(a, b),

        // ── Filesystem operations ─────────────────────────────────
        LNX_RENAME => linuxRename(a, b),
        LNX_RENAMEAT, LNX_RENAMEAT2 => linuxRenameat(nr, a, b, c, d),
        LNX_MKDIR => linuxMkdir(a),
        LNX_MKDIRAT => linuxMkdirat(a, b),
        LNX_RMDIR, LNX_UNLINK => linuxRemove(a),
        LNX_UNLINKAT => linuxUnlinkat(a, b),
        LNX_CREAT => linuxCreat(a),
        LNX_FTRUNCATE => syscall.sysTruncate(a, b),
        LNX_TRUNCATE => linuxTruncate(a, b),
        LNX_ACCESS => linuxAccess(a),
        LNX_FACCESSAT => linuxFaccessat(a, b),
        LNX_READLINK => EINVAL, // no symlinks
        LNX_READLINKAT => EINVAL,
        LNX_FCHMOD, LNX_FCHMODAT => 0, // no-op
        LNX_FSYNC, LNX_FDATASYNC => 0, // fxfs CoW consistent
        LNX_FALLOCATE => 0,
        LNX_FLOCK => 0, // no advisory locks
        LNX_READAHEAD, LNX_FADVISE64 => 0, // no page cache
        LNX_LINK, LNX_LINKAT => ENOSYS, // no hard links
        LNX_SYMLINK, LNX_SYMLINKAT => ENOSYS, // no symlinks
        LNX_UTIME, LNX_UTIMES, LNX_UTIMENSAT => 0, // no-op
        LNX_GETDENTS64 => linuxGetdents64(a, b, c),
        LNX_GETDENTS => linuxGetdents64(a, b, c), // same impl

        // ── Process ───────────────────────────────────────────────
        LNX_EXIT => syscall.sysThreadExit(a),
        LNX_EXIT_GROUP => syscall.sysExit(a),
        LNX_GETPID, LNX_GETTID => syscall.sysGetpid(0),
        LNX_GETPPID => syscall.sysGetpid(1),
        LNX_FORK, LNX_VFORK => syscall.sysRfork(RFPROC | RFFDG),
        LNX_EXECVE, LNX_EXECVEAT => linuxExecve(a, b, c),
        LNX_WAIT4 => linuxWait4(a, b, c),
        LNX_WAITID => linuxWaitid(a, b, c, d),
        LNX_SETPGID, LNX_SETSID => 0,
        LNX_ARCH_PRCTL => syscall.sysArchPrctl(a, b),

        // ── Threading ─────────────────────────────────────────────
        LNX_CLONE => syscall.sysClone(b, e, d, c, a),
        LNX_CLONE3 => linuxClone3(a, b),
        LNX_FUTEX => syscall.sysFutex(a, b, c, d),
        LNX_SET_TID_ADDRESS => syscall.sysGetpid(0),
        LNX_SET_ROBUST_LIST => 0,

        // ── Identity & Credentials ───────────────────────────────
        LNX_GETUID, LNX_GETEUID => linuxGetuid(),
        LNX_GETGID, LNX_GETEGID => linuxGetgid(),
        LNX_SETUID => linuxSetuid(a),
        LNX_SETGID => linuxSetgid(a),
        LNX_SETREUID, LNX_SETRESUID => linuxSetuid(a),
        LNX_SETREGID, LNX_SETRESGID => linuxSetgid(a),
        LNX_GETRESUID => linuxGetresuid(a),
        LNX_GETRESGID => linuxGetresgid(a),
        LNX_SETFSUID => linuxGetuid(), // noop, return current uid
        LNX_SETFSGID => linuxGetgid(), // noop, return current gid
        LNX_GETGROUPS => 0, // no supplementary groups
        LNX_SETGROUPS => 0,
        LNX_CAPGET => linuxCapget(a, b),
        LNX_CAPSET => 0,
        LNX_GETPGRP, LNX_GETPGID, LNX_GETSID => syscall.sysGetpid(0),

        // ── Signals (all noops — no Unix signal model) ───────────
        LNX_RT_SIGACTION, LNX_RT_SIGPROCMASK => 0,
        LNX_TKILL, LNX_TGKILL => 0,
        LNX_KILL => linuxKill(a, b),
        LNX_ALARM => 0,
        LNX_SIGALTSTACK, LNX_RT_SIGRETURN => 0,
        LNX_RT_SIGPENDING => linuxRtSigpending(a, b),
        LNX_RT_SIGTIMEDWAIT => EINTR,
        LNX_RT_SIGSUSPEND => EINTR,
        LNX_RT_SIGQUEUEINFO => 0,
        LNX_PAUSE => linuxPause(),

        // ── Terminal / ioctl ──────────────────────────────────────
        LNX_IOCTL => linuxIoctl(a, b, c),

        // ── Time ──────────────────────────────────────────────────
        LNX_CLOCK_GETTIME => linuxClockGettime(a, b),
        LNX_CLOCK_GETRES => linuxClockGetres(a, b),
        LNX_CLOCK_NANOSLEEP => linux_socket.linuxNanosleep(c, d), // skip clk_id/flags, use req/rem
        LNX_GETTIMEOFDAY => linuxGettimeofday(a),
        LNX_NANOSLEEP => linux_socket.linuxNanosleep(a, b),
        LNX_SETITIMER => 0,
        LNX_GETITIMER => linuxGetitimer(a),
        LNX_TIME => linuxTime(a),
        LNX_TIMES => linuxTimes(a),

        // ── Info ──────────────────────────────────────────────────
        LNX_GETCWD => linuxGetcwd(a, b),
        LNX_UNAME => linuxUname(a),
        LNX_PRLIMIT64 => linuxPrlimit64(a, b, c, d),
        LNX_GETRLIMIT => linuxGetrlimit(a, b),
        LNX_SETRLIMIT => 0,
        LNX_SYSINFO => linuxSysinfo(a),
        LNX_UMASK => 0o022,
        LNX_PRCTL => linuxPrctl(a, b),
        LNX_PERSONALITY => 0,

        // ── Scheduling ───────────────────────────────────────────
        LNX_SCHED_YIELD => 0,
        LNX_SCHED_GETAFFINITY => linuxSchedGetaffinity(a, b, c),
        LNX_SCHED_SETAFFINITY => 0,
        LNX_SCHED_GETPARAM => linuxSchedGetparam(b),
        LNX_SCHED_SETPARAM, LNX_SCHED_SETSCHEDULER => 0,
        LNX_SCHED_GETSCHEDULER => 0, // SCHED_OTHER
        LNX_SCHED_GET_PRIORITY_MAX => 99,
        LNX_SCHED_GET_PRIORITY_MIN => 0,
        LNX_GETPRIORITY => 0,
        LNX_SETPRIORITY => 0,
        LNX_GETCPU => linuxGetcpu(a),

        // ── Resource usage ───────────────────────────────────────
        LNX_GETRUSAGE => linuxGetrusage(a, b),

        // ── Random ────────────────────────────────────────────────
        LNX_GETRANDOM => linuxGetrandom(a, b),

        // ── Ownership/Permissions (noops) ────────────────────────
        LNX_CHOWN, LNX_FCHOWN, LNX_LCHOWN, LNX_FCHOWNAT => 0,
        LNX_CHMOD => 0,
        LNX_CHDIR, LNX_FCHDIR => 0,

        // ── Misc stubs ───────────────────────────────────────────
        LNX_MEMBARRIER => 0,
        LNX_CHROOT => 0,
        LNX_SYNC => 0,
        LNX_MKNOD, LNX_MKNODAT => ENOSYS,
        LNX_VHANGUP => 0,

        // ── Sockets ──────────────────────────────────────────────
        LNX_SOCKET => linux_socket.linuxSocket(a, b, c),
        LNX_CONNECT => linux_socket.linuxConnect(a, b, c),
        LNX_BIND => linux_socket.linuxBind(a, b, c),
        LNX_LISTEN => linux_socket.linuxListen(a, b),
        LNX_ACCEPT, LNX_ACCEPT4 => linux_socket.linuxAccept(a, b, c),
        LNX_SETSOCKOPT => linux_socket.linuxSetsockopt(a, b, c, d, e),
        LNX_GETSOCKOPT => linux_socket.linuxGetsockopt(a, b, c, d, e),
        LNX_SHUTDOWN => linux_socket.linuxShutdown(a, b),
        LNX_GETPEERNAME => linux_socket.linuxGetpeername(a, b, c),
        LNX_GETSOCKNAME => linux_socket.linuxGetsockname(a, b, c),
        LNX_SENDTO => linux_socket.linuxSendto(a, b, c, d, e),
        LNX_RECVFROM => linux_socket.linuxRecvfrom(a, b, c, d, e),
        LNX_SENDMSG => linuxSendmsg(a, b),
        LNX_RECVMSG => linuxRecvmsg(a, b),
        LNX_SENDMMSG => linuxSendmmsg(a, b, c),
        LNX_RECVMMSG => linuxRecvmmsg(a, b, c),
        LNX_SOCKETPAIR => linux_socket.linuxSocketpair(a, b, c, d),

        // ── Poll / Select / Sleep ────────────────────────────────
        LNX_POLL, LNX_PPOLL => linux_socket.linuxPoll(a, b, c),
        LNX_SELECT, LNX_PSELECT6 => linux_socket.linuxSelect(a, b, c, d, e),

        // ── Epoll / Eventfd / Timerfd ────────────────────────────
        LNX_EPOLL_CREATE1 => linuxEpollCreate1(),
        LNX_EPOLL_CTL => linuxEpollCtl(a, b, c, d),
        LNX_EPOLL_WAIT, LNX_EPOLL_PWAIT => linuxEpollWait(a, b, c, d),
        LNX_EVENTFD, LNX_EVENTFD2 => linuxEventfd(a),
        LNX_TIMERFD_CREATE => linuxTimerfdCreate(),
        LNX_TIMERFD_SETTIME => linuxTimerfdSettime(a, b, c, d),
        LNX_TIMERFD_GETTIME => linuxTimerfdGettime(a, b),

        // ── Explicit ENOSYS stubs (architecturally impossible) ───
        LNX_IO_URING_SETUP, LNX_IO_URING_ENTER, LNX_IO_URING_REGISTER,
        LNX_IO_SETUP, LNX_IO_SUBMIT, LNX_IO_GETEVENTS, LNX_IO_CANCEL, LNX_IO_DESTROY,
        LNX_INOTIFY_INIT, LNX_INOTIFY_INIT1, LNX_INOTIFY_ADD_WATCH, LNX_INOTIFY_RM_WATCH,
        LNX_FANOTIFY_INIT, LNX_FANOTIFY_MARK,
        LNX_SECCOMP, LNX_PTRACE,
        LNX_MOUNT, LNX_UMOUNT2, LNX_PIVOT_ROOT,
        LNX_UNSHARE, LNX_SETNS,
        LNX_PIDFD_OPEN, LNX_PIDFD_GETFD, LNX_PIDFD_SEND_SIGNAL,
        LNX_USERFAULTFD,
        LNX_PKEY_ALLOC, LNX_PKEY_FREE, LNX_PKEY_MPROTECT,
        LNX_MSGGET, LNX_MSGSND, LNX_MSGRCV, LNX_MSGCTL,
        LNX_SEMGET, LNX_SEMOP, LNX_SEMCTL, LNX_SEMTIMEDOP,
        LNX_SHMGET, LNX_SHMAT, LNX_SHMDT, LNX_SHMCTL,
        LNX_MQ_OPEN, LNX_MQ_UNLINK, LNX_MQ_TIMEDSEND, LNX_MQ_TIMEDRECEIVE, LNX_MQ_NOTIFY, LNX_MQ_GETSETATTR,
        LNX_SPLICE, LNX_TEE, LNX_VMSPLICE,
        LNX_PROCESS_VM_READV, LNX_PROCESS_VM_WRITEV,
        LNX_BPF, LNX_RSEQ, LNX_OPENAT2,
        LNX_ADD_KEY, LNX_REQUEST_KEY, LNX_KEYCTL,
        LNX_SWAPON, LNX_SWAPOFF, LNX_REBOOT, LNX_QUOTACTL,
        LNX_SYSLOG, LNX_ACCT, LNX_KCMP,
        LNX_SETXATTR, LNX_LSETXATTR, LNX_FSETXATTR,
        LNX_GETXATTR, LNX_LGETXATTR, LNX_FGETXATTR,
        LNX_LISTXATTR, LNX_LLISTXATTR, LNX_FLISTXATTR,
        LNX_REMOVEXATTR, LNX_LREMOVEXATTR, LNX_FREMOVEXATTR,
        LNX_SETHOSTNAME, LNX_SETDOMAINNAME, LNX_ADJTIMEX,
        LNX_IOPL, LNX_IOPERM,
        LNX_SIGNALFD, LNX_SIGNALFD4,
        LNX_TIMER_CREATE, LNX_TIMER_SETTIME, LNX_TIMER_GETTIME, LNX_TIMER_GETOVERRUN, LNX_TIMER_DELETE,
        => ENOSYS,

        else => {
            klog.info("linux: unknown nr=");
            klog.infoDec(nr);
            klog.info("\n");
            return ENOSYS;
        },
    };
}

// ── Translation helpers ───────────────────────────────────────────────────

fn linuxOpen(path_ptr: u64, flags: u64, mode: u64) u64 {
    _ = mode;
    const path_len = strlenUser(path_ptr);
    if (path_len == 0) return ENOENT;

    if (flags & O_CREAT != 0) {
        var fx_flags: u64 = 0;
        if (flags & O_DIRECTORY != 0) fx_flags |= 0x01;
        if (flags & O_APPEND != 0) fx_flags |= 0x02;
        return syscall.sysCreate(path_ptr, path_len, fx_flags);
    } else {
        const fd = syscall.sysOpen(path_ptr, path_len);
        // If sysOpen blocked, it won't return here. We only handle non-blocking.
        if (isError(fd)) return fd;
        if (flags & O_TRUNC != 0) {
            _ = syscall.sysTruncate(fd, 0);
        }
        return fd;
    }
}

fn linuxOpenat(dirfd: u64, path_ptr: u64, flags: u64, mode: u64) u64 {
    if (dirfd != AT_FDCWD) return ENOSYS;
    return linuxOpen(path_ptr, flags, mode);
}

fn linuxFstat(fd: u64, linux_buf: u64) u64 {
    // Call Fornax stat — writes 32-byte Fornax stat to user buffer.
    // If sysStat blocks (IPC-backed fd), the delivery path in switchTo
    // checks proc.compat==1 and calls translateStatInPlace.
    const result = syscall.sysStat(fd, linux_buf);
    // If we reach here, sysStat returned without blocking (kernel-intercepted fd)
    if (result == 0) {
        translateStatInPlace(linux_buf);
    }
    return result;
}

fn linuxPathStat(path_ptr: u64, linux_buf: u64) u64 {
    // Multi-step: open → stat → translate → close.
    // For kernel-intercepted paths, all steps are non-blocking.
    // For IPC-backed paths, sysOpen blocks → state machine in IPC reply handler.
    const proc = process.getCurrent() orelse return ENOSYS;
    const path_len = strlenUser(path_ptr);
    if (path_len == 0) return ENOENT;

    // Save linux stat buf — sysOpen checks this to use .linux_stat_open pending_op
    proc.linux_stat_buf = linux_buf;
    const fd = syscall.sysOpen(path_ptr, path_len);

    // If we reach here, sysOpen returned without blocking
    proc.linux_stat_buf = 0;
    if (isError(fd)) return ENOENT;

    // Now stat the fd
    const stat_result = syscall.sysStat(fd, linux_buf);
    // If sysStat blocks, the pending_op for stat delivery + compat translation
    // is handled by the normal .stat path in switchTo.
    if (stat_result == 0) {
        translateStatInPlace(linux_buf);
    }
    _ = syscall.sysClose(fd);
    return stat_result;
}

fn linuxNewfstatat(dirfd: u64, path_ptr: u64, linux_buf: u64, flags: u64) u64 {
    _ = flags;
    if (dirfd != AT_FDCWD) return ENOSYS;
    return linuxPathStat(path_ptr, linux_buf);
}

fn linuxRename(old_ptr: u64, new_ptr: u64) u64 {
    const old_len = strlenUser(old_ptr);
    const new_len = strlenUser(new_ptr);
    if (old_len == 0 or new_len == 0) return ENOENT;
    return syscall.sysRename(old_ptr, old_len, new_ptr, new_len);
}

fn linuxRenameat(nr: u64, a: u64, b: u64, c: u64, d: u64) u64 {
    if (a != AT_FDCWD) return ENOSYS;
    const old_ptr = b;
    const new_ptr = if (nr == LNX_RENAMEAT2) d else c;
    if (nr == LNX_RENAMEAT2 and c != AT_FDCWD) return ENOSYS;
    return linuxRename(old_ptr, new_ptr);
}

fn linuxMkdir(path_ptr: u64) u64 {
    const path_len = strlenUser(path_ptr);
    if (path_len == 0) return ENOENT;
    return syscall.sysCreate(path_ptr, path_len, 0x01); // O_DIR
}

fn linuxMkdirat(dirfd: u64, path_ptr: u64) u64 {
    if (dirfd != AT_FDCWD) return ENOSYS;
    return linuxMkdir(path_ptr);
}

fn linuxRemove(path_ptr: u64) u64 {
    const path_len = strlenUser(path_ptr);
    if (path_len == 0) return ENOENT;
    return syscall.sysRemove(path_ptr, path_len);
}

fn linuxUnlinkat(dirfd: u64, path_ptr: u64) u64 {
    if (dirfd != AT_FDCWD) return ENOSYS;
    return linuxRemove(path_ptr);
}

fn linuxCreat(path_ptr: u64) u64 {
    const path_len = strlenUser(path_ptr);
    if (path_len == 0) return ENOENT;
    return syscall.sysCreate(path_ptr, path_len, 0);
}

fn linuxAccess(path_ptr: u64) u64 {
    const path_len = strlenUser(path_ptr);
    if (path_len == 0) return ENOENT;
    const fd = syscall.sysOpen(path_ptr, path_len);
    // If sysOpen blocked, we never reach here — process will resume
    // with the open fd in syscall_ret. Not ideal for access(), but
    // the process gets a valid fd instead of ENOENT, which is close enough.
    if (isError(fd)) return ENOENT;
    _ = syscall.sysClose(fd);
    return 0;
}

fn linuxFaccessat(dirfd: u64, path_ptr: u64) u64 {
    if (dirfd != AT_FDCWD) return ENOSYS;
    return linuxAccess(path_ptr);
}

fn linuxGetdents64(fd: u64, buf_ptr: u64, buf_size: u64) u64 {
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (buf_size < 280) return EINVAL; // need room for at least one entry

    // Read Fornax dir entries: each is name[64]+type(u32)+size(u32) = 72 bytes
    // Use a kernel-side buffer on the stack to read raw entries.
    var raw_buf: [72 * 16]u8 = undefined; // read up to 16 entries at a time
    const raw_ptr = @intFromPtr(&raw_buf);
    const read_result = syscall.sysRead(fd, raw_ptr, raw_buf.len);
    if (isError(read_result)) return read_result;
    if (read_result == 0) return 0; // end of directory

    const bytes_read = @min(read_result, raw_buf.len);
    const out: [*]u8 = @ptrFromInt(buf_ptr);
    var out_off: u64 = 0;
    var in_off: u64 = 0;

    while (in_off + 72 <= bytes_read) {
        // Parse Fornax DirEntry
        const name_start = in_off;
        var name_len: u64 = 0;
        while (name_len < 64 and raw_buf[name_start + name_len] != 0) : (name_len += 1) {}
        const ftype = @as(u32, raw_buf[in_off + 64]) |
            (@as(u32, raw_buf[in_off + 65]) << 8) |
            (@as(u32, raw_buf[in_off + 66]) << 16) |
            (@as(u32, raw_buf[in_off + 67]) << 24);
        in_off += 72;

        // Linux dirent64: { u64 d_ino, u64 d_off, u16 d_reclen, u8 d_type, char d_name[] }
        // d_reclen must be 8-byte aligned
        const reclen_raw = 19 + name_len + 1; // header(19) + name + null
        const reclen = (reclen_raw + 7) & ~@as(u64, 7);

        if (out_off + reclen > buf_size) break;

        // d_ino = 1 (fake)
        writeU64(out[out_off..][0..8], 1);
        // d_off = current offset (sequential)
        writeU64(out[out_off + 8 ..][0..8], in_off);
        // d_reclen
        out[out_off + 16] = @truncate(reclen);
        out[out_off + 17] = @truncate(reclen >> 8);
        // d_type: 4=DT_DIR, 8=DT_REG
        out[out_off + 18] = if (ftype == 1) 4 else 8;
        // d_name
        const name_dst = out_off + 19;
        @memcpy(out[name_dst..][0..name_len], raw_buf[name_start..][0..name_len]);
        out[name_dst + name_len] = 0;
        // Zero padding
        var pad = name_dst + name_len + 1;
        while (pad < out_off + reclen) : (pad += 1) {
            out[pad] = 0;
        }
        out_off += reclen;
    }
    return out_off;
}

fn linuxFcntl(fd: u64, cmd: u64) u64 {
    return switch (cmd) {
        F_DUPFD, F_DUPFD_CLOEXEC => syscall.sysDup(fd),
        F_GETFL, F_SETFL, F_GETFD, F_SETFD => 0,
        F_GETPIPE_SZ => 4096,
        F_SETPIPE_SZ => 0,
        else => 0, // be permissive for compat
    };
}

// ── Linux execve — forwarded to linuxd (userspace) ──────────────────────
// Stub: will be replaced by IPC forwarding to linuxd in task 5.

fn linuxExecve(path_ptr: u64, argv_ptr: u64, envp_ptr: u64) u64 {
    _ = envp_ptr; // Fornax has no environment variables
    const proc = process.getCurrent() orelse return ENOSYS;

    // Check linuxd is available (discovered via /linux/ namespace mount)
    const linuxd_chan_id = getLinuxdChannel() orelse return ENOSYS;
    const chan = ipc.getChannel(linuxd_chan_id) orelse return ENOSYS;

    // Validate and measure path
    const path_len = strlenUser(path_ptr);
    if (path_len == 0 or path_len > 512) return ENOENT;

    // Resolve path through process's namespace to get full fxfs path
    const path_slice: [*]const u8 = @ptrFromInt(path_ptr);
    const ns = proc.getNs();
    const resolved = ns.resolve(path_slice[0..path_len]) orelse return ENOENT;
    const prefix = resolved.prefix;
    const suffix = resolved.suffix;
    const full_path_len = prefix.len + suffix.len;
    if (full_path_len == 0 or full_path_len > 512) return ENOENT;

    // Serialize Linux argv (char** NULL-terminated) → Fornax wire format:
    // [argc: u32][total_str_len: u32][str0\0str1\0...]
    var argc: u32 = 0;
    var total_str_len: u32 = 0;

    if (argv_ptr != 0 and argv_ptr < 0x0000_8000_0000_0000) {
        const argv: [*]const u64 = @ptrFromInt(argv_ptr);
        while (argc < 64) {
            const arg = argv[argc];
            if (arg == 0) break;
            if (arg >= 0x0000_8000_0000_0000) break;
            const slen = strlenUser(arg);
            if (slen == 0) break;
            total_str_len += @intCast(slen + 1); // +1 for NUL
            argc += 1;
        }
    }

    // Build IPC message: [pid:4][path_len:2][argv_len:2][path...][argv_wire...]
    // argv_wire = [argc:4][total_str_len:4][strings...]
    const argv_wire_len: u32 = if (argc > 0 and total_str_len > 0 and total_str_len <= 3800) 8 + total_str_len else 8;
    const msg_data_len: u32 = 8 + @as(u32, @intCast(full_path_len)) + argv_wire_len;

    if (msg_data_len > ipc.effective_max_data) return EINVAL;

    proc.ipc_msg.reset(.t_open);

    // [pid:4]
    proc.ipc_msg.data_buf[0] = @truncate(proc.pid);
    proc.ipc_msg.data_buf[1] = @truncate(proc.pid >> 8);
    proc.ipc_msg.data_buf[2] = @truncate(proc.pid >> 16);
    proc.ipc_msg.data_buf[3] = @truncate(proc.pid >> 24);

    // [path_len:2]
    const path_len_u16: u16 = @intCast(full_path_len);
    proc.ipc_msg.data_buf[4] = @truncate(path_len_u16);
    proc.ipc_msg.data_buf[5] = @truncate(path_len_u16 >> 8);

    // [argv_len:2]
    const argv_len_u16: u16 = @intCast(argv_wire_len);
    proc.ipc_msg.data_buf[6] = @truncate(argv_len_u16);
    proc.ipc_msg.data_buf[7] = @truncate(argv_len_u16 >> 8);

    // [resolved_path: prefix + suffix]
    var off: u32 = 8;
    if (prefix.len > 0) {
        @memcpy(proc.ipc_msg.data_buf[off..][0..prefix.len], prefix);
        off += @intCast(prefix.len);
    }
    if (suffix.len > 0) {
        @memcpy(proc.ipc_msg.data_buf[off..][0..suffix.len], suffix);
        off += @intCast(suffix.len);
    }

    // [argv_wire: argc:4 + total_str_len:4 + strings...]
    proc.ipc_msg.data_buf[off] = @truncate(argc);
    proc.ipc_msg.data_buf[off + 1] = @truncate(argc >> 8);
    proc.ipc_msg.data_buf[off + 2] = @truncate(argc >> 16);
    proc.ipc_msg.data_buf[off + 3] = @truncate(argc >> 24);
    proc.ipc_msg.data_buf[off + 4] = @truncate(total_str_len);
    proc.ipc_msg.data_buf[off + 5] = @truncate(total_str_len >> 8);
    proc.ipc_msg.data_buf[off + 6] = @truncate(total_str_len >> 16);
    proc.ipc_msg.data_buf[off + 7] = @truncate(total_str_len >> 24);
    off += 8;

    // Copy string data from user memory
    if (argc > 0 and total_str_len > 0 and total_str_len <= 3800) {
        const argv2: [*]const u64 = @ptrFromInt(argv_ptr);
        var i: u32 = 0;
        while (i < argc) : (i += 1) {
            const arg = argv2[i];
            if (arg == 0 or arg >= 0x0000_8000_0000_0000) break;
            const slen: u32 = @intCast(strlenUser(arg));
            const src: [*]const u8 = @ptrFromInt(arg);
            if (off + slen + 1 > ipc.effective_max_data) break;
            @memcpy(proc.ipc_msg.data_buf[off..][0..slen], src[0..slen]);
            proc.ipc_msg.data_buf[off + slen] = 0; // NUL terminator
            off += slen + 1;
        }
    }

    proc.ipc_msg.data_len = off;
    proc.pending_op = .linux_exec_wait;
    proc.pending_fd = 0; // no fd to close on completion — linuxd uses its own

    // Send to linuxd
    const root_syscall = @import("syscall/root.zig");
    root_syscall.sendToServer(chan, proc);

    // Block — linuxd will reply after OP_EXEC + OP_SETARGV
    proc.state = .blocked;
    process.scheduleNext(); // noreturn
}

fn linuxWait4(pid: u64, status_ptr: u64, options: u64) u64 {
    var flags: u64 = 0;
    if (options & 1 != 0) flags |= 1; // WNOHANG

    // Convert pid=-1 to Fornax convention: 0 means any child
    const fx_pid: u64 = if (pid == @as(u64, @bitCast(@as(i64, -1)))) 0 else pid;

    const result = syscall.sysWait(fx_pid, flags);
    // If sysWait blocks, we don't reach here.

    if (result != 0 and !isError(result) and status_ptr != 0 and status_ptr < 0x0000_8000_0000_0000) {
        // Packed result: upper 32 = child pid, lower 32 = POSIX status word
        const status: *align(1) u32 = @ptrFromInt(status_ptr);
        status.* = @truncate(result); // lower 32 = status word
        return result >> 32; // upper 32 = child pid
    }
    return result;
}

fn linuxReadv(fd: u64, iov_ptr: u64, iovcnt: u64) u64 {
    if (iov_ptr == 0 or iov_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (iovcnt == 0) return 0;

    // iovec: { base: u64, len: u64 } = 16 bytes each
    const max_iov = @min(iovcnt, 16);
    var total: u64 = 0;
    var i: u64 = 0;
    while (i < max_iov) : (i += 1) {
        const entry_ptr = iov_ptr + i * 16;
        if (entry_ptr + 16 > 0x0000_8000_0000_0000) break;
        const base: *align(1) const u64 = @ptrFromInt(entry_ptr);
        const len: *align(1) const u64 = @ptrFromInt(entry_ptr + 8);
        if (len.* > 0) {
            const r = syscall.sysRead(fd, base.*, len.*);
            if (isError(r)) return if (total > 0) total else r;
            total += r;
            if (r < len.*) break; // short read
        }
    }
    return total;
}

fn linuxWritev(fd: u64, iov_ptr: u64, iovcnt: u64) u64 {
    if (iov_ptr == 0 or iov_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (iovcnt == 0) return 0;

    const max_iov = @min(iovcnt, 16);
    var total: u64 = 0;
    var i: u64 = 0;
    while (i < max_iov) : (i += 1) {
        const entry_ptr = iov_ptr + i * 16;
        if (entry_ptr + 16 > 0x0000_8000_0000_0000) break;
        const base: *align(1) const u64 = @ptrFromInt(entry_ptr);
        const len: *align(1) const u64 = @ptrFromInt(entry_ptr + 8);
        if (len.* > 0) {
            const r = syscall.sysWrite(fd, base.*, len.*);
            if (isError(r)) return if (total > 0) total else r;
            total += r;
        }
    }
    return total;
}

fn linuxIoctl(fd: u64, req: u64, arg: u64) u64 {
    _ = fd;
    if (req == TIOCGWINSZ) {
        if (arg != 0 and arg < 0x0000_8000_0000_0000) {
            const ws: *align(1) [8]u8 = @ptrFromInt(arg);
            @memset(ws, 0);
            ws[0] = 25; // rows
            ws[2] = 80; // cols
        }
        return 0;
    }
    if (req == FIONREAD) {
        // Report 0 bytes available
        if (arg != 0 and arg < 0x0000_8000_0000_0000) {
            const p: *align(1) u32 = @ptrFromInt(arg);
            p.* = 0;
        }
        return 0;
    }
    if (req == FIONBIO) return 0; // non-blocking noop
    if (req == TCGETS) {
        // Fake termios: return a plausible struct
        if (arg != 0 and arg < 0x0000_8000_0000_0000) {
            const dest: [*]u8 = @ptrFromInt(arg);
            @memset(dest[0..60], 0); // struct termios ~60 bytes
        }
        return 0;
    }
    if (req == TIOCGSID) {
        if (arg != 0 and arg < 0x0000_8000_0000_0000) {
            const p: *align(1) u32 = @ptrFromInt(arg);
            p.* = @truncate(syscall.sysGetpid(0));
        }
        return 0;
    }
    return ENOTTY;
}

fn linuxClockGettime(clk_id: u64, tp_ptr: u64) u64 {
    _ = clk_id;
    if (tp_ptr == 0 or tp_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    // struct timespec { i64 tv_sec, i64 tv_nsec }
    const timer_mod = @import("timer.zig");
    const uptime_ticks: u64 = timer_mod.getTicks();
    const tps: u64 = timer_mod.TICKS_PER_SEC;
    const uptime_secs = uptime_ticks / tps;
    const remainder_ticks = uptime_ticks % tps;
    const nsec = (remainder_ticks * 1_000_000_000) / tps;

    const sec_ptr: *align(1) u64 = @ptrFromInt(tp_ptr);
    const nsec_ptr: *align(1) u64 = @ptrFromInt(tp_ptr + 8);
    sec_ptr.* = uptime_secs;
    nsec_ptr.* = nsec;

    return 0;
}

fn linuxGetrusage(_: u64, usage_ptr: u64) u64 {
    if (usage_ptr == 0 or usage_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    const dest: [*]u8 = @ptrFromInt(usage_ptr);
    @memset(dest[0..144], 0);
    // Fill ru_utime (struct timeval at offset 0: tv_sec u64 + tv_usec u64)
    const timer_mod = @import("timer.zig");
    const ticks: u64 = timer_mod.getTicks();
    const tps: u64 = timer_mod.TICKS_PER_SEC;
    const secs = ticks / tps;
    const usecs = ((ticks % tps) * 1_000_000) / tps;
    writeU64(dest[0..8], secs);
    writeU64(dest[8..16], usecs);
    return 0;
}

fn linuxGetcwd(buf_ptr: u64, size: u64) u64 {
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    // Fornax doesn't track per-process cwd in kernel.
    // Return "/" as default (containers start in root).
    if (size < 2) return ERANGE;
    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    dest[0] = '/';
    dest[1] = 0;
    return buf_ptr; // Linux getcwd returns pointer on success
}

fn linuxUname(buf_ptr: u64) u64 {
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    // struct utsname { char [65] × 6 } = 390 bytes
    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    @memset(dest[0..390], 0);
    // sysname at offset 0
    const sysname = "Fornax";
    @memcpy(dest[0..sysname.len], sysname);
    // nodename at offset 65
    const nodename = "fornax";
    @memcpy(dest[65..][0..nodename.len], nodename);
    // release at offset 130
    const release = "0.1.0";
    @memcpy(dest[130..][0..release.len], release);
    // version at offset 195
    const version = "Phase 1002";
    @memcpy(dest[195..][0..version.len], version);
    // machine at offset 260
    const machine = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .riscv64 => "riscv64",
        .aarch64 => "aarch64",
        else => "unknown",
    };
    @memcpy(dest[260..][0..machine.len], machine);
    return 0;
}

fn linuxGetrandom(buf_ptr: u64, len: u64) u64 {
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    // Fill directly from kernel PRNG (same as /dev/random)
    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    const n = @min(len, 4096);
    const devfiles_mod = @import("devfiles.zig");
    devfiles_mod.devRandomFill(dest[0..n]);
    return n;
}

fn linuxMmap(addr: u64, length: u64, prot: u64, flags: u64) u64 {
    // Fornax mmap only supports MAP_ANONYMOUS. For file-backed mmap
    // (MAP_SHARED/MAP_PRIVATE without MAP_ANONYMOUS), treat as anonymous.
    // This gives iperf3 and similar programs their memory buffers without
    // requiring a page cache implementation.
    const MAP_ANONYMOUS: u64 = 0x20;
    const forced_flags = flags | MAP_ANONYMOUS;
    return syscall.sysMmap(addr, length, prot, forced_flags);
}

// ── Wave 0: Identity & Credentials ────────────────────────────────────────

fn linuxGetuid() u64 {
    return syscall.sysGetuid() & 0xFFFF;
}

fn linuxGetgid() u64 {
    return syscall.sysGetuid() >> 16;
}

fn linuxSetuid(uid: u64) u64 {
    const cur = syscall.sysGetuid();
    return syscall.sysSetuid(uid, cur >> 16);
}

fn linuxSetgid(gid: u64) u64 {
    const cur = syscall.sysGetuid();
    return syscall.sysSetuid(cur & 0xFFFF, gid);
}

fn linuxGetresuid(buf_ptr: u64) u64 {
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    const uid: u32 = @truncate(linuxGetuid());
    // buf_ptr points to 3 × u32 (ruid, euid, suid)
    const p: [*]align(1) u32 = @ptrFromInt(buf_ptr);
    p[0] = uid;
    p[1] = uid;
    p[2] = uid;
    return 0;
}

fn linuxGetresgid(buf_ptr: u64) u64 {
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    const gid: u32 = @truncate(linuxGetgid());
    const p: [*]align(1) u32 = @ptrFromInt(buf_ptr);
    p[0] = gid;
    p[1] = gid;
    p[2] = gid;
    return 0;
}

fn linuxCapget(hdr_ptr: u64, data_ptr: u64) u64 {
    _ = hdr_ptr;
    if (data_ptr == 0 or data_ptr >= 0x0000_8000_0000_0000) return 0;
    // struct __user_cap_data_struct × 2 (v3): each is { effective: u32, permitted: u32, inheritable: u32 }
    const dest: [*]u8 = @ptrFromInt(data_ptr);
    // Set all capability bits (fake root equivalent)
    @memset(dest[0..24], 0xFF);
    return 0;
}

// ── Wave 0: Signals ───────────────────────────────────────────────────────

fn linuxKill(pid: u64, sig: u64) u64 {
    if (sig == 0) {
        // Liveness check: just verify process exists
        const signed_pid: i64 = @bitCast(pid);
        if (signed_pid <= 0) return 0; // process groups always "exist"
        const proc = process.getByPid(@truncate(pid));
        if (proc == null) return ESRCH;
        return 0;
    }
    return 0; // no signal delivery
}

fn linuxRtSigpending(set_ptr: u64, sigsetsize: u64) u64 {
    if (set_ptr == 0 or set_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    const size = @min(sigsetsize, 128);
    const dest: [*]u8 = @ptrFromInt(set_ptr);
    @memset(dest[0..size], 0); // no pending signals
    return 0;
}

fn linuxPause() u64 {
    // Sleep for 60 seconds then return EINTR
    _ = syscall.sysSleep(60000);
    return EINTR;
}

// ── Wave 0: Time & Info ──────────────────────────────────────────────────

fn getUptimeAndTps() struct { ticks: u64, tps: u64 } {
    const timer_mod = @import("timer.zig");
    return .{ .ticks = timer_mod.getTicks(), .tps = timer_mod.TICKS_PER_SEC };
}

fn linuxGettimeofday(tv_ptr: u64) u64 {
    if (tv_ptr == 0 or tv_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    const t = getUptimeAndTps();
    const secs = t.ticks / t.tps;
    const usecs = ((t.ticks % t.tps) * 1_000_000) / t.tps;
    const dest: [*]u8 = @ptrFromInt(tv_ptr);
    writeU64(dest[0..8], secs);
    writeU64(dest[8..16], usecs);
    return 0;
}

fn linuxSysinfo(buf_ptr: u64) u64 {
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    // struct sysinfo (112 bytes): uptime, loads[3], totalram, freeram, ...
    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    @memset(dest[0..112], 0);

    const t = getUptimeAndTps();
    const uptime_secs = t.ticks / t.tps;
    // uptime at offset 0 (i64)
    writeU64(dest[0..8], uptime_secs);
    // totalram at offset 32 (u64)
    const pmm = @import("pmm.zig");
    const page_size: u64 = 4096;
    writeU64(dest[32..40], pmm.getTotalPages() * page_size);
    // freeram at offset 40 (u64)
    writeU64(dest[40..48], pmm.getFreePages() * page_size);
    // procs at offset 64 (u16)
    dest[64] = 16; // approximate
    // mem_unit at offset 104 (u32)
    writeU32(dest[104..108], 1);
    return 0;
}

fn linuxPrlimit64(pid: u64, resource: u64, new_ptr: u64, old_ptr: u64) u64 {
    _ = pid;
    _ = new_ptr;
    if (old_ptr != 0 and old_ptr < 0x0000_8000_0000_0000) {
        return writeRlimit(old_ptr, resource);
    }
    return 0; // set is a noop
}

fn linuxGetrlimit(resource: u64, buf_ptr: u64) u64 {
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    return writeRlimit(buf_ptr, resource);
}

fn writeRlimit(buf_ptr: u64, resource: u64) u64 {
    // struct rlimit { u64 rlim_cur, u64 rlim_max }
    const RLIM_INFINITY: u64 = @bitCast(@as(i64, -1));
    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    var cur: u64 = RLIM_INFINITY;
    var max: u64 = RLIM_INFINITY;
    if (resource == RLIMIT_NOFILE) {
        cur = 32;
        max = 32;
    } else if (resource == RLIMIT_NPROC) {
        cur = 128;
        max = 128;
    } else if (resource == RLIMIT_STACK) {
        cur = 256 * 1024; // 256 KB user stack
        max = 256 * 1024;
    }
    writeU64(dest[0..8], cur);
    writeU64(dest[8..16], max);
    return 0;
}

fn linuxTimes(buf_ptr: u64) u64 {
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    // struct tms { clock_t tms_utime, tms_stime, tms_cutime, tms_cstime } = 4 × i64
    const t = getUptimeAndTps();
    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    @memset(dest[0..32], 0);
    // tms_utime: approximate with uptime ticks
    writeU64(dest[0..8], t.ticks);
    return t.ticks; // return clock value
}

fn linuxTime(buf_ptr: u64) u64 {
    const t = getUptimeAndTps();
    const secs = t.ticks / t.tps;
    if (buf_ptr != 0 and buf_ptr < 0x0000_8000_0000_0000) {
        const p: *align(1) u64 = @ptrFromInt(buf_ptr);
        p.* = secs;
    }
    return secs;
}

fn linuxPrctl(option: u64, arg2: u64) u64 {
    if (option == PR_SET_NAME or option == PR_SET_TIMERSLACK) return 0;
    if (option == PR_GET_TIMERSLACK) return 1; // 1 ns
    if (option == PR_GET_NAME) {
        if (arg2 != 0 and arg2 < 0x0000_8000_0000_0000) {
            const dest: [*]u8 = @ptrFromInt(arg2);
            const name = "fornax";
            @memcpy(dest[0..name.len], name);
            dest[name.len] = 0;
        }
        return 0;
    }
    return EINVAL;
}

fn linuxClockGetres(_: u64, tp_ptr: u64) u64 {
    if (tp_ptr == 0 or tp_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    const dest: [*]u8 = @ptrFromInt(tp_ptr);
    writeU64(dest[0..8], 0); // tv_sec = 0
    writeU64(dest[8..16], 1_000_000); // tv_nsec = 1ms resolution
    return 0;
}

fn linuxGetitimer(buf_ptr: u64) u64 {
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    // struct itimerval { struct timeval it_interval, it_value } = 32 bytes
    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    @memset(dest[0..32], 0);
    return 0;
}

// ── Wave 0: Scheduling ──────────────────────────────────────────────────

fn linuxSchedGetaffinity(_: u64, cpusetsize: u64, mask_ptr: u64) u64 {
    if (mask_ptr == 0 or mask_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    const size = @min(cpusetsize, 128);
    if (size == 0) return EINVAL;
    const dest: [*]u8 = @ptrFromInt(mask_ptr);
    @memset(dest[0..size], 0xFF); // all CPUs available
    return @as(u64, size);
}

fn linuxSchedGetparam(buf_ptr: u64) u64 {
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    // struct sched_param { int sched_priority }
    const p: *align(1) u32 = @ptrFromInt(buf_ptr);
    p.* = 0;
    return 0;
}

fn linuxGetcpu(cpu_ptr: u64) u64 {
    if (cpu_ptr != 0 and cpu_ptr < 0x0000_8000_0000_0000) {
        const p: *align(1) u32 = @ptrFromInt(cpu_ptr);
        p.* = 0; // always report CPU 0
    }
    return 0;
}

// ── Wave 1: File I/O ─────────────────────────────────────────────────────

fn linuxPread64(fd: u64, buf_ptr: u64, count: u64, offset: u64) u64 {
    return syscall.sysPread(fd, buf_ptr, count, offset);
}

fn linuxPwrite64(fd: u64, buf_ptr: u64, count: u64, offset: u64) u64 {
    return syscall.sysPwrite(fd, buf_ptr, count, offset);
}

fn linuxTruncate(path_ptr: u64, length: u64) u64 {
    const path_len = strlenUser(path_ptr);
    if (path_len == 0) return ENOENT;
    const fd = syscall.sysOpen(path_ptr, path_len);
    if (isError(fd)) return fd;
    const result = syscall.sysTruncate(fd, length);
    _ = syscall.sysClose(fd);
    return result;
}

fn linuxFstatfs(_: u64, buf_ptr: u64) u64 {
    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    // struct statfs (120 bytes)
    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    @memset(dest[0..120], 0);
    // f_type at offset 0 (u64 on x86_64)
    writeU64(dest[0..8], 0x66786673); // "fxfs"
    // f_bsize at offset 8
    writeU64(dest[8..16], 4096);
    // f_blocks at offset 16
    const pmm = @import("pmm.zig");
    writeU64(dest[16..24], pmm.getTotalPages());
    // f_bfree at offset 24
    writeU64(dest[24..32], pmm.getFreePages());
    // f_bavail at offset 32
    writeU64(dest[32..40], pmm.getFreePages());
    // f_namelen at offset 48
    writeU64(dest[48..56], 64);
    // f_frsize at offset 56
    writeU64(dest[56..64], 4096);
    return 0;
}

fn linuxStatfs(path_ptr: u64, buf_ptr: u64) u64 {
    _ = path_ptr;
    return linuxFstatfs(0, buf_ptr);
}

fn linuxSendfile(out_fd: u64, in_fd: u64, count: u64) u64 {
    // Read from in_fd, write to out_fd in 4KB chunks
    var buf: [4096]u8 = undefined;
    const buf_addr = @intFromPtr(&buf);
    var remaining = count;
    var total: u64 = 0;

    while (remaining > 0) {
        const chunk = @min(remaining, 4096);
        const r = syscall.sysRead(in_fd, buf_addr, chunk);
        if (isError(r)) return if (total > 0) total else r;
        if (r == 0) break;
        const w = syscall.sysWrite(out_fd, buf_addr, r);
        if (isError(w)) return if (total > 0) total else w;
        total += w;
        remaining -= r;
    }
    return total;
}

fn linuxCopyFileRange(fd_in: u64, _: u64, fd_out: u64, _x: u64, len: u64) u64 {
    _ = _x;
    return linuxSendfile(fd_out, fd_in, len);
}

fn linuxCloseRange(first: u64, last: u64) u64 {
    var fd = first;
    while (fd <= last and fd < 32) : (fd += 1) {
        _ = syscall.sysClose(fd);
    }
    return 0;
}

// ── Wave 2: Socket extensions ────────────────────────────────────────────

fn linuxSendmsg(fd: u64, msg_ptr: u64) u64 {
    if (msg_ptr == 0 or msg_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    // struct msghdr { void* name, u32 namelen, struct iovec* iov, u64 iovlen, ... }
    // iov pointer is at offset 16, iovlen at offset 24
    const iov_ptr_p: *align(1) const u64 = @ptrFromInt(msg_ptr + 16);
    const iovlen_p: *align(1) const u64 = @ptrFromInt(msg_ptr + 24);
    return linuxWritev(fd, iov_ptr_p.*, iovlen_p.*);
}

fn linuxRecvmsg(fd: u64, msg_ptr: u64) u64 {
    if (msg_ptr == 0 or msg_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    const iov_ptr_p: *align(1) const u64 = @ptrFromInt(msg_ptr + 16);
    const iovlen_p: *align(1) const u64 = @ptrFromInt(msg_ptr + 24);
    return linuxReadv(fd, iov_ptr_p.*, iovlen_p.*);
}

fn linuxSendmmsg(fd: u64, msgvec_ptr: u64, vlen: u64) u64 {
    if (msgvec_ptr == 0 or msgvec_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    // struct mmsghdr { struct msghdr msg_hdr, u32 msg_len } — each is msghdr(56) + u32(4) = ~64 bytes
    // On x86_64, sizeof(mmsghdr) = 64
    const mmsghdr_size: u64 = 64;
    var sent: u64 = 0;
    while (sent < vlen) : (sent += 1) {
        const msg_addr = msgvec_ptr + sent * mmsghdr_size;
        if (msg_addr + mmsghdr_size > 0x0000_8000_0000_0000) break;
        const r = linuxSendmsg(fd, msg_addr);
        if (isError(r)) return if (sent > 0) sent else r;
        // Write msg_len field (u32 at offset 56 in mmsghdr)
        const len_ptr: *align(1) u32 = @ptrFromInt(msg_addr + 56);
        len_ptr.* = @truncate(r);
    }
    return sent;
}

fn linuxRecvmmsg(fd: u64, msgvec_ptr: u64, vlen: u64) u64 {
    if (msgvec_ptr == 0 or msgvec_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    const mmsghdr_size: u64 = 64;
    var received: u64 = 0;
    while (received < vlen) : (received += 1) {
        const msg_addr = msgvec_ptr + received * mmsghdr_size;
        if (msg_addr + mmsghdr_size > 0x0000_8000_0000_0000) break;
        const r = linuxRecvmsg(fd, msg_addr);
        if (isError(r)) return if (received > 0) received else r;
        const len_ptr: *align(1) u32 = @ptrFromInt(msg_addr + 56);
        len_ptr.* = @truncate(r);
    }
    return received;
}

// ── Wave 3: Epoll ────────────────────────────────────────────────────────

const EpollEntry = struct { fd: u8, events: u32, data: u64 };
const MAX_EPOLL_ENTRIES = 32;
const MAX_EPOLL_INSTANCES = 8;

const EpollInstance = struct {
    entries: [MAX_EPOLL_ENTRIES]EpollEntry,
    count: u8,
    in_use: bool,
};

var epoll_table: [MAX_EPOLL_INSTANCES]EpollInstance = init: {
    var t: [MAX_EPOLL_INSTANCES]EpollInstance = undefined;
    for (&t) |*inst| {
        inst.in_use = false;
        inst.count = 0;
        inst.entries = [_]EpollEntry{.{ .fd = 0, .events = 0, .data = 0 }} ** MAX_EPOLL_ENTRIES;
    }
    break :init t;
};

fn linuxEpollCreate1() u64 {
    // Find free epoll instance
    for (&epoll_table, 0..) |*inst, idx| {
        if (!inst.in_use) {
            inst.in_use = true;
            inst.count = 0;
            // Allocate a dev fd to track this epoll
            const proc = process.getCurrent() orelse return ENOMEM;
            const fd = proc.allocDevFd(.dev_epoll) orelse return ENOMEM;
            // Store epoll index in the fd's read_offset field
            if (proc.getFdEntryPtr(fd)) |entry| {
                entry.read_offset = @truncate(idx);
            }
            return fd;
        }
    }
    return ENOMEM;
}

const EPOLL_CTL_ADD: u64 = 1;
const EPOLL_CTL_DEL: u64 = 2;
const EPOLL_CTL_MOD: u64 = 3;

fn linuxEpollCtl(epfd: u64, op: u64, fd: u64, event_ptr: u64) u64 {
    const proc = process.getCurrent() orelse return EBADF;
    const entry = proc.getFdEntry(@truncate(epfd)) orelse return EBADF;
    if (entry.fd_type != .dev_epoll) return EBADF;
    const idx = entry.read_offset;
    if (idx >= MAX_EPOLL_INSTANCES) return EBADF;
    var inst = &epoll_table[idx];

    if (op == EPOLL_CTL_ADD) {
        if (inst.count >= MAX_EPOLL_ENTRIES) return ENOMEM;
        var events: u32 = 0;
        var data: u64 = 0;
        if (event_ptr != 0 and event_ptr < 0x0000_8000_0000_0000) {
            const ep: [*]const u8 = @ptrFromInt(event_ptr);
            events = readU32(ep[0..4]);
            data = readU64(ep[4..12]);
        }
        inst.entries[inst.count] = .{ .fd = @truncate(fd), .events = events, .data = data };
        inst.count += 1;
        return 0;
    } else if (op == EPOLL_CTL_DEL) {
        var i: u8 = 0;
        while (i < inst.count) : (i += 1) {
            if (inst.entries[i].fd == @as(u8, @truncate(fd))) {
                // Swap with last
                inst.entries[i] = inst.entries[inst.count - 1];
                inst.count -= 1;
                return 0;
            }
        }
        return ENOENT;
    } else if (op == EPOLL_CTL_MOD) {
        var i: u8 = 0;
        while (i < inst.count) : (i += 1) {
            if (inst.entries[i].fd == @as(u8, @truncate(fd))) {
                if (event_ptr != 0 and event_ptr < 0x0000_8000_0000_0000) {
                    const ep: [*]const u8 = @ptrFromInt(event_ptr);
                    inst.entries[i].events = readU32(ep[0..4]);
                    inst.entries[i].data = readU64(ep[4..12]);
                }
                return 0;
            }
        }
        return ENOENT;
    }
    return EINVAL;
}

fn linuxEpollWait(epfd: u64, events_ptr: u64, maxevents: u64, timeout: u64) u64 {
    const proc = process.getCurrent() orelse return EBADF;
    const fd_entry = proc.getFdEntry(@truncate(epfd)) orelse return EBADF;
    if (fd_entry.fd_type != .dev_epoll) return EBADF;
    const idx = fd_entry.read_offset;
    if (idx >= MAX_EPOLL_INSTANCES) return EBADF;
    const inst = &epoll_table[idx];

    if (events_ptr == 0 or events_ptr >= 0x0000_8000_0000_0000) return EFAULT;

    // Each epoll_event is 12 bytes: u32 events + u64 data
    var ready: u64 = 0;
    const out: [*]u8 = @ptrFromInt(events_ptr);
    var i: u8 = 0;
    while (i < inst.count and ready < maxevents) : (i += 1) {
        // For simplicity, report all watched fds as ready (EPOLLIN|EPOLLOUT)
        const offset = ready * 12;
        writeU32(out[offset..][0..4], inst.entries[i].events & 0x7); // mask to IN/OUT/ERR
        writeU64(out[offset + 4 ..][0..8], inst.entries[i].data);
        ready += 1;
    }

    if (ready == 0 and timeout != 0) {
        // Sleep briefly then report nothing
        const sleep_ms = if (timeout == @as(u64, @bitCast(@as(i64, -1)))) @as(u64, 100) else @min(timeout, 100);
        _ = syscall.sysSleep(sleep_ms);
    }
    return ready;
}

// ── Wave 3: Eventfd ──────────────────────────────────────────────────────

const MAX_EVENTFDS = 16;
var eventfd_counters: [MAX_EVENTFDS]u64 = [_]u64{0} ** MAX_EVENTFDS;
var eventfd_in_use: [MAX_EVENTFDS]bool = [_]bool{false} ** MAX_EVENTFDS;

fn linuxEventfd(initval: u64) u64 {
    // Find free eventfd slot
    for (&eventfd_in_use, 0..) |*used, idx| {
        if (!used.*) {
            used.* = true;
            eventfd_counters[idx] = initval;
            const proc = process.getCurrent() orelse return ENOMEM;
            const fd = proc.allocDevFd(.dev_eventfd) orelse return ENOMEM;
            if (proc.getFdEntryPtr(fd)) |entry| {
                entry.read_offset = @truncate(idx);
            }
            return fd;
        }
    }
    return ENOMEM;
}

// ── Wave 3: Timerfd ──────────────────────────────────────────────────────

const MAX_TIMERFDS = 16;
var timerfd_deadlines: [MAX_TIMERFDS]u64 = [_]u64{0} ** MAX_TIMERFDS;
var timerfd_intervals: [MAX_TIMERFDS]u64 = [_]u64{0} ** MAX_TIMERFDS;
var timerfd_in_use: [MAX_TIMERFDS]bool = [_]bool{false} ** MAX_TIMERFDS;

fn linuxTimerfdCreate() u64 {
    for (&timerfd_in_use, 0..) |*used, idx| {
        if (!used.*) {
            used.* = true;
            timerfd_deadlines[idx] = 0;
            timerfd_intervals[idx] = 0;
            const proc = process.getCurrent() orelse return ENOMEM;
            const fd = proc.allocDevFd(.dev_timerfd) orelse return ENOMEM;
            if (proc.getFdEntryPtr(fd)) |entry| {
                entry.read_offset = @truncate(idx);
            }
            return fd;
        }
    }
    return ENOMEM;
}

fn linuxTimerfdSettime(fd: u64, _: u64, new_value_ptr: u64, old_value_ptr: u64) u64 {
    const proc = process.getCurrent() orelse return EBADF;
    const entry = proc.getFdEntry(@truncate(fd)) orelse return EBADF;
    if (entry.fd_type != .dev_timerfd) return EBADF;
    const idx = entry.read_offset;
    if (idx >= MAX_TIMERFDS) return EBADF;

    if (old_value_ptr != 0 and old_value_ptr < 0x0000_8000_0000_0000) {
        const dest: [*]u8 = @ptrFromInt(old_value_ptr);
        @memset(dest[0..32], 0); // struct itimerspec = 32 bytes
    }

    if (new_value_ptr != 0 and new_value_ptr < 0x0000_8000_0000_0000) {
        // struct itimerspec { struct timespec it_interval, it_value }
        // it_interval at offset 0 (16 bytes), it_value at offset 16 (16 bytes)
        const src: [*]const u8 = @ptrFromInt(new_value_ptr);
        const interval_sec = readU64(src[0..8]);
        const interval_nsec = readU64(src[8..16]);
        const value_sec = readU64(src[16..24]);
        const value_nsec = readU64(src[24..32]);

        const t = getUptimeAndTps();
        const value_ticks = value_sec * t.tps + (value_nsec * t.tps) / 1_000_000_000;
        timerfd_deadlines[idx] = if (value_ticks > 0) t.ticks + value_ticks else 0;
        timerfd_intervals[idx] = interval_sec * t.tps + (interval_nsec * t.tps) / 1_000_000_000;
    }
    return 0;
}

fn linuxTimerfdGettime(fd: u64, buf_ptr: u64) u64 {
    const proc = process.getCurrent() orelse return EBADF;
    const entry = proc.getFdEntry(@truncate(fd)) orelse return EBADF;
    if (entry.fd_type != .dev_timerfd) return EBADF;
    const idx = entry.read_offset;
    if (idx >= MAX_TIMERFDS) return EBADF;

    if (buf_ptr == 0 or buf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    @memset(dest[0..32], 0);

    const t = getUptimeAndTps();
    if (timerfd_deadlines[idx] > t.ticks) {
        const remaining = timerfd_deadlines[idx] - t.ticks;
        const secs = remaining / t.tps;
        const nsecs = ((remaining % t.tps) * 1_000_000_000) / t.tps;
        // it_value at offset 16
        writeU64(dest[16..24], secs);
        writeU64(dest[24..32], nsecs);
    }
    return 0;
}

// ── Wave 4: Memory extensions ────────────────────────────────────────────

fn linuxMremap(old_addr: u64, old_size: u64, new_size: u64, _: u64) u64 {
    if (new_size <= old_size) return old_addr; // shrink is noop
    // Allocate new region, copy old data
    const MAP_ANONYMOUS: u64 = 0x20;
    const MAP_PRIVATE: u64 = 0x02;
    const new_addr = syscall.sysMmap(0, new_size, 3, MAP_ANONYMOUS | MAP_PRIVATE); // PROT_READ|PROT_WRITE
    if (isError(new_addr)) return new_addr;
    // Copy old data
    const src: [*]const u8 = @ptrFromInt(old_addr);
    const dst: [*]u8 = @ptrFromInt(new_addr);
    @memcpy(dst[0..old_size], src[0..old_size]);
    return new_addr;
}

fn linuxMincore(_: u64, length: u64, vec_ptr: u64) u64 {
    if (vec_ptr == 0 or vec_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    // All pages are resident — fill vec with 1s
    const pages = (length + 4095) / 4096;
    const n = @min(pages, 4096);
    const dest: [*]u8 = @ptrFromInt(vec_ptr);
    @memset(dest[0..n], 1);
    return 0;
}

fn linuxMemfdCreate() u64 {
    // Create anonymous fd backed by pipe (simplified memfd)
    const proc = process.getCurrent() orelse return ENOMEM;
    const fd = proc.allocDevFd(.dev_null) orelse return ENOMEM;
    return fd;
}

// ── Wave 5: Process lifecycle ────────────────────────────────────────────

fn linuxWaitid(_: u64, id: u64, infop: u64, options: u64) u64 {
    // Simplify: translate to wait4
    var flags: u64 = 0;
    if (options & 1 != 0) flags |= 1; // WNOHANG
    const pid = if (id == 0) @as(u64, 0) else id; // P_ALL → 0
    const result = syscall.sysWait(pid, flags);
    if (isError(result)) return result;

    // Fill siginfo_t at infop if provided (128 bytes)
    if (infop != 0 and infop < 0x0000_8000_0000_0000 and result != 0) {
        const dest: [*]u8 = @ptrFromInt(infop);
        @memset(dest[0..128], 0);
        // si_signo = SIGCHLD (17)
        writeU32(dest[0..4], 17);
        // si_pid at offset 16
        writeU32(dest[16..20], @truncate(result >> 32));
        // si_status at offset 24
        writeU32(dest[24..28], @truncate(result));
    }
    return 0;
}

fn linuxClone3(args_ptr: u64, size: u64) u64 {
    if (args_ptr == 0 or args_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (size < 88) return EINVAL;
    // struct clone_args: flags(u64,0), pidfd(u64,8), child_tid(u64,16), parent_tid(u64,24),
    // exit_signal(u64,32), stack(u64,40), stack_size(u64,48), tls(u64,56), ...
    const src: [*]const u8 = @ptrFromInt(args_ptr);
    const flags = readU64(src[0..8]);
    const stack_addr = readU64(src[40..48]);
    const stack_sz = readU64(src[48..56]);
    const tls = readU64(src[56..64]);
    const child_tid = readU64(src[16..24]);
    const parent_tid = readU64(src[24..32]);

    const stack_top = if (stack_addr != 0) stack_addr + stack_sz else 0;
    return syscall.sysClone(stack_top, tls, child_tid, parent_tid, flags);
}

// ── Wave 6: statx ────────────────────────────────────────────────────────

fn linuxStatx(dirfd: u64, path_ptr: u64, _: u64, buf_ptr: u64) u64 {
    // statx: do fstatat then convert. For now fall back — callers use fstatat.
    _ = dirfd;
    _ = path_ptr;
    _ = buf_ptr;
    return ENOSYS;
}

// ── Stat translation ──────────────────────────────────────────────────────

/// Translate Fornax stat (32 bytes at user_buf) to Linux stat (144 bytes)
/// in-place. Called after Fornax stat data has been delivered to user memory.
pub fn translateStatInPlace(user_buf_ptr: u64) void {
    if (user_buf_ptr == 0 or user_buf_ptr >= 0x0000_8000_0000_0000) return;

    // Read Fornax stat (32 bytes) before overwriting
    const src: [*]const u8 = @ptrFromInt(user_buf_ptr);
    const fx_size = readU64(src[0..8]);
    const fx_file_type = readU32(src[8..12]);
    // offset 12: reserved
    const fx_mtime = readU64(src[16..24]);
    const fx_mode = readU32(src[24..28]);
    const fx_uid = readU16(src[28..30]);
    const fx_gid = readU16(src[30..32]);

    // Write Linux stat (144 bytes)
    const dst: [*]u8 = @ptrFromInt(user_buf_ptr);
    @memset(dst[0..144], 0);

    // st_ino at offset 8 (u64)
    writeU64(dst[8..16], 1);
    // st_nlink at offset 16 (u64)
    writeU64(dst[16..24], 1);
    // st_mode at offset 24 (u32)
    var mode: u32 = fx_mode;
    if (fx_file_type == 1) {
        mode |= 0o040000; // S_IFDIR
    } else {
        mode |= 0o100000; // S_IFREG
    }
    writeU32(dst[24..28], mode);
    // st_uid at offset 28 (u32)
    writeU32(dst[28..32], @as(u32, fx_uid));
    // st_gid at offset 32 (u32)
    writeU32(dst[32..36], @as(u32, fx_gid));
    // st_size at offset 48 (i64)
    writeU64(dst[48..56], fx_size);
    // st_blksize at offset 56 (i64)
    writeU64(dst[56..64], 4096);
    // st_blocks at offset 64 (i64)
    writeU64(dst[64..72], (fx_size + 511) / 512);
    // st_atime_sec at offset 72
    writeU64(dst[72..80], fx_mtime);
    // st_mtime_sec at offset 88
    writeU64(dst[88..96], fx_mtime);
    // st_ctime_sec at offset 104
    writeU64(dst[104..112], fx_mtime);
}

// ── Helpers ───────────────────────────────────────────────────────────────

/// Read null-terminated string length from user memory. Returns 0 on error.
fn strlenUser(ptr: u64) u64 {
    if (ptr == 0 or ptr >= 0x0000_8000_0000_0000) return 0;
    const s: [*]const u8 = @ptrFromInt(ptr);
    var i: u64 = 0;
    while (i < 256) : (i += 1) {
        if (s[i] == 0) return i;
    }
    return 256; // max path length
}

/// Check if a u64 return value is a Fornax/Linux error (negative when cast to i64).
fn isError(val: u64) bool {
    const signed: i64 = @bitCast(val);
    return signed < 0;
}

fn readU16(buf: *const [2]u8) u16 {
    return @as(u16, buf[0]) | (@as(u16, buf[1]) << 8);
}

fn readU32(buf: *const [4]u8) u32 {
    return @as(u32, buf[0]) |
        (@as(u32, buf[1]) << 8) |
        (@as(u32, buf[2]) << 16) |
        (@as(u32, buf[3]) << 24);
}

fn readU64(buf: *const [8]u8) u64 {
    return @as(u64, buf[0]) |
        (@as(u64, buf[1]) << 8) |
        (@as(u64, buf[2]) << 16) |
        (@as(u64, buf[3]) << 24) |
        (@as(u64, buf[4]) << 32) |
        (@as(u64, buf[5]) << 40) |
        (@as(u64, buf[6]) << 48) |
        (@as(u64, buf[7]) << 56);
}

fn writeU32(buf: *[4]u8, val: u32) void {
    buf[0] = @truncate(val);
    buf[1] = @truncate(val >> 8);
    buf[2] = @truncate(val >> 16);
    buf[3] = @truncate(val >> 24);
}

fn writeU64(buf: *[8]u8, val: u64) void {
    buf[0] = @truncate(val);
    buf[1] = @truncate(val >> 8);
    buf[2] = @truncate(val >> 16);
    buf[3] = @truncate(val >> 24);
    buf[4] = @truncate(val >> 32);
    buf[5] = @truncate(val >> 40);
    buf[6] = @truncate(val >> 48);
    buf[7] = @truncate(val >> 56);
}
