/// ping — ICMP echo test for Fornax.
///
/// Sends 4 ICMP echo requests to the QEMU gateway (10.0.2.2)
/// and prints the replies.
const fx = @import("fornax");

export fn _start() noreturn {
    _ = fx.write(1, "PING 10.0.2.2: 64 data bytes\n");

    // Step 1: Open clone to allocate a connection
    const clone_fd = fx.open("/net/icmp/clone");
    if (clone_fd < 0) {
        _ = fx.write(1, "ping: failed to open /net/icmp/clone\n");
        fx.exit(1);
    }

    // Step 2: Read connection number
    var conn_buf: [16]u8 = undefined;
    const conn_n = fx.read(clone_fd, &conn_buf);
    if (conn_n <= 0) {
        _ = fx.write(1, "ping: failed to read clone\n");
        fx.exit(1);
    }
    _ = fx.close(clone_fd);

    var conn_num_len: usize = @intCast(conn_n);
    if (conn_num_len > 0 and conn_buf[conn_num_len - 1] == '\n') {
        conn_num_len -= 1;
    }

    // Step 3: Build ctl path: /net/icmp/N/ctl
    var ctl_path: [32]u8 = undefined;
    var pos: usize = 0;
    pos = copyStr(&ctl_path, pos, "/net/icmp/");
    pos = copyBuf(&ctl_path, pos, conn_buf[0..conn_num_len]);
    pos = copyStr(&ctl_path, pos, "/ctl");

    // Step 4: Open ctl and write connect command
    const ctl_fd = fx.open(ctl_path[0..pos]);
    if (ctl_fd < 0) {
        _ = fx.write(1, "ping: failed to open ctl\n");
        fx.exit(1);
    }

    _ = fx.write(ctl_fd, "connect 10.0.2.2");
    _ = fx.close(ctl_fd);

    // Step 5: Build data path: /net/icmp/N/data
    var data_path: [32]u8 = undefined;
    pos = 0;
    pos = copyStr(&data_path, pos, "/net/icmp/");
    pos = copyBuf(&data_path, pos, conn_buf[0..conn_num_len]);
    pos = copyStr(&data_path, pos, "/data");

    const data_fd = fx.open(data_path[0..pos]);
    if (data_fd < 0) {
        _ = fx.write(1, "ping: failed to open data\n");
        fx.exit(1);
    }

    // Step 6: Send 4 pings
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        // Write to data fd triggers sending echo request
        _ = fx.write(data_fd, "ping");

        // Read reply (blocks until reply or timeout)
        var reply_buf: [128]u8 = undefined;
        const n = fx.read(data_fd, &reply_buf);
        if (n > 0) {
            _ = fx.write(1, reply_buf[0..@intCast(n)]);
        } else {
            _ = fx.write(1, "timeout\n");
        }
    }

    _ = fx.close(data_fd);

    _ = fx.write(1, "ping: done\n");
    fx.exit(0);
}

fn copyStr(buf: []u8, start: usize, s: []const u8) usize {
    var p = start;
    for (s) |c| {
        buf[p] = c;
        p += 1;
    }
    return p;
}

fn copyBuf(buf: []u8, start: usize, s: []const u8) usize {
    var p = start;
    for (s) |c| {
        buf[p] = c;
        p += 1;
    }
    return p;
}
