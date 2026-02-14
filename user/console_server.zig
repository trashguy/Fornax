/// Console file server — first userspace driver in Fornax.
///
/// Runs in Ring 3, listens on a channel for 9P-style file protocol messages.
/// Has framebuffer memory mapped into its address space by the kernel.
///
/// Handles:
///   T_OPEN  — open /dev/console
///   T_WRITE — render text to framebuffer
///   T_CTL   — control commands ("clear", "color 0xFF0000")
///   T_CLOSE — close handle
///
/// For Milestone 2: this replaces the kernel's direct framebuffer writes.
/// User programs write(fd, ...) → kernel IPC → console server renders.
const fornax = @import("fornax");

/// Console server message tags (matching kernel ipc.Tag values).
const T_OPEN: u32 = 1;
const T_READ: u32 = 2;
const T_WRITE: u32 = 3;
const T_CLOSE: u32 = 4;
const T_STAT: u32 = 5;
const T_CTL: u32 = 6;
const R_OK: u32 = 128;
const R_ERROR: u32 = 129;

/// Message buffer for IPC.
const MSG_BUF_SIZE = 4096;

export fn _start() callconv(.naked) noreturn {
    asm volatile ("call _main");
    unreachable;
}

export fn _main() callconv(.c) noreturn {
    // For Milestone 2:
    // 1. Read from our server channel (fd 3, set up by kernel)
    // 2. Dispatch based on message tag
    // 3. Reply with R_OK or R_ERROR
    //
    // For now, write a simple message to prove we're running
    _ = fornax.write(1, "[console_server] started\n");

    // TODO: IPC loop — recv messages, render to framebuffer
    // This requires the kernel to have IPC blocking/scheduling,
    // which will be fully wired up at Milestone 2.
    //
    // For now, the server starts and exits to prove the process model works.
    fornax.exit(0);
}
