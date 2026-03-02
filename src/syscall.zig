/// Fornax Plan 9-inspired syscall interface.
///
/// This file re-exports the syscall submodules. The implementation lives in
/// src/syscall/ (fs.zig, proc.zig, ipc_handlers.zig, mem.zig, ns.zig, container.zig).
const root = @import("syscall/root.zig");

// --- Public submodules ---
pub const fs = root.fs;
pub const proc = root.proc;
pub const ipc_handlers = root.ipc_handlers;
pub const mem_handlers = root.mem_handlers;
pub const ns = root.ns;
pub const container = root.container;

// --- Public types ---
pub const SYS = root.SYS;
pub const FdMapping = root.FdMapping;

// --- Dispatch ---
pub const dispatch = root.dispatch;

// --- Re-exported handlers (for linux_compat.zig backward compat) ---
pub const sysWrite = root.sysWrite;
pub const sysWritev = root.sysWritev;
pub const sysRead = root.sysRead;
pub const sysOpen = root.sysOpen;
pub const sysCreate = root.sysCreate;
pub const sysClose = root.sysClose;
pub const sysSeek = root.sysSeek;
pub const sysStat = root.sysStat;
pub const sysRemove = root.sysRemove;
pub const sysRename = root.sysRename;
pub const sysTruncate = root.sysTruncate;
pub const sysWstat = root.sysWstat;
pub const sysPipe = root.sysPipe;
pub const sysPread = root.sysPread;
pub const sysPwrite = root.sysPwrite;
pub const sysExit = root.sysExit;
pub const sysThreadExit = root.sysThreadExit;
pub const sysWait = root.sysWait;
pub const sysGetpid = root.sysGetpid;
pub const sysSpawn = root.sysSpawn;
pub const sysExec = root.sysExec;
pub const sysRfork = root.sysRfork;
pub const sysClone = root.sysClone;
pub const sysBrk = root.sysBrk;
pub const sysSetuid = root.sysSetuid;
pub const sysGetuid = root.sysGetuid;
pub const sysIpcRecv = root.sysIpcRecv;
pub const sysIpcReply = root.sysIpcReply;
pub const sysIpcPair = root.sysIpcPair;
pub const sysFutex = root.sysFutex;
pub const sysMmap = root.sysMmap;
pub const sysMunmap = root.sysMunmap;
pub const sysDup = root.sysDup;
pub const sysDup2 = root.sysDup2;
pub const sysArchPrctl = root.sysArchPrctl;
pub const sysMount = root.sysMount;
pub const sysBind = root.sysBind;
pub const sysUnmount = root.sysUnmount;
pub const sysKlog = root.sysKlog;
pub const sysSysinfo = root.sysSysinfo;
pub const sysSleep = root.sysSleep;
pub const sysShutdown = root.sysShutdown;
pub const sysCntrOp = root.sysCntrOp;
