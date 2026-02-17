/// Fornax userspace library — module root.
///
/// Re-exports all submodules for convenient `@import("fornax")` usage.
/// Backward-compatible: all public symbols from the old fornax.zig
/// are available at the top level.

pub const syscall = @import("syscall.zig");
pub const ipc = @import("ipc.zig");
pub const errno = @import("errno.zig");
pub const fmt = @import("fmt.zig");
pub const io = @import("io.zig");
pub const str = @import("str.zig");
pub const path = @import("path.zig");
pub const mem = @import("mem.zig");
pub const crypt = @import("crypt.zig");
pub const passwd = @import("passwd.zig");
pub const shadow = @import("shadow.zig");
pub const group = @import("group.zig");

// Re-export syscall functions at top level for backward compatibility.
pub const SYS = syscall.SYS;
pub const write = syscall.write;
pub const exit = syscall.exit;
pub const wait = syscall.wait;
pub const open = syscall.open;
pub const read = syscall.read;
pub const close = syscall.close;
pub const create = syscall.create;
pub const mkdir = syscall.mkdir;
pub const O_DIR = syscall.O_DIR;
pub const O_APPEND = syscall.O_APPEND;
pub const stat = syscall.stat;
pub const remove = syscall.remove;
pub const brk = syscall.brk;
pub const ipc_recv = syscall.ipc_recv;
pub const ipc_reply = syscall.ipc_reply;
pub const spawn = syscall.spawn;
pub const exec = syscall.exec;
pub const pipe = syscall.pipe;
pub const pread = syscall.pread;
pub const pwrite = syscall.pwrite;
pub const klog = syscall.klog;
pub const SysInfo = syscall.SysInfo;
pub const sysinfo = syscall.sysinfo;
pub const sleep = syscall.sleep;
pub const shutdown = syscall.shutdown;
pub const reboot = syscall.reboot;
pub const seek = syscall.seek;
pub const getpid = syscall.getpid;
pub const setuid = syscall.setuid;
pub const getuid = syscall.getuid;
pub const getgid = syscall.getgid;
pub const rename = syscall.rename;
pub const truncate = syscall.truncate;
pub const wstat = syscall.wstat;
pub const WSTAT_MODE = syscall.WSTAT_MODE;
pub const WSTAT_UID = syscall.WSTAT_UID;
pub const WSTAT_GID = syscall.WSTAT_GID;

// Re-export IPC types at top level.
pub const IpcMessage = ipc.IpcMessage;
pub const DirEntry = ipc.DirEntry;
pub const Stat = ipc.Stat;
pub const FdMapping = ipc.FdMapping;
pub const T_OPEN = ipc.T_OPEN;
pub const T_READ = ipc.T_READ;
pub const T_WRITE = ipc.T_WRITE;
pub const T_CLOSE = ipc.T_CLOSE;
pub const T_STAT = ipc.T_STAT;
pub const T_CTL = ipc.T_CTL;
pub const T_CREATE = ipc.T_CREATE;
pub const T_REMOVE = ipc.T_REMOVE;
pub const R_OK = ipc.R_OK;
pub const R_ERROR = ipc.R_ERROR;
pub const T_RENAME = ipc.T_RENAME;
pub const T_TRUNCATE = ipc.T_TRUNCATE;
pub const T_WSTAT = ipc.T_WSTAT;

// Re-export argv helpers at top level.
pub const ARGV_BASE = syscall.ARGV_BASE;
pub const buildArgvBlock = syscall.buildArgvBlock;
pub const getArgc = syscall.getArgc;
pub const getArgs = syscall.getArgs;
