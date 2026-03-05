const fx = @import("fornax");
const gop = @import("gop.zig");
const bochs = @import("bochs.zig");

const out = fx.io.Writer.stdout;

const SERVER_FD = 3;

const MAX_HANDLES = 16;

const Backend = enum { none, gop_backend, bochs_backend };

var backend: Backend = .none;

const Handle = struct {
    file_idx: u8, // 0 = ctl, 1 = fb0
    active: bool,
};

var handles: [MAX_HANDLES]Handle = [_]Handle{.{ .file_idx = 0, .active = false }} ** MAX_HANDLES;

var msg: fx.IpcMessage linksection(".bss") = undefined;
var reply: fx.IpcMessage linksection(".bss") = undefined;

// --- PCI scanning helpers ---

fn parseHexVar(s: []const u8) ?u64 {
    if (s.len == 0 or s.len > 16) return null;
    var result: u64 = 0;
    for (s) |c| {
        const d = hexDigit(c) orelse return null;
        result = (result << 4) | @as(u64, d);
    }
    return result;
}

fn hexDigit(c: u8) ?u4 {
    if (c >= '0' and c <= '9') return @truncate(c - '0');
    if (c >= 'a' and c <= 'f') return @truncate(c - 'a' + 10);
    if (c >= 'A' and c <= 'F') return @truncate(c - 'A' + 10);
    return null;
}

fn parseDecimal(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var result: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        result = result * 10 + @as(u32, c - '0');
    }
    return result;
}

/// Find a token between delimiters in a bracket group.
/// Returns end index of bracket content.
fn parseBracketTokens(line: []const u8, start: usize, values: []u64) usize {
    var count: usize = 0;
    var pos = start;
    while (pos < line.len and count < values.len) {
        while (pos < line.len and line[pos] == ' ') : (pos += 1) {}
        const tok_start = pos;
        while (pos < line.len and line[pos] != ' ' and line[pos] != ']') : (pos += 1) {}
        if (pos > tok_start) {
            values[count] = parseHexVar(line[tok_start..pos]) orelse 0;
            count += 1;
        }
        if (pos < line.len and line[pos] == ']') break;
    }
    return count;
}

fn indexOf(data: []const u8, start: usize, needle: u8) ?usize {
    var i = start;
    while (i < data.len) : (i += 1) {
        if (data[i] == needle) return i;
    }
    return null;
}

const BochsPciInfo = struct {
    bar0_base: u64,
    bar0_size: u64,
    bar2_base: u64,
};

/// Scan /dev/pci for Bochs VGA (vendor 1234, device 1111).
fn scanForBochsVga() ?BochsPciInfo {
    var buf: [8192]u8 = undefined;
    const pci_fd = fx.open("/dev/pci");
    if (pci_fd < 0) return null;
    const n = fx.read(pci_fd, &buf);
    _ = fx.close(pci_fd);
    if (n <= 0) return null;

    const data = buf[0..@intCast(n)];
    var i: usize = 0;

    while (i < data.len) {
        var eol = i;
        while (eol < data.len and data[eol] != '\n') : (eol += 1) {}
        const line = data[i..eol];
        i = eol + 1;

        // "BB:SS.F VVVV:DDDD CC:SS:PP [sz...] [b...] ..."
        if (line.len < 26) continue;
        if (line[12] != ':') continue;

        // Check vendor:device = 1234:1111
        const vendor = parseHexVar(line[8..12]) orelse continue;
        const device = parseHexVar(line[13..17]) orelse continue;
        if (vendor != 0x1234 or device != 0x1111) continue;

        // Parse BAR sizes bracket
        const sz_open = indexOf(line, 25, '[') orelse continue;
        const sz_close = indexOf(line, sz_open + 1, ']') orelse continue;
        var bar_sizes: [6]u64 = .{ 0, 0, 0, 0, 0, 0 };
        _ = parseBracketTokens(line[sz_open + 1 .. sz_close], 0, &bar_sizes);

        // Parse BAR bases bracket
        var bar_bases: [6]u64 = .{ 0, 0, 0, 0, 0, 0 };
        if (sz_close + 2 < line.len and line[sz_close + 1] == ' ' and line[sz_close + 2] == '[') {
            const b_close = indexOf(line, sz_close + 3, ']') orelse continue;
            _ = parseBracketTokens(line[sz_close + 3 .. b_close], 0, &bar_bases);
        } else continue;

        if (bar_bases[0] != 0 and bar_sizes[0] != 0) {
            return BochsPciInfo{
                .bar0_base = bar_bases[0],
                .bar0_size = bar_sizes[0],
                .bar2_base = bar_bases[2],
            };
        }
    }
    return null;
}

const FbInfo = struct {
    phys: u64,
    width: u32,
    height: u32,
    stride: u32,
    is_bgr: bool,
};

/// Read /dev/fbinfo for GOP framebuffer info.
fn readFbInfo() ?FbInfo {
    var buf: [128]u8 = undefined;
    const fd = fx.open("/dev/fbinfo");
    if (fd < 0) return null;
    const n = fx.read(fd, &buf);
    _ = fx.close(fd);
    if (n <= 0) return null;

    const data = buf[0..@intCast(n)];

    // Format: "<phys_hex> <width> <height> <stride> <bpp> <format>\n"
    // Parse space-separated tokens
    var tokens: [6][]const u8 = undefined;
    var tok_count: usize = 0;
    var pos: usize = 0;
    while (pos < data.len and tok_count < 6) {
        while (pos < data.len and (data[pos] == ' ' or data[pos] == '\n')) : (pos += 1) {}
        const tok_start = pos;
        while (pos < data.len and data[pos] != ' ' and data[pos] != '\n') : (pos += 1) {}
        if (pos > tok_start) {
            tokens[tok_count] = data[tok_start..pos];
            tok_count += 1;
        }
    }

    if (tok_count < 5) return null;

    const phys = parseHexVar(tokens[0]) orelse return null;
    const width = parseDecimal(tokens[1]) orelse return null;
    const height = parseDecimal(tokens[2]) orelse return null;
    const stride = parseDecimal(tokens[3]) orelse return null;
    const is_bgr = tok_count >= 6 and tokens[5].len >= 3 and tokens[5][0] == 'b' and tokens[5][1] == 'g' and tokens[5][2] == 'r';

    if (width == 0 or height == 0) return null;

    return FbInfo{
        .phys = phys,
        .width = width,
        .height = height,
        .stride = stride,
        .is_bgr = is_bgr,
    };
}

// --- Handle management ---

fn allocHandle(file_idx: u8) ?u32 {
    for (&handles, 0..) |*h, i| {
        if (!h.active) {
            h.* = .{ .file_idx = file_idx, .active = true };
            return @intCast(i);
        }
    }
    return null;
}

fn freeHandle(id: u32) void {
    if (id < MAX_HANDLES) {
        handles[@intCast(id)].active = false;
    }
}

fn getHandle(id: u32) ?*Handle {
    if (id >= MAX_HANDLES) return null;
    const h = &handles[@intCast(id)];
    if (!h.active) return null;
    return h;
}

// --- IPC helpers ---

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

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

// --- IPC dispatch ---

fn handleOpen(req: *fx.IpcMessage, resp: *fx.IpcMessage) void {
    const path = req.data[0..req.data_len];

    const file_idx: u8 = if (strEql(path, "ctl"))
        0
    else if (strEql(path, "fb0"))
        1
    else {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    const handle = allocHandle(file_idx) orelse {
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

    resp.* = fx.IpcMessage.init(fx.R_OK);

    if (h.file_idx == 0) {
        // ctl: return info string
        const max = @min(count, 4096);
        const n: u32 = switch (backend) {
            .bochs_backend => @intCast(bochs.bochsGetInfo(resp.data[0..max])),
            .gop_backend => @intCast(gop.gopGetInfo(resp.data[0..max])),
            .none => blk: {
                const info = "backend: none\n";
                const len: u32 = @intCast(@min(info.len, max));
                @memcpy(resp.data[0..len], info[0..len]);
                break :blk len;
            },
        };
        // Apply offset (simple text file semantics)
        if (offset >= n) {
            resp.data_len = 0;
        } else {
            const available = n - offset;
            const to_copy: u32 = @intCast(@min(available, max));
            // Shift data down if offset > 0
            if (offset > 0) {
                var i: u32 = 0;
                while (i < to_copy) : (i += 1) {
                    resp.data[i] = resp.data[offset + i];
                }
            }
            resp.data_len = to_copy;
        }
    } else {
        // fb0: read pixels from framebuffer
        const max = @min(count, 16384);
        const n: u32 = switch (backend) {
            .bochs_backend => @intCast(bochs.bochsReadFb(@as(u64, offset), resp.data[0..max])),
            .gop_backend => @intCast(gop.gopReadFb(@as(u64, offset), resp.data[0..max])),
            .none => 0,
        };
        resp.data_len = n;
    }
}

fn handleWrite(req: *fx.IpcMessage, resp: *fx.IpcMessage) void {
    if (req.data_len < 4) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    const handle_id = readU32LE(req.data[0..4]);
    const h = getHandle(handle_id) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    if (h.file_idx == 0) {
        // ctl: parse commands
        const cmd_data = req.data[4..req.data_len];
        handleCtlWrite(cmd_data, resp);
    } else {
        // fb0: write pixel data
        // Data format: [handle:4][offset:4][pixels...]
        if (req.data_len < 8) {
            resp.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        }
        const offset = readU32LE(req.data[4..8]);
        const pixel_data = req.data[8..req.data_len];
        const n: u32 = switch (backend) {
            .bochs_backend => @intCast(bochs.bochsWriteFb(@as(u64, offset), pixel_data)),
            .gop_backend => @intCast(gop.gopWriteFb(@as(u64, offset), pixel_data)),
            .none => 0,
        };
        resp.* = fx.IpcMessage.init(fx.R_OK);
        writeU32LE(resp.data[0..4], n);
        resp.data_len = 4;
    }
}

fn handleCtlWrite(cmd_data: []const u8, resp: *fx.IpcMessage) void {
    // Parse "mode <W> <H>" command
    if (cmd_data.len >= 5 and cmd_data[0] == 'm' and cmd_data[1] == 'o' and cmd_data[2] == 'd' and cmd_data[3] == 'e' and cmd_data[4] == ' ') {
        if (backend != .bochs_backend) {
            resp.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        }
        // Parse "mode <W> <H>"
        var pos: usize = 5;
        while (pos < cmd_data.len and cmd_data[pos] == ' ') : (pos += 1) {}
        const w_start = pos;
        while (pos < cmd_data.len and cmd_data[pos] != ' ' and cmd_data[pos] != '\n') : (pos += 1) {}
        const width = parseDecimal(cmd_data[w_start..pos]) orelse {
            resp.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        };

        while (pos < cmd_data.len and cmd_data[pos] == ' ') : (pos += 1) {}
        const h_start = pos;
        while (pos < cmd_data.len and cmd_data[pos] != ' ' and cmd_data[pos] != '\n') : (pos += 1) {}
        const height = parseDecimal(cmd_data[h_start..pos]) orelse {
            resp.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        };

        if (bochs.bochsSetMode(width, height)) {
            resp.* = fx.IpcMessage.init(fx.R_OK);
            resp.data_len = 0;
        } else {
            resp.* = fx.IpcMessage.init(fx.R_ERROR);
        }
        return;
    }

    // "info" command — same as read on ctl
    if (cmd_data.len >= 4 and cmd_data[0] == 'i' and cmd_data[1] == 'n' and cmd_data[2] == 'f' and cmd_data[3] == 'o') {
        resp.* = fx.IpcMessage.init(fx.R_OK);
        resp.data_len = 0;
        return;
    }

    resp.* = fx.IpcMessage.init(fx.R_ERROR);
}

fn handleClose(req: *fx.IpcMessage, resp: *fx.IpcMessage) void {
    if (req.data_len < 4) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }
    const handle_id = readU32LE(req.data[0..4]);
    freeHandle(handle_id);
    resp.* = fx.IpcMessage.init(fx.R_OK);
    resp.data_len = 0;
}

fn handleStat(req: *fx.IpcMessage, resp: *fx.IpcMessage) void {
    if (req.data_len < 4) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    const handle_id = readU32LE(req.data[0..4]);
    const h = getHandle(handle_id) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    resp.* = fx.IpcMessage.init(fx.R_OK);
    @memset(resp.data[0..64], 0);

    if (h.file_idx == 0) {
        // ctl: small text file
        writeU32LE(resp.data[0..4], 256);
    } else {
        // fb0: size = width * height * 4
        const size: u32 = switch (backend) {
            .bochs_backend => @intCast(@min(bochs.bochsFbSize(), 0xFFFFFFFF)),
            .gop_backend => @intCast(@min(gop.gopFbSize(), 0xFFFFFFFF)),
            .none => 0,
        };
        writeU32LE(resp.data[0..4], size);
    }
    // file_type = 0 (regular file)
    writeU32LE(resp.data[4..8], 0);
    resp.data_len = 64;
}

// --- Entry point ---

export fn _start() noreturn {
    // Autodetect backend
    // 1. Try Bochs VGA
    if (scanForBochsVga()) |pci| {
        if (pci.bar2_base != 0 and bochs.bochsInit(pci.bar0_base, pci.bar0_size, pci.bar2_base)) {
            backend = .bochs_backend;
            out.puts("gpud: bochs VGA detected\n");
        }
    }

    // 2. Fall back to GOP
    if (backend == .none) {
        if (readFbInfo()) |info| {
            if (gop.gopInit(info.phys, info.width, info.height, info.stride, info.is_bgr)) {
                backend = .gop_backend;
                out.puts("gpud: GOP framebuffer detected\n");
            }
        }
    }

    if (backend == .none) {
        out.puts("gpud: no GPU backend available\n");
    }

    // Server loop
    while (true) {
        const rc = fx.ipc_recv(SERVER_FD, &msg);
        if (rc < 0) {
            _ = fx.write(2, "gpud: ipc_recv error\n");
            continue;
        }

        switch (msg.tag) {
            fx.T_OPEN => handleOpen(&msg, &reply),
            fx.T_READ => handleRead(&msg, &reply),
            fx.T_WRITE => handleWrite(&msg, &reply),
            fx.T_CLOSE => handleClose(&msg, &reply),
            fx.T_STAT => handleStat(&msg, &reply),
            else => {
                reply = fx.IpcMessage.init(fx.R_ERROR);
            },
        }

        _ = fx.ipc_reply(SERVER_FD, &reply);
    }
}
