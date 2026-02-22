/// crond — Fornax cron daemon.
///
/// IPC server mounted at /sched/. Reads /etc/crontab, runs scheduled jobs
/// via `fsh -c "command"`. Supports standard 5-field cron, @boot, @every,
/// @hourly, @daily, @weekly, @monthly, @yearly.
///
/// Threads:
///   - main: IPC worker loop (handles T_OPEN/T_READ/T_WRITE/T_CLOSE)
///   - scheduler: checks jobs each second, spawns matching ones, kills timeouts
///   - reaper: waits for child exits, logs results to /var/log/cron
const fx = @import("fornax");
const Mutex = fx.thread.Mutex;

const SERVER_FD = 3;
const MAX_JOBS = 64;
const MAX_HANDLES = 32;
const MAX_LOG_ENTRIES = 128;

/// Default maximum job runtime before kill (seconds). 0 = no limit.
const DEFAULT_TIMEOUT: u32 = 3600; // 1 hour

// ── Schedule types ──────────────────────────────────────────────

const ScheduleKind = enum(u8) {
    cron,
    interval,
    boot,
    hourly,
    daily,
    weekly,
    monthly,
    yearly,
};

const CronField = struct {
    bits: u64 = 0,

    fn matches(self: CronField, val: u8) bool {
        if (self.bits == 0) return true;
        return (self.bits >> @as(u6, @intCast(val))) & 1 != 0;
    }

    fn setBit(self: *CronField, val: u8) void {
        self.bits |= @as(u64, 1) << @as(u6, @intCast(val));
    }
};

const Job = struct {
    active: bool = false,
    kind: ScheduleKind = .cron,
    minute: CronField = .{},
    hour: CronField = .{},
    dom: CronField = .{},
    month: CronField = .{},
    dow: CronField = .{},
    interval_secs: u32 = 0,
    last_run: u64 = 0,
    ran_boot: bool = false,
    command: [256]u8 = undefined,
    command_len: u16 = 0,
    user: [32]u8 = undefined,
    user_len: u8 = 0,
    running_pid: i32 = -1,
    spawn_time: u64 = 0,
    max_runtime: u32 = DEFAULT_TIMEOUT,

    fn cmdSlice(self: *const Job) []const u8 {
        return self.command[0..self.command_len];
    }

    fn userSlice(self: *const Job) []const u8 {
        if (self.user_len == 0) return "root";
        return self.user[0..self.user_len];
    }
};

const LogEntry = struct {
    epoch: u64 = 0,
    job_id: u16 = 0,
    exit_code: u16 = 0,
};

// ── Handle types for IPC ────────────────────────────────────────

const HandleKind = enum(u8) {
    ctl,
    log,
    dir,
};

const Handle = struct {
    active: bool = false,
    kind: HandleKind = .ctl,
    read_done: bool = false,
};

// ── Global state ────────────────────────────────────────────────

var jobs: [MAX_JOBS]Job = [_]Job{.{}} ** MAX_JOBS;
var job_count: u16 = 0;

var handles: [MAX_HANDLES]Handle = [_]Handle{.{}} ** MAX_HANDLES;

var log_entries: [MAX_LOG_ENTRIES]LogEntry = [_]LogEntry{.{}} ** MAX_LOG_ENTRIES;
var log_head: u16 = 0;
var log_count: u16 = 0;

var sched_lock: Mutex = .{};

/// 4 MB buffer for caching the fsh ELF binary (loaded once at startup).
var elf_buf: [4 * 1024 * 1024]u8 linksection(".bss") = undefined;
var fsh_elf_len: usize = 0;

/// Fd for /dev/null (opened at startup, used for job stdin/stdout/stderr).
var null_fd: i32 = -1;

/// Fd for /var/log/cron (append log of job executions).
var log_fd: i32 = -1;

// ── Saved interval state for reload preservation ────────────────

const SavedInterval = struct {
    command_hash: u64 = 0,
    last_run: u64 = 0,
    active: bool = false,
};
var saved_intervals: [MAX_JOBS]SavedInterval = [_]SavedInterval{.{}} ** MAX_JOBS;

// ── Handle management ───────────────────────────────────────────

fn allocHandle(kind: HandleKind) ?u32 {
    for (&handles, 0..) |*h, i| {
        if (!h.active) {
            h.* = .{ .active = true, .kind = kind, .read_done = false };
            return @intCast(i);
        }
    }
    return null;
}

fn freeHandle(idx: u32) void {
    if (idx < MAX_HANDLES) {
        handles[idx].active = false;
    }
}

fn getHandle(idx: u32) ?*Handle {
    if (idx < MAX_HANDLES and handles[idx].active) return &handles[idx];
    return null;
}

// ── IPC message helpers ─────────────────────────────────────────

fn writeU32LE(bytes: *[4]u8, val: u32) void {
    bytes[0] = @truncate(val);
    bytes[1] = @truncate(val >> 8);
    bytes[2] = @truncate(val >> 16);
    bytes[3] = @truncate(val >> 24);
}

fn readU32LE(bytes: *const [4]u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

// ── IPC handlers ────────────────────────────────────────────────

fn handleOpen(msg: *fx.IpcMessage, reply: *fx.IpcMessage) void {
    if (msg.data_len <= 4) {
        reply.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }
    const path_bytes: []const u8 = msg.data[4..msg.data_len];
    const path = if (path_bytes.len > 6 and startsWith(path_bytes, "sched/"))
        path_bytes[6..]
    else
        path_bytes;

    if (eql(path, "ctl")) {
        if (allocHandle(.ctl)) |h| {
            reply.* = fx.IpcMessage.init(fx.R_OK);
            writeU32LE(reply.data[0..4], h);
            reply.data_len = 4;
            return;
        }
    } else if (eql(path, "log")) {
        if (allocHandle(.log)) |h| {
            reply.* = fx.IpcMessage.init(fx.R_OK);
            writeU32LE(reply.data[0..4], h);
            reply.data_len = 4;
            return;
        }
    } else if (path.len == 0 or eql(path, ".")) {
        if (allocHandle(.dir)) |h| {
            reply.* = fx.IpcMessage.init(fx.R_OK);
            writeU32LE(reply.data[0..4], h);
            reply.data_len = 4;
            return;
        }
    }

    reply.* = fx.IpcMessage.init(fx.R_ERROR);
}

fn handleRead(msg: *fx.IpcMessage, reply: *fx.IpcMessage) void {
    if (msg.data_len < 4) {
        reply.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }
    const hidx = readU32LE(msg.data[0..4]);
    const h = getHandle(hidx) orelse {
        reply.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    if (h.read_done) {
        reply.* = fx.IpcMessage.init(fx.R_OK);
        reply.data_len = 4;
        writeU32LE(reply.data[0..4], hidx);
        return;
    }

    switch (h.kind) {
        .ctl => readCtl(hidx, reply),
        .log => readLog(hidx, reply),
        .dir => readDir(hidx, reply),
    }
    h.read_done = true;
}

fn readCtl(hidx: u32, reply: *fx.IpcMessage) void {
    var buf: [4000]u8 = undefined;
    var pos: usize = 0;

    sched_lock.lock();
    defer sched_lock.unlock();

    for (&jobs, 0..) |*j, i| {
        if (!j.active) continue;
        // id
        pos += writeDec(buf[pos..], i);
        if (pos < buf.len) {
            buf[pos] = ' ';
            pos += 1;
        }
        // schedule
        const sched = scheduleStr(j);
        if (pos + sched.len <= buf.len) {
            @memcpy(buf[pos..][0..sched.len], sched);
            pos += sched.len;
        }
        if (pos < buf.len) {
            buf[pos] = ' ';
            pos += 1;
        }
        // user
        const u = j.userSlice();
        if (pos + u.len <= buf.len) {
            @memcpy(buf[pos..][0..u.len], u);
            pos += u.len;
        }
        if (pos < buf.len) {
            buf[pos] = ' ';
            pos += 1;
        }
        // command
        const cmd = j.cmdSlice();
        const clen = @min(cmd.len, buf.len -| pos);
        if (clen > 0) {
            @memcpy(buf[pos..][0..clen], cmd[0..clen]);
            pos += clen;
        }
        if (pos < buf.len) {
            buf[pos] = '\n';
            pos += 1;
        }
    }

    reply.* = fx.IpcMessage.init(fx.R_OK);
    writeU32LE(reply.data[0..4], hidx);
    const data_max = reply.data.len - 4;
    const copy_len = @min(pos, data_max);
    @memcpy(reply.data[4..][0..copy_len], buf[0..copy_len]);
    reply.data_len = @intCast(4 + copy_len);
}

fn readLog(hidx: u32, reply: *fx.IpcMessage) void {
    var buf: [4000]u8 = undefined;
    var pos: usize = 0;

    sched_lock.lock();
    defer sched_lock.unlock();

    var count = log_count;
    if (count > MAX_LOG_ENTRIES) count = MAX_LOG_ENTRIES;
    var start: u16 = 0;
    if (log_count >= MAX_LOG_ENTRIES) {
        start = log_head;
    }

    var i: u16 = 0;
    while (i < count) : (i += 1) {
        const idx = (start + i) % MAX_LOG_ENTRIES;
        const entry = &log_entries[idx];
        pos += writeDec(buf[pos..], entry.epoch);
        if (pos < buf.len) {
            buf[pos] = ' ';
            pos += 1;
        }
        pos += writeDec(buf[pos..], entry.job_id);
        if (pos < buf.len) {
            buf[pos] = ' ';
            pos += 1;
        }
        pos += writeDec(buf[pos..], entry.exit_code);
        if (pos < buf.len) {
            buf[pos] = '\n';
            pos += 1;
        }
    }

    reply.* = fx.IpcMessage.init(fx.R_OK);
    writeU32LE(reply.data[0..4], hidx);
    const data_max = reply.data.len - 4;
    const copy_len = @min(pos, data_max);
    @memcpy(reply.data[4..][0..copy_len], buf[0..copy_len]);
    reply.data_len = @intCast(4 + copy_len);
}

fn readDir(hidx: u32, reply: *fx.IpcMessage) void {
    const listing = "ctl\nlog\n";
    reply.* = fx.IpcMessage.init(fx.R_OK);
    writeU32LE(reply.data[0..4], hidx);
    @memcpy(reply.data[4..][0..listing.len], listing);
    reply.data_len = @intCast(4 + listing.len);
}

fn handleWrite(msg: *fx.IpcMessage, reply: *fx.IpcMessage) void {
    if (msg.data_len <= 4) {
        reply.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }
    const hidx = readU32LE(msg.data[0..4]);
    const h = getHandle(hidx) orelse {
        reply.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    if (h.kind != .ctl) {
        reply.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    const data = msg.data[4..msg.data_len];
    var end = data.len;
    while (end > 0 and (data[end - 1] == '\n' or data[end - 1] == ' ')) {
        end -= 1;
    }
    if (end == 0) {
        reply.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }
    const cmd = data[0..end];

    if (eql(cmd, "reload")) {
        sched_lock.lock();
        reloadCrontab();
        sched_lock.unlock();
        replyOk(reply, hidx);
    } else if (eql(cmd, "flush")) {
        sched_lock.lock();
        for (&jobs) |*j| j.active = false;
        job_count = 0;
        sched_lock.unlock();
        replyOk(reply, hidx);
    } else if (startsWith(cmd, "add ")) {
        sched_lock.lock();
        const ok = addJobFromLine(cmd[4..]);
        sched_lock.unlock();
        if (ok) {
            replyOk(reply, hidx);
        } else {
            reply.* = fx.IpcMessage.init(fx.R_ERROR);
        }
    } else if (startsWith(cmd, "remove ")) {
        const id = parseDec(cmd[7..]) orelse {
            reply.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        };
        sched_lock.lock();
        if (id < MAX_JOBS and jobs[id].active) {
            jobs[id].active = false;
            job_count -|= 1;
            sched_lock.unlock();
            replyOk(reply, hidx);
        } else {
            sched_lock.unlock();
            reply.* = fx.IpcMessage.init(fx.R_ERROR);
        }
    } else {
        reply.* = fx.IpcMessage.init(fx.R_ERROR);
    }
}

fn replyOk(reply: *fx.IpcMessage, hidx: u32) void {
    reply.* = fx.IpcMessage.init(fx.R_OK);
    writeU32LE(reply.data[0..4], hidx);
    reply.data_len = 4;
}

fn handleClose(msg: *fx.IpcMessage, reply: *fx.IpcMessage) void {
    if (msg.data_len >= 4) {
        const hidx = readU32LE(msg.data[0..4]);
        freeHandle(hidx);
    }
    reply.* = fx.IpcMessage.init(fx.R_OK);
    reply.data_len = 0;
}

fn handleStat(msg: *fx.IpcMessage, reply: *fx.IpcMessage) void {
    if (msg.data_len < 4) {
        reply.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }
    const hidx = readU32LE(msg.data[0..4]);
    const h = getHandle(hidx) orelse {
        reply.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    reply.* = fx.IpcMessage.init(fx.R_OK);
    writeU32LE(reply.data[0..4], hidx);
    @memset(reply.data[4..36], 0);
    if (h.kind == .dir) {
        writeU32LE(reply.data[16..20], 0o40755);
    } else {
        writeU32LE(reply.data[16..20], 0o100644);
    }
    reply.data_len = 36;
}

// ── Crontab parser ──────────────────────────────────────────────

var crontab_buf: [8192]u8 linksection(".bss") = undefined;

/// Reload crontab preserving @every last_run times.
fn reloadCrontab() void {
    // Save interval job states before clearing
    var save_count: usize = 0;
    for (&jobs) |*j| {
        if (j.active and j.kind == .interval and save_count < MAX_JOBS) {
            saved_intervals[save_count] = .{
                .command_hash = hashCommand(j.cmdSlice()),
                .last_run = j.last_run,
                .active = true,
            };
            save_count += 1;
        }
    }
    // Clear remaining saved slots
    for (save_count..MAX_JOBS) |i| {
        saved_intervals[i].active = false;
    }

    // Reload from file
    loadCrontab();

    // Restore interval last_run values
    const up = fx.getUptime();
    for (&jobs) |*j| {
        if (j.active and j.kind == .interval) {
            const h = hashCommand(j.cmdSlice());
            var found = false;
            for (&saved_intervals) |*si| {
                if (si.active and si.command_hash == h) {
                    j.last_run = si.last_run;
                    si.active = false;
                    found = true;
                    break;
                }
            }
            if (!found) {
                // New interval job — set last_run to now to avoid immediate fire
                j.last_run = up;
            }
        }
    }
}

fn loadCrontab() void {
    for (&jobs) |*j| j.active = false;
    job_count = 0;

    const fd = fx.open("/etc/crontab");
    if (fd < 0) return;

    var total: usize = 0;
    while (total < crontab_buf.len) {
        const n = fx.read(fd, crontab_buf[total..]);
        if (n <= 0) break;
        total += @intCast(n);
    }
    _ = fx.close(fd);
    if (total == 0) return;

    const text = crontab_buf[0..total];
    var start: usize = 0;
    for (text, 0..) |c, i| {
        if (c == '\n') {
            if (i > start) {
                _ = addJobFromLine(text[start..i]);
            }
            start = i + 1;
        }
    }
    if (start < text.len) {
        _ = addJobFromLine(text[start..]);
    }
}

fn addJobFromLine(line: []const u8) bool {
    var pos: usize = 0;
    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;
    if (pos >= line.len or line[pos] == '#') return false;

    var slot: ?usize = null;
    for (&jobs, 0..) |*j, i| {
        if (!j.active) {
            slot = i;
            break;
        }
    }
    const idx = slot orelse return false;
    var job = &jobs[idx];
    job.* = .{};

    if (line[pos] == '@') {
        const rest = line[pos..];
        if (startsWith(rest, "@boot ") or startsWith(rest, "@boot\t")) {
            job.kind = .boot;
            job.max_runtime = 0; // no timeout for boot jobs
            pos += 6;
        } else if (startsWith(rest, "@hourly ") or startsWith(rest, "@hourly\t")) {
            job.kind = .hourly;
            job.max_runtime = 3500;
            pos += 8;
        } else if (startsWith(rest, "@daily ") or startsWith(rest, "@daily\t")) {
            job.kind = .daily;
            job.max_runtime = 86000;
            pos += 7;
        } else if (startsWith(rest, "@weekly ") or startsWith(rest, "@weekly\t")) {
            job.kind = .weekly;
            job.max_runtime = 604000;
            pos += 8;
        } else if (startsWith(rest, "@monthly ") or startsWith(rest, "@monthly\t")) {
            job.kind = .monthly;
            job.max_runtime = 0;
            pos += 9;
        } else if (startsWith(rest, "@yearly ") or startsWith(rest, "@yearly\t")) {
            job.kind = .yearly;
            job.max_runtime = 0;
            pos += 8;
        } else if (startsWith(rest, "@every ")) {
            pos += 7;
            const interval = parseInterval(line[pos..]) orelse return false;
            job.kind = .interval;
            job.interval_secs = interval.secs;
            job.max_runtime = interval.secs * 2;
            pos += interval.consumed;
            while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;
        } else {
            return false;
        }
    } else {
        job.kind = .cron;
        job.max_runtime = DEFAULT_TIMEOUT;

        const min_end = parseCronField(line[pos..], &job.minute, 0, 59) orelse return false;
        pos += min_end;
        while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;

        const hr_end = parseCronField(line[pos..], &job.hour, 0, 23) orelse return false;
        pos += hr_end;
        while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;

        const dom_end = parseCronField(line[pos..], &job.dom, 1, 31) orelse return false;
        pos += dom_end;
        while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;

        const mon_end = parseCronField(line[pos..], &job.month, 1, 12) orelse return false;
        pos += mon_end;
        while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;

        const dow_end = parseCronField(line[pos..], &job.dow, 0, 6) orelse return false;
        pos += dow_end;
    }

    // Skip whitespace
    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;
    if (pos >= line.len) return false;

    // Parse optional user field (system crontab format: schedule user command)
    // User field is a single word before the command. Heuristic: if the next
    // token doesn't contain '/' or special chars, treat it as username.
    const user_start = pos;
    var user_end = pos;
    while (user_end < line.len and line[user_end] != ' ' and line[user_end] != '\t') {
        user_end += 1;
    }
    const maybe_user = line[user_start..user_end];

    // Check if this looks like a username (letters, digits, underscore, hyphen, <= 31 chars)
    // and there's more content after it (the actual command).
    var has_command_after = false;
    if (user_end < line.len) {
        var check = user_end;
        while (check < line.len and (line[check] == ' ' or line[check] == '\t')) check += 1;
        if (check < line.len) has_command_after = true;
    }

    if (has_command_after and maybe_user.len <= 31 and isUsername(maybe_user)) {
        // User field present
        const ulen = @min(maybe_user.len, job.user.len);
        @memcpy(job.user[0..ulen], maybe_user[0..ulen]);
        job.user_len = @intCast(ulen);
        pos = user_end;
        while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;
    }
    // else: no user field, defaults to "root" (user_len = 0)

    if (pos >= line.len) return false;

    // Copy command
    const cmd = line[pos..];
    const cmd_len = @min(cmd.len, job.command.len);
    @memcpy(job.command[0..cmd_len], cmd[0..cmd_len]);
    job.command_len = @intCast(cmd_len);
    job.active = true;
    job_count += 1;
    return true;
}

fn isUsername(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_' or c == '-') continue;
        return false;
    }
    return true;
}

fn parseCronField(input: []const u8, field: *CronField, min_val: u8, max_val: u8) ?usize {
    if (input.len == 0) return null;

    var pos: usize = 0;
    if (input[0] == '*') {
        pos = 1;
        if (pos < input.len and input[pos] == '/') {
            pos += 1;
            const step_result = parseNumber(input[pos..]) orelse return null;
            const step = step_result.val;
            pos += step_result.consumed;
            if (step == 0) return null;
            var v: u8 = min_val;
            while (v <= max_val) {
                field.setBit(v);
                v += @as(u8, @intCast(step));
            }
        }
        // else: wildcard — bits=0 means match all
        return pos;
    }

    while (true) {
        const num_result = parseNumber(input[pos..]) orelse return null;
        const n: u8 = @intCast(@min(num_result.val, max_val));
        pos += num_result.consumed;

        if (pos < input.len and input[pos] == '-') {
            pos += 1;
            const end_result = parseNumber(input[pos..]) orelse return null;
            const end_val: u8 = @intCast(@min(end_result.val, max_val));
            pos += end_result.consumed;
            var v: u8 = n;
            while (v <= end_val) {
                field.setBit(v);
                v += 1;
            }
        } else {
            field.setBit(n);
        }

        if (pos < input.len and input[pos] == ',') {
            pos += 1;
            continue;
        }
        break;
    }
    return pos;
}

const ParseResult = struct { val: u32, consumed: usize };

fn parseNumber(input: []const u8) ?ParseResult {
    if (input.len == 0) return null;
    var val: u32 = 0;
    var i: usize = 0;
    while (i < input.len and input[i] >= '0' and input[i] <= '9') {
        val = val * 10 + @as(u32, input[i] - '0');
        i += 1;
    }
    if (i == 0) return null;
    return .{ .val = val, .consumed = i };
}

const IntervalResult = struct { secs: u32, consumed: usize };

fn parseInterval(input: []const u8) ?IntervalResult {
    const num = parseNumber(input) orelse return null;
    var pos = num.consumed;
    if (pos >= input.len) return null;
    const unit = input[pos];
    pos += 1;
    const secs: u32 = switch (unit) {
        's' => num.val,
        'm' => num.val * 60,
        'h' => num.val * 3600,
        else => return null,
    };
    return .{ .secs = secs, .consumed = pos };
}

fn scheduleStr(j: *const Job) []const u8 {
    return switch (j.kind) {
        .cron => "cron",
        .interval => "@every",
        .boot => "@boot",
        .hourly => "@hourly",
        .daily => "@daily",
        .weekly => "@weekly",
        .monthly => "@monthly",
        .yearly => "@yearly",
    };
}

fn hashCommand(cmd: []const u8) u64 {
    // FNV-1a 64-bit
    var h: u64 = 0xcbf29ce484222325;
    for (cmd) |c| {
        h ^= c;
        h *%= 0x100000001b3;
    }
    return h;
}

// ── Scheduler thread ────────────────────────────────────────────

fn schedulerEntry(_: ?*anyopaque) callconv(.c) noreturn {
    schedulerLoop();
}

fn schedulerLoop() noreturn {
    // Run @boot jobs on first iteration
    sched_lock.lock();
    for (&jobs) |*j| {
        if (j.active and j.kind == .boot and !j.ran_boot) {
            j.ran_boot = true;
            runJob(j);
        }
    }
    sched_lock.unlock();

    var last_minute: u8 = 0xFF;
    while (true) {
        fx.sleep(1000);

        const epoch = fx.time();
        const up = fx.getUptime();
        const dt = fx.time_lib.fromEpoch(epoch);

        sched_lock.lock();

        // Fire matching jobs
        for (&jobs) |*j| {
            if (!j.active) continue;
            if (j.running_pid >= 0) continue;

            switch (j.kind) {
                .cron => {
                    if (dt.minute != last_minute) {
                        if (j.minute.matches(dt.minute) and
                            j.hour.matches(dt.hour) and
                            j.dom.matches(dt.day) and
                            j.month.matches(dt.month) and
                            j.dow.matches(dt.dow))
                        {
                            runJob(j);
                        }
                    }
                },
                .interval => {
                    if (j.interval_secs > 0 and up >= j.last_run + j.interval_secs) {
                        j.last_run = up;
                        runJob(j);
                    }
                },
                .hourly => {
                    if (dt.minute == 0 and dt.minute != last_minute) runJob(j);
                },
                .daily => {
                    if (dt.hour == 0 and dt.minute == 0 and dt.minute != last_minute) runJob(j);
                },
                .weekly => {
                    // Fire on Sunday at 00:00
                    if (dt.dow == 0 and dt.hour == 0 and dt.minute == 0 and dt.minute != last_minute) runJob(j);
                },
                .monthly => {
                    // Fire on 1st at 00:00
                    if (dt.day == 1 and dt.hour == 0 and dt.minute == 0 and dt.minute != last_minute) runJob(j);
                },
                .yearly => {
                    // Fire on Jan 1 at 00:00
                    if (dt.month == 1 and dt.day == 1 and dt.hour == 0 and dt.minute == 0 and dt.minute != last_minute) runJob(j);
                },
                .boot => {},
            }
        }

        // Kill timed-out jobs
        for (&jobs) |*j| {
            if (!j.active or j.running_pid < 0) continue;
            if (j.max_runtime == 0) continue;
            if (up > j.spawn_time + j.max_runtime) {
                killJob(j);
            }
        }

        last_minute = dt.minute;
        sched_lock.unlock();
    }
}

fn runJob(j: *Job) void {
    if (fsh_elf_len == 0) return;
    const fsh_data = elf_buf[0..fsh_elf_len];

    var argv_buf: [512]u8 = undefined;
    const args: []const []const u8 = &.{
        "fsh",
        "-c",
        j.cmdSlice(),
    };
    const argv_block = fx.buildArgvBlock(&argv_buf, args) orelse return;

    // Map /dev/null to stdin/stdout/stderr of child
    if (null_fd >= 0) {
        const nfd: u32 = @intCast(null_fd);
        const mappings = [_]fx.FdMapping{
            .{ .parent_fd = nfd, .child_fd = 0 },
            .{ .parent_fd = nfd, .child_fd = 1 },
            .{ .parent_fd = nfd, .child_fd = 2 },
        };
        const pid = fx.spawn(fsh_data, &mappings, argv_block);
        if (pid >= 0) {
            j.running_pid = @intCast(pid);
            j.spawn_time = fx.getUptime();
        }
    } else {
        // Fallback: no fd mappings
        const pid = fx.spawn(fsh_data, &.{}, argv_block);
        if (pid >= 0) {
            j.running_pid = @intCast(pid);
            j.spawn_time = fx.getUptime();
        }
    }
}

fn killJob(j: *Job) void {
    if (j.running_pid < 0) return;
    // Write "kill" to /proc/N/ctl
    var path_buf: [32]u8 = undefined;
    var pos: usize = 0;
    const prefix = "/proc/";
    @memcpy(path_buf[0..prefix.len], prefix);
    pos = prefix.len;
    pos += writeDec(path_buf[pos..], @as(u64, @intCast(j.running_pid)));
    const suffix = "/ctl";
    @memcpy(path_buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;

    const ctl_fd = fx.open(path_buf[0..pos]);
    if (ctl_fd >= 0) {
        _ = fx.write(ctl_fd, "kill");
        _ = fx.close(ctl_fd);
    }
    j.running_pid = -1;
}

// ── Reaper thread ───────────────────────────────────────────────

fn reaperEntry(_: ?*anyopaque) callconv(.c) noreturn {
    reaperLoop();
}

fn reaperLoop() noreturn {
    while (true) {
        const status = fx.wait(0);
        if (status >= 0x8000_0000_0000_0000) {
            fx.sleep(100);
            continue;
        }

        const exit_code: u16 = @intCast((status >> 8) & 0xFF);
        const child_pid: i32 = @intCast(@as(u32, @truncate(status >> 32)));

        sched_lock.lock();

        for (&jobs, 0..) |*j, i| {
            if (j.active and j.running_pid == child_pid) {
                j.running_pid = -1;

                // In-memory log ring
                log_entries[log_head] = .{
                    .epoch = fx.time(),
                    .job_id = @intCast(i),
                    .exit_code = exit_code,
                };
                log_head = (log_head + 1) % MAX_LOG_ENTRIES;
                if (log_count < MAX_LOG_ENTRIES) log_count += 1;

                // Append to /var/log/cron
                writeLogFile(@intCast(i), j, exit_code);
                break;
            }
        }

        sched_lock.unlock();
    }
}

var log_line_buf: [512]u8 = undefined;

fn writeLogFile(job_id: u16, j: *const Job, exit_code: u16) void {
    if (log_fd < 0) return;

    var pos: usize = 0;

    // Formatted timestamp
    const epoch = fx.time();
    const dt = fx.time_lib.fromEpoch(epoch);
    var dt_buf: [20]u8 = undefined;
    const dt_str = fx.time_lib.fmtDateTime(dt, &dt_buf);
    if (pos + dt_str.len <= log_line_buf.len) {
        @memcpy(log_line_buf[pos..][0..dt_str.len], dt_str);
        pos += dt_str.len;
    }
    if (pos < log_line_buf.len) {
        log_line_buf[pos] = ' ';
        pos += 1;
    }

    // Job id
    pos += writeDec(log_line_buf[pos..], job_id);
    if (pos < log_line_buf.len) {
        log_line_buf[pos] = ' ';
        pos += 1;
    }

    // User
    const u = j.userSlice();
    if (pos + u.len <= log_line_buf.len) {
        @memcpy(log_line_buf[pos..][0..u.len], u);
        pos += u.len;
    }
    if (pos < log_line_buf.len) {
        log_line_buf[pos] = ' ';
        pos += 1;
    }

    // Exit code
    if (pos + 5 <= log_line_buf.len) {
        @memcpy(log_line_buf[pos..][0..5], "exit=");
        pos += 5;
    }
    pos += writeDec(log_line_buf[pos..], exit_code);
    if (pos < log_line_buf.len) {
        log_line_buf[pos] = ' ';
        pos += 1;
    }

    // Command (truncated to fit)
    const cmd = j.cmdSlice();
    const clen = @min(cmd.len, log_line_buf.len -| (pos + 1));
    if (clen > 0) {
        @memcpy(log_line_buf[pos..][0..clen], cmd[0..clen]);
        pos += clen;
    }
    if (pos < log_line_buf.len) {
        log_line_buf[pos] = '\n';
        pos += 1;
    }

    _ = fx.write(log_fd, log_line_buf[0..pos]);
}

// ── Helpers ─────────────────────────────────────────────────────

fn loadFsh() void {
    var p = fx.path.PathBuf.from("/bin/fsh");
    const fd = fx.open(p.slice());
    if (fd < 0) {
        _ = fx.write(1, "crond: cannot load /bin/fsh\n");
        return;
    }
    var total: usize = 0;
    while (total < elf_buf.len) {
        const n = fx.read(fd, elf_buf[total..]);
        if (n <= 0) break;
        total += @intCast(n);
    }
    _ = fx.close(fd);
    fsh_elf_len = total;
}

fn writeDec(buf: []u8, val: anytype) usize {
    const v: u64 = @intCast(val);
    if (buf.len == 0) return 0;
    if (v == 0) {
        buf[0] = '0';
        return 1;
    }
    var tmp: [20]u8 = undefined;
    var x = v;
    var i: usize = 0;
    while (x > 0 and i < 20) {
        tmp[i] = '0' + @as(u8, @intCast(x % 10));
        x /= 10;
        i += 1;
    }
    const len = @min(i, buf.len);
    for (0..len) |j| {
        buf[j] = tmp[i - 1 - j];
    }
    return len;
}

fn parseDec(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var result: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        result = result * 10 + (c - '0');
    }
    return result;
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    return eql(s[0..prefix.len], prefix);
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

// ── IPC worker loop ─────────────────────────────────────────────

fn workerLoop() noreturn {
    var wmsg: fx.IpcMessage = undefined;
    var wreply: fx.IpcMessage = undefined;

    while (true) {
        const rc = fx.ipc_recv(SERVER_FD, &wmsg);
        if (rc < 0) continue;

        switch (wmsg.tag) {
            fx.T_OPEN => handleOpen(&wmsg, &wreply),
            fx.T_READ => handleRead(&wmsg, &wreply),
            fx.T_WRITE => handleWrite(&wmsg, &wreply),
            fx.T_CLOSE => handleClose(&wmsg, &wreply),
            fx.T_STAT => handleStat(&wmsg, &wreply),
            else => {
                wreply = fx.IpcMessage.init(fx.R_ERROR);
            },
        }

        _ = fx.ipc_reply(SERVER_FD, &wreply);
    }
}

// ── Entry point ─────────────────────────────────────────────────

export fn _start() noreturn {
    _ = fx.write(1, "crond: started\n");

    // Cache fsh ELF once (avoid reloading from disk on every job spawn)
    loadFsh();
    if (fsh_elf_len == 0) {
        _ = fx.write(1, "crond: warning: /bin/fsh not found, jobs will not run\n");
    }

    // Open /dev/null for job fd mapping
    null_fd = @intCast(fx.open("/dev/null"));

    // Ensure /var/log exists, open log file
    _ = fx.mkdir("/var");
    _ = fx.mkdir("/var/log");
    log_fd = @intCast(fx.create("/var/log/cron", 0));

    // Load crontab (initial load, no interval preservation needed)
    sched_lock.lock();
    loadCrontab();
    sched_lock.unlock();

    // Spawn scheduler thread
    _ = fx.thread.spawnThread(schedulerEntry, null) catch {};

    // Spawn reaper thread
    _ = fx.thread.spawnThread(reaperEntry, null) catch {};

    // Main thread enters IPC worker loop
    workerLoop();
}
