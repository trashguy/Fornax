/// tcptest — TCP connection test for Fornax.
///
/// Opens a TCP connection to the QEMU host HTTP server (10.0.2.2:80),
/// sends an HTTP GET request, and prints the response.
const fx = @import("fornax");

export fn _start() noreturn {
    _ = fx.write(1, "tcptest: starting TCP test...\n");

    // Step 1: Open clone to allocate a connection
    const clone_fd = fx.open("/net/tcp/clone");
    if (clone_fd < 0) {
        _ = fx.write(1, "tcptest: failed to open /net/tcp/clone\n");
        fx.exit(1);
    }

    // Step 2: Read connection number
    var conn_buf: [16]u8 = undefined;
    const conn_n = fx.read(clone_fd, &conn_buf);
    if (conn_n <= 0) {
        _ = fx.write(1, "tcptest: failed to read clone\n");
        fx.exit(1);
    }
    _ = fx.close(clone_fd);

    // Parse connection number (strip newline)
    var conn_num_len: usize = @intCast(conn_n);
    if (conn_num_len > 0 and conn_buf[conn_num_len - 1] == '\n') {
        conn_num_len -= 1;
    }

    _ = fx.write(1, "tcptest: got connection ");
    _ = fx.write(1, conn_buf[0..conn_num_len]);
    _ = fx.write(1, "\n");

    // Step 3: Build ctl path: /net/tcp/N/ctl
    var ctl_path: [32]u8 = undefined;
    var pos: usize = 0;
    const prefix = "/net/tcp/";
    for (prefix) |c| {
        ctl_path[pos] = c;
        pos += 1;
    }
    for (conn_buf[0..conn_num_len]) |c| {
        ctl_path[pos] = c;
        pos += 1;
    }
    const ctl_suffix = "/ctl";
    for (ctl_suffix) |c| {
        ctl_path[pos] = c;
        pos += 1;
    }

    // Step 4: Open ctl and write connect command
    const ctl_fd = fx.open(ctl_path[0..pos]);
    if (ctl_fd < 0) {
        _ = fx.write(1, "tcptest: failed to open ctl\n");
        fx.exit(1);
    }

    _ = fx.write(1, "tcptest: connecting to 10.0.2.2:80...\n");
    const wr = fx.write(ctl_fd, "connect 10.0.2.2!80\n");
    if (wr == 0) {
        _ = fx.write(1, "tcptest: connect failed\n");
        fx.exit(1);
    }
    _ = fx.close(ctl_fd);

    _ = fx.write(1, "tcptest: connected!\n");

    // Step 5: Open data and send HTTP GET
    var data_path: [32]u8 = undefined;
    pos = 0;
    for (prefix) |c| {
        data_path[pos] = c;
        pos += 1;
    }
    for (conn_buf[0..conn_num_len]) |c| {
        data_path[pos] = c;
        pos += 1;
    }
    const data_suffix = "/data";
    for (data_suffix) |c| {
        data_path[pos] = c;
        pos += 1;
    }

    const data_fd = fx.open(data_path[0..pos]);
    if (data_fd < 0) {
        _ = fx.write(1, "tcptest: failed to open data\n");
        fx.exit(1);
    }

    const http_req = "GET / HTTP/1.0\r\nHost: 10.0.2.2\r\n\r\n";
    _ = fx.write(data_fd, http_req);

    _ = fx.write(1, "tcptest: sent HTTP GET, reading response...\n");

    // Step 6: Read response
    var resp_buf: [2048]u8 = undefined;
    var total: usize = 0;
    while (total < resp_buf.len) {
        const n = fx.read(data_fd, resp_buf[total..]);
        if (n <= 0) break;
        total += @intCast(n);
    }

    if (total > 0) {
        _ = fx.write(1, "tcptest: response:\n");
        // Print first 512 bytes
        const show = @min(total, 512);
        _ = fx.write(1, resp_buf[0..show]);
        _ = fx.write(1, "\n");
    } else {
        _ = fx.write(1, "tcptest: no response received\n");
    }

    // Step 7: Close
    _ = fx.close(data_fd);

    _ = fx.write(1, "tcptest: done\n");
    fx.exit(0);
}
