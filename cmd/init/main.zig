/// Fornax init — PID 1.
///
/// Spawns login on each virtual terminal (VT 0-3).
/// When a login/shell exits, init respawns login on that VT.
const fx = @import("fornax");

/// 4 MB buffer for loading ELF binaries (matches spawn syscall limit).
/// linksection forces this into .bss so it doesn't bloat the ELF file.
var elf_buf: [4 * 1024 * 1024]u8 linksection(".bss") = undefined;

const out = fx.io.Writer.stdout;

const MAX_VTS = 4;

/// Per-VT tracking
var vt_pids: [MAX_VTS]i32 = .{ -1, -1, -1, -1 };

/// Per-VT respawn failure count (rapid-death throttle)
var vt_fail_count: [MAX_VTS]u8 = .{ 0, 0, 0, 0 };
var vt_last_spawn: [MAX_VTS]u64 = .{ 0, 0, 0, 0 };

/// Read /etc/vts to determine active VT count (1..MAX_VTS, default MAX_VTS).
fn readVtCount() usize {
    const fd = fx.open("/etc/vts");
    if (fd < 0) return MAX_VTS;
    var buf: [8]u8 = undefined;
    const n = fx.read(fd, &buf);
    _ = fx.close(fd);
    if (n <= 0) return MAX_VTS;
    const c = buf[0];
    if (c >= '1' and c <= '0' + MAX_VTS) {
        return c - '0';
    }
    return MAX_VTS;
}

/// Load an ELF from /bin/<name> into elf_buf. Returns the slice, or null on failure.
fn loadBin(name: []const u8) ?[]const u8 {
    out.print("init: opening /bin/{s}\n", .{name});

    var p = fx.path.PathBuf.from("/bin/");
    _ = p.appendRaw(name);

    const fd = fx.open(p.slice());
    out.print("init: open returned {d}\n", .{@as(u64, @bitCast(@as(i64, fd)))});
    if (fd < 0) return null;

    out.puts("init: reading into elf_buf...\n");
    var total: usize = 0;
    while (total < elf_buf.len) {
        const n = fx.read(fd, elf_buf[total..]);
        if (n <= 0) break;
        total += @intCast(n);
    }
    _ = fx.close(fd);

    out.print("init: read {d} bytes\n", .{@as(u64, total)});

    if (total == 0) return null;
    return elf_buf[0..total];
}

/// Spawn login on a given VT, return pid or -1.
fn spawnLogin(elf_data: []const u8, vt: usize) i32 {
    // Set init's VT so the child inherits it
    var vt_cmd = [_]u8{ 'v', 't', ' ', '0' + @as(u8, @intCast(vt)) };
    _ = fx.write(0, &vt_cmd);

    const pid = fx.spawn(elf_data, &.{}, null);
    if (pid >= 0) {
        out.print("init: login on VT {d}, pid={d}\n", .{ vt, @as(u64, @bitCast(@as(i64, pid))) });
    } else {
        out.print("init: failed to spawn login on VT {d}\n", .{vt});
    }
    return pid;
}

/// Check if a process is still alive via /proc/<pid>/status.
fn isAlive(pid: i32) bool {
    if (pid < 0) return false;
    var path_buf: [32]u8 = undefined;
    var pos: usize = 0;

    // Build "/proc/<pid>/status"
    const prefix = "/proc/";
    @memcpy(path_buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;

    var dec_buf: [10]u8 = undefined;
    const pid_str = fx.fmt.formatDec(&dec_buf, @as(u64, @bitCast(@as(i64, pid))));
    @memcpy(path_buf[pos..][0..pid_str.len], pid_str);
    pos += pid_str.len;

    const suffix = "/status";
    @memcpy(path_buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;

    const fd = fx.open(path_buf[0..pos]);
    if (fd < 0) return false;
    _ = fx.close(fd);
    return true;
}

/// Spawn netd: userspace network server at /net.
/// Spawn bridge: Ethernet bridge server at /bridge (optional, for containers).
fn spawnBridge() void {
    const bridge_elf = loadBin("bridge") orelse return; // not present = skip

    const pair = fx.ipc_pair();
    if (pair.err < 0) return;

    const ether_fd = fx.open("/dev/ether0");
    if (ether_fd < 0) {
        _ = fx.close(pair.server_fd);
        _ = fx.close(pair.client_fd);
        return;
    }

    const mappings = [_]fx.FdMapping{
        .{ .parent_fd = @intCast(pair.server_fd), .child_fd = 3 },
        .{ .parent_fd = @intCast(ether_fd), .child_fd = 4 },
    };
    const pid = fx.spawn(bridge_elf, &mappings, null);
    if (pid < 0) {
        _ = fx.close(pair.server_fd);
        _ = fx.close(pair.client_fd);
        _ = fx.close(ether_fd);
        return;
    }

    const rc = fx.mount(pair.client_fd, "/bridge/", 0);
    if (rc < 0) {
        out.puts("init: failed to mount bridge at /bridge\n");
    } else {
        out.puts("init: bridge mounted at /bridge\n");
    }

    _ = fx.close(pair.server_fd);
    _ = fx.close(pair.client_fd);
    _ = fx.close(ether_fd);
}

fn spawnNetd() void {
    // Create IPC channel pair
    const pair = fx.ipc_pair();
    if (pair.err < 0) {
        out.puts("init: failed to create IPC pair for netd\n");
        return;
    }

    // Open /dev/ether0 for raw frame access
    const ether_fd = fx.open("/dev/ether0");
    if (ether_fd < 0) {
        out.puts("init: /dev/ether0 not available, skipping netd\n");
        _ = fx.close(pair.server_fd);
        _ = fx.close(pair.client_fd);
        return;
    }

    // Load netd binary
    const netd_elf = loadBin("netd") orelse {
        out.puts("init: failed to load /bin/netd, skipping\n");
        _ = fx.close(pair.server_fd);
        _ = fx.close(pair.client_fd);
        _ = fx.close(ether_fd);
        return;
    };

    // Spawn with fd mappings: server_fd→3, ether_fd→4
    const mappings = [_]fx.FdMapping{
        .{ .parent_fd = @intCast(pair.server_fd), .child_fd = 3 },
        .{ .parent_fd = @intCast(ether_fd), .child_fd = 4 },
    };
    const pid = fx.spawn(netd_elf, &mappings, null);
    if (pid < 0) {
        out.puts("init: failed to spawn netd\n");
        _ = fx.close(pair.server_fd);
        _ = fx.close(pair.client_fd);
        _ = fx.close(ether_fd);
        return;
    }

    // Mount client end at /net
    const rc = fx.mount(pair.client_fd, "/net/", 0);
    if (rc < 0) {
        out.puts("init: failed to mount netd at /net\n");
    } else {
        out.puts("init: netd mounted at /net\n");
    }

    // Close init's copies (channel stays alive via child + namespace mount)
    _ = fx.close(pair.server_fd);
    _ = fx.close(pair.client_fd);
    _ = fx.close(ether_fd);
}

/// Spawn crond: cron daemon at /sched.
fn spawnCrond() void {
    const pair = fx.ipc_pair();
    if (pair.err < 0) {
        out.puts("init: failed to create IPC pair for crond\n");
        return;
    }

    const crond_elf = loadBin("crond") orelse {
        out.puts("init: /bin/crond not found, skipping\n");
        _ = fx.close(pair.server_fd);
        _ = fx.close(pair.client_fd);
        return;
    };

    // Spawn with fd mapping: server_fd→3
    const mappings = [_]fx.FdMapping{
        .{ .parent_fd = @intCast(pair.server_fd), .child_fd = 3 },
    };
    const pid = fx.spawn(crond_elf, &mappings, null);
    if (pid < 0) {
        out.puts("init: failed to spawn crond\n");
        _ = fx.close(pair.server_fd);
        _ = fx.close(pair.client_fd);
        return;
    }

    const rc = fx.mount(pair.client_fd, "/sched/", 0);
    if (rc < 0) {
        out.puts("init: failed to mount crond at /sched\n");
    } else {
        out.puts("init: crond mounted at /sched\n");
    }

    _ = fx.close(pair.server_fd);
    _ = fx.close(pair.client_fd);
}

export fn _start() noreturn {
    out.puts("init: started\n");

    // Ensure standard directories exist
    _ = fx.mkdir("/var");
    _ = fx.mkdir("/var/log");
    _ = fx.mkdir("/etc");
    _ = fx.mkdir("/home");

    // Restrict /etc/shadow to root only (mode 0600)
    const shadow_fd = fx.open("/etc/shadow");
    if (shadow_fd >= 0) {
        _ = fx.wstat(shadow_fd, 0o600, 0, 0, fx.WSTAT_MODE);
        _ = fx.close(shadow_fd);
    }

    // Spawn bridge (optional, for container networking)
    spawnBridge();

    // Spawn netd (userspace network server)
    spawnNetd();

    // Spawn crond (cron daemon)
    spawnCrond();

    // Determine how many VTs to use (/etc/vts overrides default)
    const active_vts = readVtCount();
    out.print("init: {d} virtual terminals\n", .{@as(u64, active_vts)});

    // Load login once
    const elf_data = loadBin("login") orelse {
        // Fall back to fsh if login doesn't exist
        const fsh_data = loadBin("fsh") orelse {
            out.puts("init: failed to load /bin/login and /bin/fsh\n");
            fx.exit(1);
        };
        // Spawn fsh directly on each VT (fallback mode)
        for (0..active_vts) |i| {
            var vt_cmd = [_]u8{ 'v', 't', ' ', '0' + @as(u8, @intCast(i)) };
            _ = fx.write(0, &vt_cmd);
            const pid = fx.spawn(fsh_data, &.{}, null);
            if (pid >= 0) vt_pids[i] = pid;
        }
        // Wait loop for fallback
        while (true) {
            _ = fx.wait(0);
        }
    };

    // Spawn login on each active VT
    const now = fx.getUptime();
    for (0..active_vts) |i| {
        vt_pids[i] = spawnLogin(elf_data, i);
        vt_last_spawn[i] = now;
    }

    // Respawn loop: when any child exits, check which VT lost its login
    while (true) {
        _ = fx.wait(0); // blocks until a child exits

        for (0..active_vts) |i| {
            if (vt_pids[i] >= 0 and !isAlive(vt_pids[i])) {
                // Respawn throttle: if process died within 3 seconds, count as failure
                const spawn_now = fx.getUptime();
                if (spawn_now - vt_last_spawn[i] < 3) {
                    vt_fail_count[i] += 1;
                    if (vt_fail_count[i] >= 5) {
                        out.print("init: VT {d} respawn limit reached, disabling\n", .{@as(u64, i)});
                        vt_pids[i] = -1;
                        continue;
                    }
                } else {
                    vt_fail_count[i] = 0;
                }

                out.print("init: respawning login on VT {d}\n", .{i});
                // Need to reload ELF since elf_buf may have been reused
                const new_elf = loadBin("login") orelse continue;
                vt_pids[i] = spawnLogin(new_elf, i);
                vt_last_spawn[i] = spawn_now;
            }
        }
    }
}
