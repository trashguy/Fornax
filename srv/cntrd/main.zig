/// cntrd — Fornax container management server.
///
/// Serves the /cntr/ virtual filesystem via IPC on fd 3 (server channel).
/// Manages container lifecycle (create, configure, start, stop, destroy)
/// using kernel primitives: process groups (via proc_setup) and spawn_blocked.
///
/// Protocol (same as kernel devfiles/cntr):
///   T_OPEN("cntr")           → R_OK(handle)    — directory
///   T_OPEN("cntr/clone")     → R_OK(handle)    — read returns new container ID
///   T_OPEN("cntr/N/status")  → R_OK(handle)    — read returns key=value text
///   T_OPEN("cntr/N/ctl")     → R_OK(handle)    — write commands
///   T_OPEN("cntr/N/procs")   → R_OK(handle)    — read returns PID list
///   T_READ(handle, off, n)   → R_OK(data)
///   T_WRITE(handle, data)    → R_OK(bytes)      — ctl write
///   T_CLOSE(handle)          → R_OK
const fx = @import("fornax");

const MAX_CONTAINERS = 16;
const MAX_NAME = 64;
const MAX_PATH = 256;
const MAX_HANDLES = 32;
const SERVER_FD = 3;

const ContainerState = enum(u8) {
    free = 0,
    created = 1, // configured but not started
    running = 2, // init process running
    stopped = 3, // init process exited
    failed = 4, // init process crashed
};

const Container = struct {
    active: bool,
    id: u8,
    state: ContainerState,
    group_id: u8, // kernel process group (0xFF = not allocated)
    name: [MAX_NAME]u8,
    name_len: u16,
    rootfs_path: [MAX_PATH]u8,
    rootfs_path_len: u16,
    compat: u8, // 0=fornax, 1=linux
    init_pid: u32, // 0 = none
    netd_pid: u32, // 0 = none
    cmd: [MAX_PATH]u8,
    cmd_len: u16,
    max_pages: u32,
    max_children: u32,
};

const HandleKind = enum(u8) {
    dir, // /cntr/ directory
    clone, // /cntr/clone
    status, // /cntr/N/status
    ctl, // /cntr/N/ctl
    procs, // /cntr/N/procs
};

const Handle = struct {
    active: bool,
    kind: HandleKind,
    cntr_idx: u8, // index into containers[] (for status/ctl/procs)
    read_offset: u32,
};

var containers: [MAX_CONTAINERS]Container linksection(".bss") = undefined;
var handles: [MAX_HANDLES]Handle linksection(".bss") = undefined;
var msg: fx.IpcMessage linksection(".bss") = undefined;
var reply: fx.IpcMessage linksection(".bss") = undefined;
/// Scratch buffer for building text responses.
var scratch: [4096]u8 linksection(".bss") = undefined;

fn initContainers() void {
    for (&containers, 0..) |*c, i| {
        c.active = false;
        c.id = @intCast(i);
        c.state = .free;
        c.group_id = 0xFF;
        c.name_len = 0;
        c.rootfs_path_len = 0;
        c.compat = 0;
        c.init_pid = 0;
        c.netd_pid = 0;
        c.cmd_len = 0;
        c.max_pages = 2048; // 8 MB default
        c.max_children = 8;
    }
    for (&handles) |*h| {
        h.active = false;
    }
}

fn allocHandle(kind: HandleKind, cntr_idx: u8) ?u32 {
    for (1..MAX_HANDLES) |i| {
        if (!handles[i].active) {
            handles[i] = .{ .active = true, .kind = kind, .cntr_idx = cntr_idx, .read_offset = 0 };
            return @intCast(i);
        }
    }
    return null;
}

fn freeHandle(handle: u32) void {
    if (handle > 0 and handle < MAX_HANDLES) {
        handles[handle].active = false;
    }
}

fn getHandle(handle: u32) ?*Handle {
    if (handle == 0 or handle >= MAX_HANDLES) return null;
    if (!handles[handle].active) return null;
    return &handles[handle];
}

fn allocContainer() ?*Container {
    for (&containers) |*c| {
        if (!c.active) {
            c.active = true;
            c.state = .created;
            @memset(&c.name, 0);
            c.name_len = 0;
            @memset(&c.rootfs_path, 0);
            c.rootfs_path_len = 0;
            c.compat = 0;
            c.init_pid = 0;
            c.netd_pid = 0;
            @memset(&c.cmd, 0);
            c.cmd_len = 0;
            c.max_pages = 2048;
            c.max_children = 8;
            // Allocate a kernel process group
            const gid = fx.group_alloc();
            if (gid < 0) {
                c.active = false;
                c.state = .free;
                return null;
            }
            c.group_id = @intCast(@as(u32, @bitCast(gid)));
            // Set default quotas on the group
            _ = fx.group_set_quota(c.group_id, 0, c.max_pages);
            _ = fx.group_set_quota(c.group_id, 2, c.max_children);
            return c;
        }
    }
    return null;
}

// ── Path parsing ────────────────────────────────────────────────────

fn parseCntrPath(path: []const u8) ?struct { kind: HandleKind, cntr_idx: u8 } {
    // Paths arrive stripped of the mount prefix. Expected:
    //   ""          -> dir
    //   "clone"     -> clone
    //   "N/status"  -> status for container N
    //   "N/ctl"     -> ctl for container N
    //   "N/procs"   -> procs for container N
    if (path.len == 0) return .{ .kind = .dir, .cntr_idx = 0 };
    if (strEql(path, "clone")) return .{ .kind = .clone, .cntr_idx = 0 };

    // Parse "N/suffix"
    var slash_pos: ?usize = null;
    for (path, 0..) |c, i| {
        if (c == '/') {
            slash_pos = i;
            break;
        }
    }
    const sp = slash_pos orelse return null;
    const id_str = path[0..sp];
    const suffix = path[sp + 1 ..];

    const id = parseDecimal(id_str) orelse return null;
    if (id >= MAX_CONTAINERS) return null;
    if (!containers[id].active) return null;

    if (strEql(suffix, "status")) return .{ .kind = .status, .cntr_idx = @intCast(id) };
    if (strEql(suffix, "ctl")) return .{ .kind = .ctl, .cntr_idx = @intCast(id) };
    if (strEql(suffix, "procs")) return .{ .kind = .procs, .cntr_idx = @intCast(id) };

    return null;
}

fn parseDecimal(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var val: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        val = val * 10 + (c - '0');
    }
    return val;
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

// ── IPC handlers ────────────────────────────────────────────────────

fn handleOpen(req: *fx.IpcMessage, resp: *fx.IpcMessage) void {
    const path = req.data[0..req.data_len];
    const parsed = parseCntrPath(path) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };
    const handle = allocHandle(parsed.kind, parsed.cntr_idx) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };
    resp.* = fx.IpcMessage.init(fx.R_OK);
    writeU32LE(resp.data[0..4], handle);
    resp.data_len = 4;
}

fn handleRead(req: *fx.IpcMessage, resp: *fx.IpcMessage) void {
    if (req.data_len < 12) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }
    const handle_id = readU32LE(req.data[0..4]);
    const offset = readU32LE(req.data[4..8]);
    const count = readU32LE(req.data[8..12]);
    const h = getHandle(handle_id) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    switch (h.kind) {
        .dir => readDir(offset, count, resp),
        .clone => readClone(h, resp),
        .status => readStatus(h.cntr_idx, offset, count, resp),
        .procs => readProcs(h.cntr_idx, offset, count, resp),
        .ctl => {
            // ctl is write-only
            resp.* = fx.IpcMessage.init(fx.R_OK);
            resp.data_len = 0;
        },
    }
}

fn handleWrite(req: *fx.IpcMessage, resp: *fx.IpcMessage) void {
    if (req.data_len < 4) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }
    const handle_id = readU32LE(req.data[0..4]);
    const data = req.data[4..req.data_len];
    const h = getHandle(handle_id) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    if (h.kind != .ctl) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    writeCtl(h.cntr_idx, data, resp);
}

fn handleClose(req: *fx.IpcMessage, resp: *fx.IpcMessage) void {
    if (req.data_len >= 4) {
        const handle_id = readU32LE(req.data[0..4]);
        freeHandle(handle_id);
    }
    resp.* = fx.IpcMessage.init(fx.R_OK);
    resp.data_len = 0;
}

// ── Read implementations ────────────────────────────────────────────

fn readDir(offset: u32, count: u32, resp: *fx.IpcMessage) void {
    resp.* = fx.IpcMessage.init(fx.R_OK);
    const entry_size = @sizeOf(fx.DirEntry);
    const max_entries = @min(count / entry_size, 4096 / entry_size);
    const skip = offset / entry_size;

    var written: u32 = 0;
    var entries_written: u32 = 0;
    var skipped: u32 = 0;

    // First entry: "clone"
    if (skipped >= skip and entries_written < max_entries) {
        const dest: *fx.DirEntry = @ptrCast(@alignCast(resp.data[written..][0..entry_size]));
        @memset(&dest.name, 0);
        @memcpy(dest.name[0..5], "clone");
        dest.file_type = 0; // file
        dest.size = 0;
        written += entry_size;
        entries_written += 1;
    }
    skipped += 1;

    // Then each active container as a directory entry "N"
    for (&containers) |*c| {
        if (!c.active) continue;
        if (entries_written >= max_entries) break;
        if (skipped < skip) {
            skipped += 1;
            continue;
        }
        const dest: *fx.DirEntry = @ptrCast(@alignCast(resp.data[written..][0..entry_size]));
        @memset(&dest.name, 0);
        var dec_buf: [20]u8 = undefined;
        const id_str = fmtDecimal(c.id, &dec_buf);
        @memcpy(dest.name[0..id_str.len], id_str);
        dest.file_type = 1; // directory
        dest.size = 0;
        written += entry_size;
        entries_written += 1;
        skipped += 1;
    }

    resp.data_len = written;
}

fn readClone(h: *Handle, resp: *fx.IpcMessage) void {
    // Reading /cntr/clone allocates a new container and returns its ID as text
    const ct = allocContainer() orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    resp.* = fx.IpcMessage.init(fx.R_OK);
    var dec_buf: [20]u8 = undefined;
    const id_str = fmtDecimal(ct.id, &dec_buf);
    @memcpy(resp.data[0..id_str.len], id_str);
    resp.data[id_str.len] = '\n';
    resp.data_len = @intCast(id_str.len + 1);

    // Prevent re-allocation on subsequent reads
    h.kind = .dir; // downgrade to harmless
}

fn readStatus(cntr_idx: u8, offset: u32, count: u32, resp: *fx.IpcMessage) void {
    const ct = &containers[cntr_idx];
    resp.* = fx.IpcMessage.init(fx.R_OK);

    // Build status text
    var pos: usize = 0;
    pos = appendKV(&scratch, pos, "id", fmtDecBuf(ct.id));
    pos = appendKV(&scratch, pos, "name", ct.name[0..ct.name_len]);
    pos = appendKV(&scratch, pos, "state", stateName(ct.state));
    pos = appendKV(&scratch, pos, "compat", if (ct.compat == 1) "linux" else "fornax");
    pos = appendKV(&scratch, pos, "init_pid", fmtDecBuf(ct.init_pid));
    pos = appendKV(&scratch, pos, "group_id", fmtDecBuf(ct.group_id));
    pos = appendKV(&scratch, pos, "rootfs", ct.rootfs_path[0..ct.rootfs_path_len]);
    pos = appendKV(&scratch, pos, "quota_pages", fmtDecBuf(ct.max_pages));
    pos = appendKV(&scratch, pos, "quota_children", fmtDecBuf(ct.max_children));
    if (ct.cmd_len > 0) {
        pos = appendKV(&scratch, pos, "cmd", ct.cmd[0..ct.cmd_len]);
    }

    // Apply offset/count
    if (offset >= pos) {
        resp.data_len = 0;
        return;
    }
    const available = pos - offset;
    const to_copy = @min(@min(count, available), 4096);
    @memcpy(resp.data[0..to_copy], scratch[offset..][0..to_copy]);
    resp.data_len = @intCast(to_copy);
}

fn readProcs(cntr_idx: u8, offset: u32, count: u32, resp: *fx.IpcMessage) void {
    const ct = &containers[cntr_idx];
    _ = count;
    resp.* = fx.IpcMessage.init(fx.R_OK);

    // Build PID list by querying /proc for processes with matching group_id.
    // Since we're in userspace, we use sysinfo or iterate /proc.
    // For simplicity, we track init_pid and netd_pid directly.
    var pos: usize = 0;
    if (ct.init_pid != 0) {
        const s = fmtDecBuf(ct.init_pid);
        if (pos + s.len + 1 < scratch.len) {
            @memcpy(scratch[pos..][0..s.len], s);
            pos += s.len;
            scratch[pos] = '\n';
            pos += 1;
        }
    }
    if (ct.netd_pid != 0) {
        const s = fmtDecBuf(ct.netd_pid);
        if (pos + s.len + 1 < scratch.len) {
            @memcpy(scratch[pos..][0..s.len], s);
            pos += s.len;
            scratch[pos] = '\n';
            pos += 1;
        }
    }

    if (offset >= pos) {
        resp.data_len = 0;
        return;
    }
    const available = pos - offset;
    const to_copy = @min(available, 4096);
    @memcpy(resp.data[0..to_copy], scratch[offset..][0..to_copy]);
    resp.data_len = @intCast(to_copy);
}

// ── Ctl write ───────────────────────────────────────────────────────

fn writeCtl(cntr_idx: u8, data: []const u8, resp: *fx.IpcMessage) void {
    const ct = &containers[cntr_idx];

    // Strip trailing newline
    var cmd = data;
    if (cmd.len > 0 and cmd[cmd.len - 1] == '\n') cmd = cmd[0 .. cmd.len - 1];

    if (startsWith(cmd, "name ")) {
        const val = cmd[5..];
        if (val.len > MAX_NAME) {
            resp.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        }
        @memset(&ct.name, 0);
        @memcpy(ct.name[0..val.len], val);
        ct.name_len = @intCast(val.len);
    } else if (startsWith(cmd, "rootfs ")) {
        const val = cmd[7..];
        if (val.len > MAX_PATH) {
            resp.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        }
        @memset(&ct.rootfs_path, 0);
        @memcpy(ct.rootfs_path[0..val.len], val);
        ct.rootfs_path_len = @intCast(val.len);
    } else if (startsWith(cmd, "compat ")) {
        const val = cmd[7..];
        if (strEql(val, "linux")) {
            ct.compat = 1;
        } else if (strEql(val, "fornax")) {
            ct.compat = 0;
        } else {
            resp.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        }
    } else if (startsWith(cmd, "cmd ")) {
        const val = cmd[4..];
        if (val.len > MAX_PATH) {
            resp.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        }
        @memset(&ct.cmd, 0);
        @memcpy(ct.cmd[0..val.len], val);
        ct.cmd_len = @intCast(val.len);
    } else if (startsWith(cmd, "quota pages ")) {
        const val = cmd[12..];
        const n = parseDecimal(val) orelse {
            resp.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        };
        ct.max_pages = n;
        if (ct.group_id != 0xFF) {
            _ = fx.group_set_quota(ct.group_id, 0, n);
        }
    } else if (startsWith(cmd, "quota children ")) {
        const val = cmd[15..];
        const n = parseDecimal(val) orelse {
            resp.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        };
        ct.max_children = n;
        if (ct.group_id != 0xFF) {
            _ = fx.group_set_quota(ct.group_id, 2, n);
        }
    } else if (startsWith(cmd, "started ")) {
        // "started <pid>" — notification from fnx that the container init was started
        const val = cmd[8..];
        const pid = parseDecimal(val) orelse {
            resp.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        };
        ct.init_pid = pid;
        ct.state = .running;
    } else if (startsWith(cmd, "netd ")) {
        // "netd <pid>" — notification from fnx that a container netd was started
        const val = cmd[5..];
        const pid = parseDecimal(val) orelse {
            resp.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        };
        ct.netd_pid = pid;
    } else if (strEql(cmd, "stop")) {
        if (ct.group_id != 0xFF) {
            _ = fx.group_kill(ct.group_id);
        }
        ct.state = .stopped;
        ct.init_pid = 0;
        ct.netd_pid = 0;
    } else if (strEql(cmd, "destroy")) {
        if (ct.group_id != 0xFF) {
            _ = fx.group_kill(ct.group_id);
            _ = fx.group_free(ct.group_id);
        }
        ct.state = .free;
        ct.active = false;
        ct.init_pid = 0;
        ct.netd_pid = 0;
        ct.group_id = 0xFF;
    } else {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    resp.* = fx.IpcMessage.init(fx.R_OK);
    writeU32LE(resp.data[0..4], @intCast(data.len));
    resp.data_len = 4;
}

// ── Helpers ─────────────────────────────────────────────────────────

fn writeU32LE(buf: *[4]u8, val: u32) void {
    buf[0] = @truncate(val);
    buf[1] = @truncate(val >> 8);
    buf[2] = @truncate(val >> 16);
    buf[3] = @truncate(val >> 24);
}

fn readU32LE(buf: *const [4]u8) u32 {
    return @as(u32, buf[0]) |
        (@as(u32, buf[1]) << 8) |
        (@as(u32, buf[2]) << 16) |
        (@as(u32, buf[3]) << 24);
}

fn appendKV(buf: *[4096]u8, pos_in: usize, key: []const u8, val: []const u8) usize {
    var pos = pos_in;
    if (pos + key.len + 1 + val.len + 1 >= buf.len) return pos;
    @memcpy(buf[pos..][0..key.len], key);
    pos += key.len;
    buf[pos] = ' ';
    pos += 1;
    @memcpy(buf[pos..][0..val.len], val);
    pos += val.len;
    buf[pos] = '\n';
    pos += 1;
    return pos;
}

fn appendStr(buf: *[4096]u8, pos_in: usize, s: []const u8) usize {
    var pos = pos_in;
    if (pos + s.len >= buf.len) return pos;
    @memcpy(buf[pos..][0..s.len], s);
    pos += s.len;
    return pos;
}

/// Decimal formatting into a static buffer (returns slice into shared buf).
var dec_buf_shared: [20]u8 = undefined;

fn fmtDecBuf(val: u32) []const u8 {
    return fmtDecimal(val, &dec_buf_shared);
}

fn fmtDecimal(val: u32, buf: *[20]u8) []const u8 {
    if (val == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var v = val;
    var i: usize = 0;
    while (v > 0) : (i += 1) {
        buf[19 - i] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
    return buf[20 - i .. 20];
}

fn stateName(state: ContainerState) []const u8 {
    return switch (state) {
        .free => "free",
        .created => "created",
        .running => "running",
        .stopped => "stopped",
        .failed => "failed",
    };
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    return strEql(s[0..prefix.len], prefix);
}

// ── Entry point ─────────────────────────────────────────────────────

export fn _start() noreturn {
    initContainers();

    while (true) {
        const rc = fx.ipc_recv(SERVER_FD, &msg);
        if (rc < 0) {
            _ = fx.write(2, "cntrd: ipc_recv error\n");
            continue;
        }

        switch (msg.tag) {
            fx.T_OPEN => handleOpen(&msg, &reply),
            fx.T_READ => handleRead(&msg, &reply),
            fx.T_WRITE => handleWrite(&msg, &reply),
            fx.T_CLOSE => handleClose(&msg, &reply),
            else => {
                reply = fx.IpcMessage.init(fx.R_ERROR);
            },
        }

        _ = fx.ipc_reply(SERVER_FD, &reply);
    }
}
