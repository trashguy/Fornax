/// Console file server — first userspace driver in Fornax.
///
/// Runs in Ring 3, listens on fd 3 (server channel set up by supervisor).
/// Receives 9P-style IPC messages and handles:
///   T_WRITE — relay text to stdout (kernel framebuffer path)
///   T_OPEN  — acknowledge open
///   T_READ  — currently returns empty (no input yet)
///   default — reply R_ERROR
const fornax = @import("fornax");

/// Server channel fd (set up by supervisor before process starts).
const SERVER_FD: i32 = 3;

/// Static message buffer (too large for the stack).
var recv_buf: fornax.IpcMessage = undefined;
var reply_buf: fornax.IpcMessage = undefined;

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\call _main
        \\ud2
    );
}

export fn _main() callconv(.c) noreturn {
    _ = fornax.write(1, "[console_server] started\n");

    // IPC receive loop
    while (true) {
        const rc = fornax.ipc_recv(SERVER_FD, &recv_buf);
        if (rc < 0) {
            _ = fornax.write(1, "[console_server] ipc_recv error\n");
            fornax.exit(1);
        }

        switch (recv_buf.tag) {
            fornax.T_WRITE => {
                // Relay the data to stdout (kernel direct framebuffer path)
                if (recv_buf.data_len > 0) {
                    _ = fornax.write(1, recv_buf.data[0..recv_buf.data_len]);
                }
                // Reply R_OK with data_len = bytes written
                reply_buf = fornax.IpcMessage.init(fornax.R_OK);
                reply_buf.data_len = recv_buf.data_len;
                _ = fornax.ipc_reply(SERVER_FD, &reply_buf);
            },
            fornax.T_OPEN => {
                // Acknowledge open
                reply_buf = fornax.IpcMessage.init(fornax.R_OK);
                reply_buf.data_len = 0;
                _ = fornax.ipc_reply(SERVER_FD, &reply_buf);
            },
            fornax.T_READ => {
                // No input support yet — reply with 0 bytes
                reply_buf = fornax.IpcMessage.init(fornax.R_OK);
                reply_buf.data_len = 0;
                _ = fornax.ipc_reply(SERVER_FD, &reply_buf);
            },
            else => {
                // Unknown tag — reply error
                reply_buf = fornax.IpcMessage.init(fornax.R_ERROR);
                reply_buf.data_len = 0;
                _ = fornax.ipc_reply(SERVER_FD, &reply_buf);
            },
        }
    }
}
