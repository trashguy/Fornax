/// ping — ICMP echo test for Fornax.
///
/// Sends 4 ICMP echo requests to the QEMU gateway (10.0.2.2)
/// and prints the replies.
const fx = @import("fornax");

const out = fx.io.Writer.stdout;

export fn _start() noreturn {
    out.puts("PING 10.0.2.2: 64 data bytes\n");

    // Step 1: Open clone to allocate a connection
    const clone_fd = fx.open("/net/icmp/clone");
    if (clone_fd < 0) {
        out.puts("ping: failed to open /net/icmp/clone\n");
        fx.exit(1);
    }

    // Step 2: Read connection number
    var conn_buf: [16]u8 = undefined;
    const conn_n = fx.read(clone_fd, &conn_buf);
    if (conn_n <= 0) {
        out.puts("ping: failed to read clone\n");
        fx.exit(1);
    }
    _ = fx.close(clone_fd);

    var conn_num_len: usize = @intCast(conn_n);
    if (conn_num_len > 0 and conn_buf[conn_num_len - 1] == '\n') {
        conn_num_len -= 1;
    }
    const conn_num = conn_buf[0..conn_num_len];

    // Step 3: Build ctl path and connect
    var ctl_path = fx.path.PathBuf.from("/net/icmp/");
    _ = ctl_path.appendRaw(conn_num);
    _ = ctl_path.appendRaw("/ctl");

    const ctl_fd = fx.open(ctl_path.slice());
    if (ctl_fd < 0) {
        out.puts("ping: failed to open ctl\n");
        fx.exit(1);
    }

    _ = fx.write(ctl_fd, "connect 10.0.2.2");
    _ = fx.close(ctl_fd);

    // Step 4: Build data path
    var data_path = fx.path.PathBuf.from("/net/icmp/");
    _ = data_path.appendRaw(conn_num);
    _ = data_path.appendRaw("/data");

    const data_fd = fx.open(data_path.slice());
    if (data_fd < 0) {
        out.puts("ping: failed to open data\n");
        fx.exit(1);
    }

    // Step 5: Send 4 pings
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        _ = fx.write(data_fd, "ping");

        var reply_buf: [128]u8 = undefined;
        const n = fx.read(data_fd, &reply_buf);
        if (n > 0) {
            out.puts(reply_buf[0..@intCast(n)]);
        } else {
            out.puts("timeout\n");
        }
    }

    _ = fx.close(data_fd);

    out.puts("ping: done\n");
    fx.exit(0);
}
