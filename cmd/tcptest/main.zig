/// tcptest — TCP connection test for Fornax.
///
/// Opens a TCP connection to the QEMU host HTTP server (10.0.2.2:80),
/// sends an HTTP GET request, and prints the response.
const fx = @import("fornax");

const out = fx.io.Writer.stdout;

export fn _start() noreturn {
    out.puts("tcptest: starting TCP test...\n");

    // Step 1: Open clone to allocate a connection
    const clone_fd = fx.open("/net/tcp/clone");
    if (clone_fd < 0) {
        out.puts("tcptest: failed to open /net/tcp/clone\n");
        fx.exit(1);
    }

    // Step 2: Read connection number
    var conn_buf: [16]u8 = undefined;
    const conn_n = fx.read(clone_fd, &conn_buf);
    if (conn_n <= 0) {
        out.puts("tcptest: failed to read clone\n");
        fx.exit(1);
    }
    _ = fx.close(clone_fd);

    // Parse connection number (strip newline)
    var conn_num_len: usize = @intCast(conn_n);
    if (conn_num_len > 0 and conn_buf[conn_num_len - 1] == '\n') {
        conn_num_len -= 1;
    }
    const conn_num = conn_buf[0..conn_num_len];

    out.print("tcptest: got connection {s}\n", .{conn_num});

    // Step 3: Open ctl and write connect command
    var ctl_path = fx.path.PathBuf.from("/net/tcp/");
    _ = ctl_path.appendRaw(conn_num);
    _ = ctl_path.appendRaw("/ctl");

    const ctl_fd = fx.open(ctl_path.slice());
    if (ctl_fd < 0) {
        out.puts("tcptest: failed to open ctl\n");
        fx.exit(1);
    }

    out.puts("tcptest: connecting to 10.0.2.2:80...\n");
    const wr = fx.write(ctl_fd, "connect 10.0.2.2!80\n");
    if (wr == 0) {
        out.puts("tcptest: connect failed\n");
        fx.exit(1);
    }
    _ = fx.close(ctl_fd);

    out.puts("tcptest: connected!\n");

    // Step 4: Open data and send HTTP GET
    var data_path = fx.path.PathBuf.from("/net/tcp/");
    _ = data_path.appendRaw(conn_num);
    _ = data_path.appendRaw("/data");

    const data_fd = fx.open(data_path.slice());
    if (data_fd < 0) {
        out.puts("tcptest: failed to open data\n");
        fx.exit(1);
    }

    const http_req = "GET / HTTP/1.0\r\nHost: 10.0.2.2\r\n\r\n";
    _ = fx.write(data_fd, http_req);

    out.puts("tcptest: sent HTTP GET, reading response...\n");

    // Step 5: Read response
    var resp_buf: [2048]u8 = undefined;
    const total = fx.io.readAll(data_fd, &resp_buf);

    if (total > 0) {
        out.puts("tcptest: response:\n");
        const show = @min(total, 512);
        out.puts(resp_buf[0..show]);
        out.putc('\n');
    } else {
        out.puts("tcptest: no response received\n");
    }

    // Step 6: Close
    _ = fx.close(data_fd);

    out.puts("tcptest: done\n");
    fx.exit(0);
}
