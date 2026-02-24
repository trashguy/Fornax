/// Virtual file handlers for /dev/*, /proc/*, and /cntr/* paths.
///
/// These functions generate text content for kernel-intercepted virtual files
/// and handle ctl writes. Extracted from syscall.zig to separate content
/// generation from syscall dispatch.
const process = @import("process.zig");
const klog = @import("klog.zig");
const pmm = @import("pmm.zig");
const timer = @import("timer.zig");

/// Error return values (same as syscall.zig).
const EBADF: u64 = @bitCast(@as(i64, -9));
const ENOENT: u64 = @bitCast(@as(i64, -2));
const EINVAL: u64 = @bitCast(@as(i64, -22));

// ---------- Formatting helpers ----------

fn fmtDecimal(val: u64, buf: *[20]u8) []const u8 {
    if (val == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var n = val;
    var i: usize = 0;
    while (n > 0) : (i += 1) {
        buf[i] = @intCast(n % 10 + '0');
        n /= 10;
    }
    var lo: usize = 0;
    var hi = i - 1;
    while (lo < hi) {
        const tmp = buf[lo];
        buf[lo] = buf[hi];
        buf[hi] = tmp;
        lo += 1;
        hi -= 1;
    }
    return buf[0..i];
}

pub fn parseDecimal(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var result: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        const old = result;
        result = result *% 10 +% (c - '0');
        if (result < old) return null;
    }
    return result;
}

/// Append a "key value\n" line to buf, return new position.
fn appendKV(buf: []u8, pos: usize, key: []const u8, val: u64) usize {
    var p = pos;
    if (p + key.len >= buf.len) return p;
    @memcpy(buf[p..][0..key.len], key);
    p += key.len;
    if (p >= buf.len) return p;
    buf[p] = ' ';
    p += 1;
    var dec_buf: [20]u8 = undefined;
    const dec = fmtDecimal(val, &dec_buf);
    if (p + dec.len >= buf.len) return p;
    @memcpy(buf[p..][0..dec.len], dec);
    p += dec.len;
    if (p >= buf.len) return p;
    buf[p] = '\n';
    p += 1;
    return p;
}

fn appendStr(buf: []u8, pos: usize, s: []const u8) usize {
    var p = pos;
    for (s) |c| {
        if (p >= buf.len) break;
        buf[p] = c;
        p += 1;
    }
    return p;
}

/// Format a decimal number into buffer, return bytes written.
fn appendDec(buf: []u8, val: anytype) usize {
    var v: u64 = @intCast(val);
    if (v == 0) {
        if (buf.len > 0) {
            buf[0] = '0';
            return 1;
        }
        return 0;
    }
    var tmp: [20]u8 = undefined;
    var i: usize = 0;
    while (v > 0) : (i += 1) {
        tmp[i] = @intCast('0' + v % 10);
        v /= 10;
    }
    if (i > buf.len) return 0;
    for (0..i) |j| {
        buf[j] = tmp[i - 1 - j];
    }
    return i;
}

/// Format a u16 as exactly 4 hex digits into buf[0..4].
fn fmtHex4(buf: *[4]u8, val: u16) void {
    const hex = "0123456789abcdef";
    buf[0] = hex[@as(u4, @truncate(val >> 12))];
    buf[1] = hex[@as(u4, @truncate(val >> 8))];
    buf[2] = hex[@as(u4, @truncate(val >> 4))];
    buf[3] = hex[@as(u4, @truncate(val))];
}

/// Format a u8 as exactly 2 hex digits into buf[0..2].
fn fmtHex2(buf: *[2]u8, val: u8) void {
    const hex = "0123456789abcdef";
    buf[0] = hex[@as(u4, @truncate(val >> 4))];
    buf[1] = hex[@as(u4, @truncate(val))];
}

// ---------- State ----------

const ProcDirEntry = extern struct {
    name: [64]u8,
    file_type: u32,
    size: u32,
};

var proc_dir_buf: [65 * @sizeOf(ProcDirEntry)]u8 linksection(".bss") = undefined;

var dev_random_state: u64 = 0x853c49e6748fea9b; // xorshift64 seed

pub var sysname_buf: [64]u8 = [_]u8{ 'f', 'o', 'r', 'n', 'a', 'x' } ++ [_]u8{0} ** 58;
pub var sysname_len: usize = 6;

// ---------- /proc read ----------

pub fn procRead(entry_ptr: *process.FdEntry, buf_ptr: u64, count: u64) u64 {
    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    const max_bytes: usize = @intCast(@min(count, 4096));

    switch (entry_ptr.proc_kind) {
        .dir => {
            // List active PIDs + meminfo as ProcDirEntry structs
            const procs = process.getProcessTable();
            var pos: usize = 0;

            for (procs) |*p| {
                if (p.state == .free or p.state == .dead) continue;
                if (pos + @sizeOf(ProcDirEntry) > proc_dir_buf.len) break;

                var de: ProcDirEntry = .{ .name = [_]u8{0} ** 64, .file_type = 1, .size = 0 };
                var dec_buf: [20]u8 = undefined;
                const pid_str = fmtDecimal(p.pid, &dec_buf);
                @memcpy(de.name[0..pid_str.len], pid_str);

                const de_bytes: *const [@sizeOf(ProcDirEntry)]u8 = @ptrCast(&de);
                @memcpy(proc_dir_buf[pos..][0..@sizeOf(ProcDirEntry)], de_bytes);
                pos += @sizeOf(ProcDirEntry);
            }

            // Add "meminfo" entry
            if (pos + @sizeOf(ProcDirEntry) <= proc_dir_buf.len) {
                var de_mi: ProcDirEntry = .{ .name = [_]u8{0} ** 64, .file_type = 0, .size = 0 };
                @memcpy(de_mi.name[0..7], "meminfo");
                const mi_bytes: *const [@sizeOf(ProcDirEntry)]u8 = @ptrCast(&de_mi);
                @memcpy(proc_dir_buf[pos..][0..@sizeOf(ProcDirEntry)], mi_bytes);
                pos += @sizeOf(ProcDirEntry);
            }

            // Add "supervisor" entry (directory)
            if (pos + @sizeOf(ProcDirEntry) <= proc_dir_buf.len) {
                var de_sv: ProcDirEntry = .{ .name = [_]u8{0} ** 64, .file_type = 1, .size = 0 };
                @memcpy(de_sv.name[0..10], "supervisor");
                const sv_bytes: *const [@sizeOf(ProcDirEntry)]u8 = @ptrCast(&de_sv);
                @memcpy(proc_dir_buf[pos..][0..@sizeOf(ProcDirEntry)], sv_bytes);
                pos += @sizeOf(ProcDirEntry);
            }

            // Apply read offset
            const offset: usize = entry_ptr.read_offset;
            if (offset >= pos) return 0;
            const available = pos - offset;
            const to_copy = @min(available, max_bytes);
            @memcpy(dest[0..to_copy], proc_dir_buf[offset..][0..to_copy]);
            entry_ptr.read_offset += @intCast(to_copy);
            return to_copy;
        },
        .pid_dir => {
            // List "status" and "ctl" as ProcDirEntry structs
            var tmp_buf: [2 * @sizeOf(ProcDirEntry)]u8 = undefined;
            var pos: usize = 0;

            // "status" entry
            var de_status: ProcDirEntry = .{ .name = [_]u8{0} ** 64, .file_type = 0, .size = 0 };
            @memcpy(de_status.name[0..6], "status");
            const s_bytes: *const [@sizeOf(ProcDirEntry)]u8 = @ptrCast(&de_status);
            @memcpy(tmp_buf[pos..][0..@sizeOf(ProcDirEntry)], s_bytes);
            pos += @sizeOf(ProcDirEntry);

            // "ctl" entry
            var de_ctl: ProcDirEntry = .{ .name = [_]u8{0} ** 64, .file_type = 0, .size = 0 };
            @memcpy(de_ctl.name[0..3], "ctl");
            const c_bytes: *const [@sizeOf(ProcDirEntry)]u8 = @ptrCast(&de_ctl);
            @memcpy(tmp_buf[pos..][0..@sizeOf(ProcDirEntry)], c_bytes);
            pos += @sizeOf(ProcDirEntry);

            const offset: usize = entry_ptr.read_offset;
            if (offset >= pos) return 0;
            const available = pos - offset;
            const to_copy = @min(available, max_bytes);
            @memcpy(dest[0..to_copy], tmp_buf[offset..][0..to_copy]);
            entry_ptr.read_offset += @intCast(to_copy);
            return to_copy;
        },
        .status => {
            const target = process.getByPid(entry_ptr.proc_pid) orelse return 0;
            var text_buf: [384]u8 = undefined;
            var pos: usize = 0;

            pos = appendKV(&text_buf, pos, "pid", target.pid);
            pos = appendKV(&text_buf, pos, "ppid", target.parent_pid orelse 0);

            // State as text
            const state_str = switch (target.state) {
                .free => "free",
                .running => "running",
                .ready => "ready",
                .blocked => "blocked",
                .zombie => "zombie",
                .dead => "dead",
            };
            if (pos + 6 + state_str.len + 1 <= text_buf.len) {
                @memcpy(text_buf[pos..][0..6], "state ");
                pos += 6;
                @memcpy(text_buf[pos..][0..state_str.len], state_str);
                pos += state_str.len;
                text_buf[pos] = '\n';
                pos += 1;
            }

            pos = appendKV(&text_buf, pos, "pages", target.pages_used);
            pos = appendKV(&text_buf, pos, "uid", target.uid);
            pos = appendKV(&text_buf, pos, "gid", target.gid);
            pos = appendKV(&text_buf, pos, "core", target.assigned_core);

            // Affinity
            if (target.core_affinity < 0) {
                pos = appendStr(&text_buf, pos, "affinity any\n");
            } else {
                pos = appendKV(&text_buf, pos, "affinity", @intCast(@as(u16, @bitCast(target.core_affinity))));
            }

            // VT
            pos = appendKV(&text_buf, pos, "vt", target.vt);

            // Process name
            {
                var name_len: usize = 0;
                while (name_len < 16 and target.name[name_len] != 0) : (name_len += 1) {}
                if (name_len > 0) {
                    pos = appendStr(&text_buf, pos, "name ");
                    pos = appendStr(&text_buf, pos, target.name[0..name_len]);
                    pos = appendStr(&text_buf, pos, "\n");
                }
            }

            const offset: usize = entry_ptr.read_offset;
            if (offset >= pos) return 0;
            const available = pos - offset;
            const to_copy = @min(available, max_bytes);
            @memcpy(dest[0..to_copy], text_buf[offset..][0..to_copy]);
            entry_ptr.read_offset += @intCast(to_copy);
            return to_copy;
        },
        .ctl => {
            return 0; // ctl is write-only
        },
        .meminfo => {
            var text_buf: [256]u8 = undefined;
            var pos: usize = 0;

            pos = appendKV(&text_buf, pos, "total_pages", pmm.getTotalPages());
            pos = appendKV(&text_buf, pos, "free_pages", pmm.getFreePages());
            pos = appendKV(&text_buf, pos, "page_size", 4096);
            pos = appendKV(&text_buf, pos, "total_bytes", pmm.getTotalPages() * 4096);
            pos = appendKV(&text_buf, pos, "free_bytes", pmm.getFreePages() * 4096);
            pos = appendKV(&text_buf, pos, "used_pages", pmm.getTotalPages() - pmm.getFreePages());

            const offset: usize = entry_ptr.read_offset;
            if (offset >= pos) return 0;
            const available = pos - offset;
            const to_copy = @min(available, max_bytes);
            @memcpy(dest[0..to_copy], text_buf[offset..][0..to_copy]);
            entry_ptr.read_offset += @intCast(to_copy);
            return to_copy;
        },
        .supervisor => {
            return supervisorRead(entry_ptr, dest, max_bytes);
        },
        .supervisor_ctl => {
            return 0; // ctl is write-only
        },
    }
}

// ---------- /proc write ----------

pub fn procWrite(entry: process.FdEntry, buf_ptr: u64, count: u64) u64 {
    if (entry.proc_kind == .supervisor_ctl) {
        return supervisorWrite(buf_ptr, count);
    }
    if (entry.proc_kind != .ctl) return EBADF;

    const buf: [*]const u8 = @ptrFromInt(buf_ptr);
    const len: usize = @intCast(@min(count, 64));

    // Strip trailing whitespace/newline
    var cmd_len = len;
    while (cmd_len > 0 and (buf[cmd_len - 1] == '\n' or buf[cmd_len - 1] == ' ')) {
        cmd_len -= 1;
    }

    // "kill" — terminate the target process
    if (cmd_len == 4 and buf[0] == 'k' and buf[1] == 'i' and buf[2] == 'l' and buf[3] == 'l') {
        const target = process.getByPid(entry.proc_pid) orelse return ENOENT;
        if (target.state == .free or target.state == .dead) return ENOENT;

        target.exit_status = 137; // killed

        // Kill children first
        process.killChildren(target.pid);

        // Wake parent if waiting
        if (target.parent_pid) |ppid| {
            if (process.getByPid(ppid)) |parent| {
                if (parent.state == .blocked) {
                    if (parent.waiting_for_pid) |wait_pid| {
                        if (wait_pid == target.pid or wait_pid == 0) {
                            parent.syscall_ret = target.exit_status;
                            process.markReady(parent);
                            parent.waiting_for_pid = null;
                            target.state = .free;
                            target.parent_pid = null;
                            return len;
                        }
                    }
                }
            }
        }

        target.state = .zombie;
        return len;
    }

    // "stop" — suspend the target process
    if (cmd_len == 4 and buf[0] == 's' and buf[1] == 't' and buf[2] == 'o' and buf[3] == 'p') {
        const target = process.getByPid(entry.proc_pid) orelse return ENOENT;
        if (target.state == .free or target.state == .dead or target.state == .zombie) return ENOENT;
        if (target.state == .running or target.state == .ready) {
            target.state = .blocked;
            target.pending_op = .none;
        }
        return len;
    }

    // "start" — resume a stopped process
    if (cmd_len == 5 and buf[0] == 's' and buf[1] == 't' and buf[2] == 'a' and buf[3] == 'r' and buf[4] == 't') {
        const target = process.getByPid(entry.proc_pid) orelse return ENOENT;
        if (target.state == .blocked and target.pending_op == .none) {
            process.markReady(target);
        }
        return len;
    }

    // "killgrp" — kill all children of the target
    if (cmd_len == 7 and buf[0] == 'k' and buf[1] == 'i' and buf[2] == 'l' and buf[3] == 'l' and
        buf[4] == 'g' and buf[5] == 'r' and buf[6] == 'p')
    {
        _ = process.getByPid(entry.proc_pid) orelse return ENOENT;
        process.killChildren(entry.proc_pid);
        return len;
    }

    // "wired N" or "wired any" — set core affinity
    if (cmd_len >= 7 and buf[0] == 'w' and buf[1] == 'i' and buf[2] == 'r' and
        buf[3] == 'e' and buf[4] == 'd' and buf[5] == ' ')
    {
        const target = process.getByPid(entry.proc_pid) orelse return ENOENT;
        const arg = buf[6..cmd_len];
        if (arg.len == 3 and arg[0] == 'a' and arg[1] == 'n' and arg[2] == 'y') {
            target.core_affinity = -1;
            return len;
        }
        // Parse decimal core number
        var core_num: u16 = 0;
        for (arg) |c| {
            if (c < '0' or c > '9') return EINVAL;
            core_num = core_num * 10 + (c - '0');
        }
        const percpu = @import("percpu.zig");
        if (core_num >= percpu.cores_online) return EINVAL;
        target.core_affinity = @intCast(core_num);
        return len;
    }

    // "close N" — close fd N in target process
    if (cmd_len >= 7 and buf[0] == 'c' and buf[1] == 'l' and buf[2] == 'o' and
        buf[3] == 's' and buf[4] == 'e' and buf[5] == ' ')
    {
        const target = process.getByPid(entry.proc_pid) orelse return ENOENT;
        const arg = buf[6..cmd_len];
        var fd_num: u16 = 0;
        for (arg) |c| {
            if (c < '0' or c > '9') return EINVAL;
            fd_num = fd_num * 10 + (c - '0');
        }
        if (fd_num >= process.MAX_FDS) return EINVAL;
        target.closeFd(@intCast(fd_num));
        return len;
    }

    return EINVAL;
}

// ---------- /dev/* read handlers ----------

pub fn sysnameRead(entry_ptr: *process.FdEntry, buf_ptr: u64, count: u64) u64 {
    var text_buf: [65]u8 = undefined;
    @memcpy(text_buf[0..sysname_len], sysname_buf[0..sysname_len]);
    text_buf[sysname_len] = '\n';
    const total = sysname_len + 1;

    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    const max_bytes: usize = @intCast(@min(count, 4096));
    const offset: usize = entry_ptr.read_offset;
    if (offset >= total) return 0;
    const available = total - offset;
    const to_copy = @min(available, max_bytes);
    @memcpy(dest[0..to_copy], text_buf[offset..][0..to_copy]);
    entry_ptr.read_offset += @intCast(to_copy);
    return to_copy;
}

pub fn osversionRead(entry_ptr: *process.FdEntry, buf_ptr: u64, count: u64) u64 {
    const text = "Fornax 0.1\n";
    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    const max_bytes: usize = @intCast(@min(count, 4096));
    const offset: usize = entry_ptr.read_offset;
    if (offset >= text.len) return 0;
    const available = text.len - offset;
    const to_copy = @min(available, max_bytes);
    @memcpy(dest[0..to_copy], text[offset..][0..to_copy]);
    entry_ptr.read_offset += @intCast(to_copy);
    return to_copy;
}

pub fn timeRead(entry_ptr: *process.FdEntry, buf_ptr: u64, count: u64) u64 {
    const time_mod = @import("time.zig");
    const epoch = time_mod.wallClock();
    const up = time_mod.uptime();

    var text_buf: [48]u8 = undefined;
    var dec1: [20]u8 = undefined;
    var dec2: [20]u8 = undefined;
    const epoch_str = fmtDecimal(epoch, &dec1);
    const up_str = fmtDecimal(up, &dec2);
    var pos: usize = 0;
    @memcpy(text_buf[pos..][0..epoch_str.len], epoch_str);
    pos += epoch_str.len;
    text_buf[pos] = ' ';
    pos += 1;
    @memcpy(text_buf[pos..][0..up_str.len], up_str);
    pos += up_str.len;
    text_buf[pos] = '\n';
    pos += 1;

    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    const max_bytes: usize = @intCast(@min(count, 4096));
    const offset: usize = entry_ptr.read_offset;
    if (offset >= pos) return 0;
    const available = pos - offset;
    const to_copy = @min(available, max_bytes);
    @memcpy(dest[0..to_copy], text_buf[offset..][0..to_copy]);
    entry_ptr.read_offset += @intCast(to_copy);
    return to_copy;
}

pub fn kmesgRead(entry_ptr: *process.FdEntry, buf_ptr: u64, count: u64) u64 {
    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    const max_bytes: usize = @intCast(@min(count, 4096));
    const offset: usize = entry_ptr.read_offset;
    const n = klog.read(dest[0..max_bytes], offset);
    entry_ptr.read_offset += @intCast(n);
    return n;
}

pub fn driversRead(entry_ptr: *process.FdEntry, buf_ptr: u64, count: u64) u64 {
    var text_buf: [512]u8 = undefined;
    var pos: usize = 0;

    // Always present
    pos = appendStr(&text_buf, pos, "console\n");
    pos = appendStr(&text_buf, pos, "keyboard\n");
    pos = appendStr(&text_buf, pos, "timer\n");

    // Check optional subsystems
    if (@import("nvme.zig").isInitialized()) {
        pos = appendStr(&text_buf, pos, "nvme\n");
    }
    if (@import("ahci.zig").isInitialized()) {
        pos = appendStr(&text_buf, pos, "ahci\n");
    }
    if (@import("virtio_blk.zig").isInitialized()) {
        pos = appendStr(&text_buf, pos, "virtio_blk\n");
    }
    const virtio_net = @import("virtio_net.zig");
    if (virtio_net.isInitialized()) {
        pos = appendStr(&text_buf, pos, "virtio_net\n");
    }
    const xhci = @import("xhci.zig");
    if (xhci.isInitialized()) {
        pos = appendStr(&text_buf, pos, "xhci\n");
    }

    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    const max_bytes: usize = @intCast(@min(count, 4096));
    const offset: usize = entry_ptr.read_offset;
    if (offset >= pos) return 0;
    const available = pos - offset;
    const to_copy = @min(available, max_bytes);
    @memcpy(dest[0..to_copy], text_buf[offset..][0..to_copy]);
    entry_ptr.read_offset += @intCast(to_copy);
    return to_copy;
}

pub fn pidRead(entry_ptr: *process.FdEntry, buf_ptr: u64, count: u64) u64 {
    const proc = process.getCurrent() orelse return 0;
    var text_buf: [24]u8 = undefined;
    var dec_buf: [20]u8 = undefined;
    const dec = fmtDecimal(proc.pid, &dec_buf);
    @memcpy(text_buf[0..dec.len], dec);
    text_buf[dec.len] = '\n';
    const total = dec.len + 1;

    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    const max_bytes: usize = @intCast(@min(count, 4096));
    const offset: usize = entry_ptr.read_offset;
    if (offset >= total) return 0;
    const available = total - offset;
    const to_copy = @min(available, max_bytes);
    @memcpy(dest[0..to_copy], text_buf[offset..][0..to_copy]);
    entry_ptr.read_offset += @intCast(to_copy);
    return to_copy;
}

pub fn userRead(entry_ptr: *process.FdEntry, buf_ptr: u64, count: u64) u64 {
    const proc = process.getCurrent() orelse return 0;
    var text_buf: [24]u8 = undefined;
    var dec_buf: [20]u8 = undefined;
    const dec = fmtDecimal(proc.uid, &dec_buf);
    @memcpy(text_buf[0..dec.len], dec);
    text_buf[dec.len] = '\n';
    const total = dec.len + 1;

    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    const max_bytes: usize = @intCast(@min(count, 4096));
    const offset: usize = entry_ptr.read_offset;
    if (offset >= total) return 0;
    const available = total - offset;
    const to_copy = @min(available, max_bytes);
    @memcpy(dest[0..to_copy], text_buf[offset..][0..to_copy]);
    entry_ptr.read_offset += @intCast(to_copy);
    return to_copy;
}

pub fn sysstatRead(entry_ptr: *process.FdEntry, buf_ptr: u64, count: u64) u64 {
    const percpu = @import("percpu.zig");
    var text_buf: [4096]u8 = undefined;
    var pos: usize = 0;

    // One line per online core: "core_id ctx_switches interrupts syscalls idle_ticks"
    var i: u8 = 0;
    while (i < percpu.cores_online) : (i += 1) {
        const pc = &percpu.percpu_array[i];
        var dec_buf: [20]u8 = undefined;

        // core_id
        const id_str = fmtDecimal(i, &dec_buf);
        pos = appendStr(&text_buf, pos, id_str);
        pos = appendStr(&text_buf, pos, " ");

        // ctx_switches
        var dec2: [20]u8 = undefined;
        const cs_str = fmtDecimal(pc.ctx_switches, &dec2);
        pos = appendStr(&text_buf, pos, cs_str);
        pos = appendStr(&text_buf, pos, " ");

        // interrupts
        var dec3: [20]u8 = undefined;
        const int_str = fmtDecimal(pc.interrupts, &dec3);
        pos = appendStr(&text_buf, pos, int_str);
        pos = appendStr(&text_buf, pos, " ");

        // syscalls
        var dec4: [20]u8 = undefined;
        const sys_str = fmtDecimal(pc.syscalls, &dec4);
        pos = appendStr(&text_buf, pos, sys_str);
        pos = appendStr(&text_buf, pos, " ");

        // idle_ticks
        var dec5: [20]u8 = undefined;
        const idle_str = fmtDecimal(pc.idle_ticks, &dec5);
        pos = appendStr(&text_buf, pos, idle_str);
        pos = appendStr(&text_buf, pos, "\n");
    }

    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    const max_bytes: usize = @intCast(@min(count, 4096));
    const offset: usize = entry_ptr.read_offset;
    if (offset >= pos) return 0;
    const available = pos - offset;
    const to_copy = @min(available, max_bytes);
    @memcpy(dest[0..to_copy], text_buf[offset..][0..to_copy]);
    entry_ptr.read_offset += @intCast(to_copy);
    return to_copy;
}

// ---------- /dev/random ----------

pub fn devRandomFill(buf: []u8) void {
    var state = dev_random_state;
    // Seed from timer ticks on first call for some entropy
    if (state == 0x853c49e6748fea9b) {
        state ^= timer.getTicks();
        if (state == 0) state = 0x853c49e6748fea9b;
    }
    var i: usize = 0;
    while (i < buf.len) {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        const bytes = @as([8]u8, @bitCast(state));
        const remaining = buf.len - i;
        const n = @min(remaining, 8);
        @memcpy(buf[i..][0..n], bytes[0..n]);
        i += n;
    }
    dev_random_state = state;
}

// ---------- /dev/pci ----------

/// Read handler for /dev/pci — one text line per PCI device.
/// Format: "BB:SS.F VVVV:DDDD CC:SS:PP\n"
pub fn pciRead(entry_ptr: *process.FdEntry, buf_ptr: u64, count: u64) u64 {
    const pci = switch (@import("builtin").cpu.arch) {
        .x86_64 => @import("arch/x86_64/pci.zig"),
        .riscv64 => @import("arch/riscv64/pci.zig"),
        else => @compileError("unsupported arch"),
    };
    const devs = pci.getDevices();

    // Generate text into static buffer
    // Each line: "BB:SS.F VVVV:DDDD CC:SS:PP\n" = 27 chars max
    // Max 32 devices = 864 bytes
    var text_buf: [1024]u8 = undefined;
    var pos: usize = 0;

    for (devs) |d| {
        if (pos + 27 > text_buf.len) break;
        // BB:SS.F
        fmtHex2(text_buf[pos..][0..2], d.bus);
        pos += 2;
        text_buf[pos] = ':';
        pos += 1;
        fmtHex2(text_buf[pos..][0..2], d.slot);
        pos += 2;
        text_buf[pos] = '.';
        pos += 1;
        text_buf[pos] = '0' + @as(u8, @truncate(d.func & 0x7));
        pos += 1;
        text_buf[pos] = ' ';
        pos += 1;
        // VVVV:DDDD
        fmtHex4(text_buf[pos..][0..4], d.vendor_id);
        pos += 4;
        text_buf[pos] = ':';
        pos += 1;
        fmtHex4(text_buf[pos..][0..4], d.device_id);
        pos += 4;
        text_buf[pos] = ' ';
        pos += 1;
        // CC:SS:PP
        fmtHex2(text_buf[pos..][0..2], d.class_code);
        pos += 2;
        text_buf[pos] = ':';
        pos += 1;
        fmtHex2(text_buf[pos..][0..2], d.subclass);
        pos += 2;
        text_buf[pos] = ':';
        pos += 1;
        fmtHex2(text_buf[pos..][0..2], d.prog_if);
        pos += 2;
        text_buf[pos] = '\n';
        pos += 1;
    }

    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    const max_bytes: usize = @intCast(@min(count, 4096));
    const offset: usize = entry_ptr.read_offset;
    if (offset >= pos) return 0;
    const available = pos - offset;
    const to_copy = @min(available, max_bytes);
    @memcpy(dest[0..to_copy], text_buf[offset..][0..to_copy]);
    entry_ptr.read_offset += @intCast(to_copy);
    return to_copy;
}

// ---------- /dev/cpu ----------

/// Read handler for /dev/cpu — CPU info as key-value text.
pub fn cpuInfoRead(entry_ptr: *process.FdEntry, buf_ptr: u64, count: u64) u64 {
    const builtin = @import("builtin");
    const percpu = @import("percpu.zig");
    var text_buf: [512]u8 = undefined;
    var pos: usize = 0;

    // Architecture
    const arch_str = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .riscv64 => "riscv64",
        .aarch64 => "aarch64",
        else => "unknown",
    };
    pos = appendStr(&text_buf, pos, "arch ");
    pos = appendStr(&text_buf, pos, arch_str);
    pos = appendStr(&text_buf, pos, "\n");

    // Core count
    pos = appendKV(&text_buf, pos, "cores", percpu.cores_online);

    if (builtin.cpu.arch == .x86_64) {
        const cpu = @import("arch/x86_64/cpu.zig");

        // Vendor string (CPUID leaf 0)
        const leaf0 = cpu.cpuid(0, 0);
        var vendor: [12]u8 = undefined;
        @memcpy(vendor[0..4], @as(*const [4]u8, @ptrCast(&leaf0.ebx)));
        @memcpy(vendor[4..8], @as(*const [4]u8, @ptrCast(&leaf0.edx)));
        @memcpy(vendor[8..12], @as(*const [4]u8, @ptrCast(&leaf0.ecx)));
        pos = appendStr(&text_buf, pos, "vendor ");
        pos = appendStr(&text_buf, pos, &vendor);
        pos = appendStr(&text_buf, pos, "\n");

        // Brand string (CPUID leaves 0x80000002-0x80000004)
        const ext_max = cpu.cpuid(0x80000000, 0).eax;
        if (ext_max >= 0x80000004) {
            pos = appendStr(&text_buf, pos, "model ");
            inline for ([_]u32{ 0x80000002, 0x80000003, 0x80000004 }) |leaf| {
                const r = cpu.cpuid(leaf, 0);
                const regs = [4]u32{ r.eax, r.ebx, r.ecx, r.edx };
                for (regs) |reg| {
                    const bytes = @as(*const [4]u8, @ptrCast(&reg));
                    for (bytes) |b| {
                        if (b == 0) break;
                        if (pos < text_buf.len) {
                            text_buf[pos] = b;
                            pos += 1;
                        }
                    }
                }
            }
            pos = appendStr(&text_buf, pos, "\n");
        }

        // Family/model/stepping (CPUID leaf 1)
        const leaf1 = cpu.cpuid(1, 0);
        const stepping = leaf1.eax & 0xF;
        const base_model = (leaf1.eax >> 4) & 0xF;
        const base_family = (leaf1.eax >> 8) & 0xF;
        const ext_model = (leaf1.eax >> 16) & 0xF;
        const ext_family = (leaf1.eax >> 20) & 0xFF;
        const family = if (base_family == 0xF) base_family + ext_family else base_family;
        const model = if (base_family == 0xF or base_family == 0x6) (ext_model << 4) | base_model else base_model;
        pos = appendKV(&text_buf, pos, "family", family);
        pos = appendKV(&text_buf, pos, "model_id", model);
        pos = appendKV(&text_buf, pos, "stepping", stepping);

        // Threads per core (CPUID leaf 1 EBX[23:16]) and topology
        const logical_per_pkg = (leaf1.ebx >> 16) & 0xFF;
        if (logical_per_pkg > 0) {
            pos = appendKV(&text_buf, pos, "threads_per_pkg", logical_per_pkg);
        }
    }

    if (builtin.cpu.arch == .riscv64) {
        const cpu = @import("arch/riscv64/cpu.zig");

        // ISA string (known at compile time from target)
        pos = appendStr(&text_buf, pos, "isa rv64imafdc\n");

        // SBI vendor/arch/implementation IDs
        const mvendorid = cpu.sbiGetMvendorid();
        const marchid = cpu.sbiGetMarchid();
        const mimpid = cpu.sbiGetMimpid();

        pos = appendKV(&text_buf, pos, "mvendorid", mvendorid);
        pos = appendKV(&text_buf, pos, "marchid", marchid);
        pos = appendKV(&text_buf, pos, "mimpid", mimpid);
    }

    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    const max_bytes: usize = @intCast(@min(count, 4096));
    const offset: usize = entry_ptr.read_offset;
    if (offset >= pos) return 0;
    const available = pos - offset;
    const to_copy = @min(available, max_bytes);
    @memcpy(dest[0..to_copy], text_buf[offset..][0..to_copy]);
    entry_ptr.read_offset += @intCast(to_copy);
    return to_copy;
}

// ---------- /dev/usb, /dev/mouse, /dev/ether0 ----------

pub fn usbRead(entry_ptr: *process.FdEntry, buf_ptr: u64, count: u64) u64 {
    const xhci = @import("xhci.zig");
    var text_buf: [2048]u8 = undefined;
    const pos = xhci.formatDeviceInfo(&text_buf);

    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    const max_bytes: usize = @intCast(@min(count, 4096));
    const offset: usize = entry_ptr.read_offset;
    if (offset >= pos) return 0;
    const available = pos - offset;
    const to_copy = @min(available, max_bytes);
    @memcpy(dest[0..to_copy], text_buf[offset..][0..to_copy]);
    entry_ptr.read_offset += @intCast(to_copy);
    return to_copy;
}

pub fn mouseRead(proc: *process.Process, entry_ptr: *process.FdEntry, buf_ptr: u64, count: u64) u64 {
    _ = entry_ptr;
    const xhci = @import("xhci.zig");
    if (!xhci.mouseDataAvailable()) {
        // Block until mouse data available
        xhci.setMouseWaiter(proc);
        proc.pending_op = .console_read;
        proc.ipc_recv_buf_ptr = buf_ptr;
        proc.pending_fd = @intCast(@min(count, 4096));
        proc.state = .blocked;
        process.scheduleNext();
    }
    // Data available — read directly
    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    const max_bytes: usize = @intCast(@min(count, 4096));
    return xhci.mouseRead(dest, max_bytes);
}

pub fn etherRead(proc: *process.Process, fd_num: u64, entry_ptr: *process.FdEntry, buf_ptr: u64, count: u64) u64 {
    const ether_mod = @import("ether.zig");
    const client_idx = entry_ptr.ether_client;

    if (!ether_mod.hasData(client_idx)) {
        // Block until frame available
        ether_mod.setReadWaiter(client_idx, @intCast(proc.pid));
        proc.pending_op = .ether_read;
        proc.ipc_recv_buf_ptr = buf_ptr;
        // Stash fd number in pending_fd, max count in syscall_ret (net_read pattern)
        proc.pending_fd = @intCast(fd_num);
        proc.syscall_ret = @min(count, ether_mod.MAX_FRAME);
        proc.state = .blocked;
        process.scheduleNext();
    }
    // Data available — read directly
    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    const max_bytes: usize = @intCast(@min(count, ether_mod.MAX_FRAME));
    return ether_mod.readFrame(client_idx, dest[0..max_bytes]);
}

// ---------- /dev/sysname write ----------

pub fn sysnameWrite(buf_ptr: u64, count: u64) u64 {
    const src: [*]const u8 = @ptrFromInt(buf_ptr);
    const len: usize = @intCast(@min(count, 63));
    // Strip trailing newline
    var actual_len = len;
    while (actual_len > 0 and (src[actual_len - 1] == '\n' or src[actual_len - 1] == ' ')) {
        actual_len -= 1;
    }
    if (actual_len == 0) return EINVAL;
    @memcpy(sysname_buf[0..actual_len], src[0..actual_len]);
    sysname_len = actual_len;
    return len;
}

// ---------- /cntr read ----------

/// Read from /cntr/ virtual files.
pub fn cntrRead(entry_ptr: *process.FdEntry, buf_ptr: u64, count: u64) u64 {
    const container = @import("container.zig");
    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    const max: usize = @intCast(@min(count, 4096));

    switch (entry_ptr.cntr_kind) {
        .dir => {
            // List active containers as DirEntry structs (72 bytes each)
            const entry_size = 72;
            const all = container.getAll();
            var total: usize = 0;
            var offset: usize = entry_ptr.read_offset;

            for (all) |*ct| {
                if (!ct.active) continue;
                if (total + entry_size > max) break;

                if (offset > 0) {
                    offset -= 1;
                    continue;
                }

                // Build DirEntry: name[64], file_type u32, size u32
                var ent_buf: [entry_size]u8 = @splat(0);
                // Format ID as name
                var dec_buf: [20]u8 = undefined;
                const id_str = fmtDecimal(ct.id, &dec_buf);
                @memcpy(ent_buf[0..id_str.len], id_str);
                // file_type = 1 (directory)
                ent_buf[64] = 1;
                @memcpy(dest[total..][0..entry_size], &ent_buf);
                total += entry_size;
            }
            entry_ptr.read_offset += @intCast(total / entry_size);
            return total;
        },
        .clone => {
            // Allocate a new container on first read
            if (entry_ptr.read_offset > 0) return 0; // Already read

            const ct = container.allocSlot() orelse return 0;
            entry_ptr.read_offset = 1;
            entry_ptr.cntr_id = ct.id;

            // Return decimal ID string
            var dec_buf: [20]u8 = undefined;
            const id_str = fmtDecimal(ct.id, &dec_buf);
            if (id_str.len <= max) {
                @memcpy(dest[0..id_str.len], id_str);
                return id_str.len;
            }
            return 0;
        },
        .status => {
            if (entry_ptr.read_offset > 0) return 0; // One-shot read
            const ct = container.getById(entry_ptr.cntr_id) orelse return 0;

            // Build key-value status text using appendStr/appendKV helpers
            var buf: [512]u8 = undefined;
            var pos: usize = 0;

            // "id N\n"
            pos = appendKV(&buf, pos, "id", ct.id);

            // "name <name>\n"
            pos = appendStr(&buf, pos, "name ");
            pos = appendStr(&buf, pos, ct.name[0..ct.name_len]);
            if (pos < buf.len) {
                buf[pos] = '\n';
                pos += 1;
            }

            // "state <state>\n"
            const state_str = switch (ct.state) {
                .free => "free",
                .created => "created",
                .running => "running",
                .stopped => "stopped",
                .failed => "failed",
            };
            pos = appendStr(&buf, pos, "state ");
            pos = appendStr(&buf, pos, state_str);
            if (pos < buf.len) {
                buf[pos] = '\n';
                pos += 1;
            }

            // "compat <mode>\n"
            pos = appendStr(&buf, pos, "compat ");
            pos = appendStr(&buf, pos, if (ct.compat == .linux) "linux" else "fornax");
            if (pos < buf.len) {
                buf[pos] = '\n';
                pos += 1;
            }

            // "init_pid N|none\n"
            if (ct.init_pid) |pid| {
                pos = appendKV(&buf, pos, "init_pid", pid);
            } else {
                pos = appendStr(&buf, pos, "init_pid none\n");
            }

            // Numeric KV fields
            pos = appendKV(&buf, pos, "procs", ct.process_count);
            pos = appendKV(&buf, pos, "pages", ct.pages_used_total);
            pos = appendKV(&buf, pos, "quota_pages", ct.quotas.max_memory_pages);
            pos = appendKV(&buf, pos, "quota_children", ct.quotas.max_children);

            // "rootfs <path>\n"
            pos = appendStr(&buf, pos, "rootfs ");
            pos = appendStr(&buf, pos, ct.rootfs_path[0..ct.rootfs_path_len]);
            if (pos < buf.len) {
                buf[pos] = '\n';
                pos += 1;
            }

            // "ip <a.b.c.d>\n" (if assigned)
            if (ct.net_ip != 0) {
                pos = appendStr(&buf, pos, "ip ");
                const ip: u64 = ct.net_ip;
                var dec_buf2: [20]u8 = undefined;
                pos = appendStr(&buf, pos, fmtDecimal(ip & 0xFF, &dec_buf2));
                if (pos < buf.len) {
                    buf[pos] = '.';
                    pos += 1;
                }
                pos = appendStr(&buf, pos, fmtDecimal((ip >> 8) & 0xFF, &dec_buf2));
                if (pos < buf.len) {
                    buf[pos] = '.';
                    pos += 1;
                }
                pos = appendStr(&buf, pos, fmtDecimal((ip >> 16) & 0xFF, &dec_buf2));
                if (pos < buf.len) {
                    buf[pos] = '.';
                    pos += 1;
                }
                pos = appendStr(&buf, pos, fmtDecimal((ip >> 24) & 0xFF, &dec_buf2));
                if (pos < buf.len) {
                    buf[pos] = '\n';
                    pos += 1;
                }
            }

            // "cmd <command>\n"
            if (ct.cmd_len > 0) {
                pos = appendStr(&buf, pos, "cmd ");
                pos = appendStr(&buf, pos, ct.cmd[0..ct.cmd_len]);
                if (pos < buf.len) {
                    buf[pos] = '\n';
                    pos += 1;
                }
            }

            const to_copy = @min(pos, max);
            @memcpy(dest[0..to_copy], buf[0..to_copy]);
            entry_ptr.read_offset = 1;
            return to_copy;
        },
        .procs => {
            if (entry_ptr.read_offset > 0) return 0;
            const ct = container.getById(entry_ptr.cntr_id) orelse return 0;

            // List PIDs of processes in this container
            var buf: [512]u8 = undefined;
            var pos: usize = 0;
            const table = process.getProcessTable();
            for (table) |*p| {
                if (p.state != .free and p.container_id == ct.id) {
                    var dec_buf: [20]u8 = undefined;
                    const pid_str = fmtDecimal(p.pid, &dec_buf);
                    pos = appendStr(&buf, pos, pid_str);
                    if (pos < buf.len) {
                        buf[pos] = '\n';
                        pos += 1;
                    }
                    if (pos >= buf.len - 16) break;
                }
            }

            const to_copy = @min(pos, max);
            @memcpy(dest[0..to_copy], buf[0..to_copy]);
            entry_ptr.read_offset = 1;
            return to_copy;
        },
        .ctl => return 0, // write-only
    }
}

// ---------- /cntr write ----------

/// Write to /cntr/N/ctl.
pub fn cntrWrite(entry: process.FdEntry, buf_ptr: u64, count: u64) u64 {
    const container = @import("container.zig");

    // Container processes cannot manage containers
    if (process.getCurrent()) |caller| {
        if (caller.container_id != container.HOST_CONTAINER) return @bitCast(@as(i64, -1));
    }

    if (entry.cntr_kind != .ctl) return EBADF;

    const ct = container.getById(entry.cntr_id) orelse return ENOENT;
    const buf: [*]const u8 = @ptrFromInt(buf_ptr);
    const len: usize = @intCast(@min(count, 256));

    // Strip trailing whitespace
    var cmd_len = len;
    while (cmd_len > 0 and (buf[cmd_len - 1] == '\n' or buf[cmd_len - 1] == ' ')) {
        cmd_len -= 1;
    }
    if (cmd_len == 0) return EINVAL;

    const cmd = buf[0..cmd_len];

    // "stop" — kill all container processes
    if (cmd_len == 4 and cmd[0] == 's' and cmd[1] == 't' and cmd[2] == 'o' and cmd[3] == 'p') {
        container.stop(ct);
        return len;
    }

    // "destroy" — stop + free slot
    if (cmd_len == 7 and cmd[0] == 'd' and cmd[1] == 'e' and cmd[2] == 's' and
        cmd[3] == 't' and cmd[4] == 'r' and cmd[5] == 'o' and cmd[6] == 'y')
    {
        container.destroy(ct);
        return len;
    }

    // "name <name>" — set container name (created state only)
    if (cmd_len > 5 and cmd[0] == 'n' and cmd[1] == 'a' and cmd[2] == 'm' and
        cmd[3] == 'e' and cmd[4] == ' ')
    {
        if (ct.state != .created) return EINVAL;
        const name = cmd[5..];
        if (name.len > container.MAX_NAME) return EINVAL;
        @memcpy(ct.name[0..name.len], name);
        ct.name_len = @intCast(name.len);
        return len;
    }

    // "rootfs <path>" — set rootfs path (created state only)
    if (cmd_len > 7 and cmd[0] == 'r' and cmd[1] == 'o' and cmd[2] == 'o' and
        cmd[3] == 't' and cmd[4] == 'f' and cmd[5] == 's' and cmd[6] == ' ')
    {
        if (ct.state != .created) return EINVAL;
        const path = cmd[7..];
        if (path.len > container.MAX_PATH) return EINVAL;
        @memcpy(ct.rootfs_path[0..path.len], path);
        ct.rootfs_path_len = @intCast(path.len);
        return len;
    }

    // "compat linux" or "compat fornax"
    if (cmd_len >= 12 and cmd[0] == 'c' and cmd[1] == 'o' and cmd[2] == 'm' and
        cmd[3] == 'p' and cmd[4] == 'a' and cmd[5] == 't' and cmd[6] == ' ')
    {
        const arg = cmd[7..];
        if (arg.len == 5 and arg[0] == 'l' and arg[1] == 'i' and arg[2] == 'n' and
            arg[3] == 'u' and arg[4] == 'x')
        {
            ct.compat = .linux;
            return len;
        }
        if (arg.len == 6 and arg[0] == 'f' and arg[1] == 'o' and arg[2] == 'r' and
            arg[3] == 'n' and arg[4] == 'a' and arg[5] == 'x')
        {
            ct.compat = .fornax;
            return len;
        }
        return EINVAL;
    }

    // "cmd <command>"
    if (cmd_len > 4 and cmd[0] == 'c' and cmd[1] == 'm' and cmd[2] == 'd' and cmd[3] == ' ') {
        const command = cmd[4..];
        if (command.len > container.MAX_PATH) return EINVAL;
        @memcpy(ct.cmd[0..command.len], command);
        ct.cmd_len = @intCast(command.len);
        return len;
    }

    // "quota pages N" or "quota children N"
    if (cmd_len > 6 and cmd[0] == 'q' and cmd[1] == 'u' and cmd[2] == 'o' and
        cmd[3] == 't' and cmd[4] == 'a' and cmd[5] == ' ')
    {
        const arg = cmd[6..];
        if (arg.len > 6 and arg[0] == 'p' and arg[1] == 'a' and arg[2] == 'g' and
            arg[3] == 'e' and arg[4] == 's' and arg[5] == ' ')
        {
            const val = parseDecimal(arg[6..]) orelse return EINVAL;
            ct.quotas.max_memory_pages = @intCast(val);
            return len;
        }
        if (arg.len > 9 and arg[0] == 'c' and arg[1] == 'h' and arg[2] == 'i' and
            arg[3] == 'l' and arg[4] == 'd' and arg[5] == 'r' and arg[6] == 'e' and
            arg[7] == 'n' and arg[8] == ' ')
        {
            const val = parseDecimal(arg[9..]) orelse return EINVAL;
            ct.quotas.max_children = @intCast(val);
            return len;
        }
        return EINVAL;
    }

    return EINVAL;
}

pub fn traceRead(entry_ptr: *process.FdEntry, buf_ptr: u64, count: u64) u64 {
    const trace = @import("trace.zig");
    const percpu = @import("percpu.zig");
    const SpinLock = @import("spinlock.zig").SpinLock;

    const text_buf_size = 65536;
    const S = struct {
        var text_buf: [text_buf_size]u8 linksection(".bss") = undefined;
        var text_lock: SpinLock = .{};
    };

    S.text_lock.lock();
    defer S.text_lock.unlock();

    var pos: usize = 0;

    // Format entries from all online cores sequentially
    var core: u8 = 0;
    while (core < percpu.cores_online) : (core += 1) {
        const cnt = trace.getCount(core);
        // Header: "=== Core N (M entries) ===\n"
        pos = appendStr(&S.text_buf, pos, "=== Core ");
        var dec_buf: [20]u8 = undefined;
        pos = appendStr(&S.text_buf, pos, fmtDecimal(core, &dec_buf));
        pos = appendStr(&S.text_buf, pos, " (");
        var dec_buf2: [20]u8 = undefined;
        pos = appendStr(&S.text_buf, pos, fmtDecimal(cnt, &dec_buf2));
        pos = appendStr(&S.text_buf, pos, " entries) ===\n");

        if (pos >= text_buf_size) break;

        // Format this core's entries
        const remaining = text_buf_size - pos;
        const written = trace.formatCoreEntries(core, S.text_buf[pos..][0..remaining]);
        pos += written;
        if (pos >= text_buf_size) break;
    }

    // Standard offset-based delivery
    const dest: [*]u8 = @ptrFromInt(buf_ptr);
    const max_bytes: usize = @intCast(@min(count, 4096));
    const offset: usize = entry_ptr.read_offset;
    if (offset >= pos) return 0;
    const available = pos - offset;
    const to_copy = @min(available, max_bytes);
    @memcpy(dest[0..to_copy], S.text_buf[offset..][0..to_copy]);
    entry_ptr.read_offset += @intCast(to_copy);
    return to_copy;
}

// ---------- /proc/supervisor ----------

const supervisor = @import("supervisor.zig");

/// Read handler for /proc/supervisor — table of supervised services.
fn supervisorRead(entry_ptr: *process.FdEntry, dest: [*]u8, max_bytes: usize) u64 {
    const svcs = supervisor.getServices();
    var text_buf: [2048]u8 = undefined;
    var pos: usize = 0;

    // Header
    pos = appendStr(&text_buf, pos, "NAME        PID  STATE            RESTARTS  BACKOFF  DEPS\n");

    for (svcs) |*s| {
        if (!s.active) continue;

        // Name (left-padded to 12 chars)
        const name = s.name[0..s.name_len];
        pos = appendStr(&text_buf, pos, name);
        if (name.len < 12) {
            var pad: usize = 12 - name.len;
            while (pad > 0 and pos < text_buf.len) : (pad -= 1) {
                text_buf[pos] = ' ';
                pos += 1;
            }
        }

        // PID
        if (s.pid) |pid| {
            var dec_buf: [20]u8 = undefined;
            const pid_str = fmtDecimal(pid, &dec_buf);
            // Right-align in 4 chars
            if (pid_str.len < 4) {
                var p: usize = 4 - pid_str.len;
                while (p > 0 and pos < text_buf.len) : (p -= 1) {
                    text_buf[pos] = ' ';
                    pos += 1;
                }
            }
            pos = appendStr(&text_buf, pos, pid_str);
        } else {
            pos = appendStr(&text_buf, pos, "   -");
        }

        // State
        pos = appendStr(&text_buf, pos, "  ");
        const state_str = switch (s.state) {
            .running => "running         ",
            .stopped => "stopped         ",
            .dead => "dead            ",
            .pending_restart => "pending_restart ",
        };
        pos = appendStr(&text_buf, pos, state_str);

        // Restarts
        {
            var dec_buf: [20]u8 = undefined;
            const r_str = fmtDecimal(s.restart_count, &dec_buf);
            // Right-align in 8 chars
            if (r_str.len < 8) {
                var p: usize = 8 - r_str.len;
                while (p > 0 and pos < text_buf.len) : (p -= 1) {
                    text_buf[pos] = ' ';
                    pos += 1;
                }
            }
            pos = appendStr(&text_buf, pos, r_str);
        }

        // Backoff
        pos = appendStr(&text_buf, pos, "  ");
        {
            var dec_buf: [20]u8 = undefined;
            const b_str = fmtDecimal(s.backoff_ticks, &dec_buf);
            if (b_str.len < 6) {
                var p: usize = 6 - b_str.len;
                while (p > 0 and pos < text_buf.len) : (p -= 1) {
                    text_buf[pos] = ' ';
                    pos += 1;
                }
            }
            pos = appendStr(&text_buf, pos, b_str);
        }

        // Dependencies
        pos = appendStr(&text_buf, pos, "  ");
        if (s.depends_on_len == 0) {
            pos = appendStr(&text_buf, pos, "-");
        } else {
            for (0..s.depends_on_len) |di| {
                if (di > 0) pos = appendStr(&text_buf, pos, ",");
                const dep_idx = s.depends_on[di];
                if (dep_idx < supervisor.MAX_SERVICES) {
                    const dep = &svcs[dep_idx];
                    if (dep.active) {
                        pos = appendStr(&text_buf, pos, dep.name[0..dep.name_len]);
                    } else {
                        pos = appendStr(&text_buf, pos, "?");
                    }
                }
            }
        }

        if (pos < text_buf.len) {
            text_buf[pos] = '\n';
            pos += 1;
        }
    }

    const offset: usize = entry_ptr.read_offset;
    if (offset >= pos) return 0;
    const available = pos - offset;
    const to_copy = @min(available, max_bytes);
    @memcpy(dest[0..to_copy], text_buf[offset..][0..to_copy]);
    entry_ptr.read_offset += @intCast(to_copy);
    return to_copy;
}

/// Write handler for /proc/supervisor/ctl.
/// Commands: "restart <name>", "stop <name>", "start <name>", "reset <name>"
fn supervisorWrite(buf_ptr: u64, count: u64) u64 {
    const buf: [*]const u8 = @ptrFromInt(buf_ptr);
    const len: usize = @intCast(@min(count, 128));

    // Strip trailing whitespace/newline
    var cmd_len = len;
    while (cmd_len > 0 and (buf[cmd_len - 1] == '\n' or buf[cmd_len - 1] == ' ')) {
        cmd_len -= 1;
    }
    if (cmd_len == 0) return EINVAL;

    // Find space separator between command and service name
    var sep: usize = 0;
    while (sep < cmd_len and buf[sep] != ' ') : (sep += 1) {}
    if (sep >= cmd_len) return EINVAL; // no service name

    const cmd = buf[0..sep];
    var name_start = sep + 1;
    while (name_start < cmd_len and buf[name_start] == ' ') : (name_start += 1) {}
    if (name_start >= cmd_len) return EINVAL;
    const name = buf[name_start..cmd_len];

    const svc = supervisor.findByName(name) orelse return ENOENT;

    // "restart"
    if (cmd.len == 7 and cmd[0] == 'r' and cmd[1] == 'e' and cmd[2] == 's' and
        cmd[3] == 't' and cmd[4] == 'a' and cmd[5] == 'r' and cmd[6] == 't')
    {
        klog.info("[supervisor/ctl] Force restart '");
        klog.info(name);
        klog.info("'\n");
        // Kill old process
        if (svc.pid) |pid| {
            if (process.getByPid(pid)) |proc| {
                process.killChildren(proc.pid);
                proc.state = .dead;
            }
        }
        svc.restart_count += 1;
        svc.state = .pending_restart;
        svc.last_restart_tick = 0; // Allow immediate restart
        supervisor.startService(svc);
        return len;
    }

    // "stop"
    if (cmd.len == 4 and cmd[0] == 's' and cmd[1] == 't' and cmd[2] == 'o' and cmd[3] == 'p') {
        klog.info("[supervisor/ctl] Stopping '");
        klog.info(name);
        klog.info("'\n");
        supervisor.stopService(svc);
        return len;
    }

    // "start"
    if (cmd.len == 5 and cmd[0] == 's' and cmd[1] == 't' and cmd[2] == 'a' and
        cmd[3] == 'r' and cmd[4] == 't')
    {
        klog.info("[supervisor/ctl] Starting '");
        klog.info(name);
        klog.info("'\n");
        supervisor.startService(svc);
        return len;
    }

    // "reset"
    if (cmd.len == 5 and cmd[0] == 'r' and cmd[1] == 'e' and cmd[2] == 's' and
        cmd[3] == 'e' and cmd[4] == 't')
    {
        supervisor.resetService(svc);
        return len;
    }

    return EINVAL;
}
