// Kernel trace buffer — per-CPU binary ring buffers for structured event tracing.
// Always-on, ~30-50 cycle overhead per trace point. No locks on write path.

const builtin = @import("builtin");
const percpu = @import("percpu.zig");

pub const TRACE_BUF_ENTRIES = 1024;

pub const EventType = enum(u8) {
    syscall_enter,
    syscall_exit,
    irq_enter,
    irq_exit,
    ctx_switch,
    ipc_send,
    ipc_recv,
    ipc_reply,
    process_create,
    process_exit,
    page_fault,
    timer_tick,
};

pub const TraceEvent = extern struct {
    timestamp: u64,
    data: u32,
    pid: u16,
    core_id: u8,
    event_type: EventType,
};

// Per-CPU ring buffers in BSS (NOT inside PerCpu to avoid bloating it).
// 128 cores x 1024 entries x 16 bytes = 2 MB.
var trace_bufs: [percpu.MAX_CORES][TRACE_BUF_ENTRIES]TraceEvent linksection(".bss") = undefined;
var trace_write_pos: [percpu.MAX_CORES]u32 linksection(".bss") = undefined;
var trace_count: [percpu.MAX_CORES]u32 linksection(".bss") = undefined;

pub fn init() void {
    for (0..percpu.MAX_CORES) |i| {
        trace_write_pos[i] = 0;
        trace_count[i] = 0;
    }
}

/// Hot-path trace write. Inline to minimize overhead at call sites.
pub inline fn trace(event_type: EventType, data: u32) void {
    const core_id = percpu.getCoreId();
    const pid: u16 = blk: {
        const process = @import("process.zig");
        const proc = process.getCurrent();
        break :blk if (proc) |p| @as(u16, @truncate(p.pid)) else 0;
    };
    const pos = trace_write_pos[core_id];
    trace_bufs[core_id][pos] = .{
        .timestamp = rdtsc(),
        .data = data,
        .pid = pid,
        .core_id = core_id,
        .event_type = event_type,
    };
    trace_write_pos[core_id] = (pos + 1) % TRACE_BUF_ENTRIES;
    if (trace_count[core_id] < TRACE_BUF_ENTRIES) {
        trace_count[core_id] += 1;
    }
}

inline fn rdtsc() u64 {
    if (builtin.cpu.arch == .x86_64) {
        var lo: u32 = undefined;
        var hi: u32 = undefined;
        asm volatile ("rdtsc"
            : [lo] "={eax}" (lo),
              [hi] "={edx}" (hi),
        );
        return (@as(u64, hi) << 32) | lo;
    } else if (builtin.cpu.arch == .aarch64) {
        return asm volatile ("mrs %[ret], cntvct_el0"
            : [ret] "=r" (-> u64),
        );
    } else {
        // riscv64: use rdtime
        return asm volatile ("rdtime %[ret]"
            : [ret] "=r" (-> u64),
        );
    }
}

pub fn eventName(et: EventType) []const u8 {
    return switch (et) {
        .syscall_enter => "SC_ENTER",
        .syscall_exit => "SC_EXIT",
        .irq_enter => "IRQ_ENTER",
        .irq_exit => "IRQ_EXIT",
        .ctx_switch => "CTX_SW",
        .ipc_send => "IPC_SEND",
        .ipc_recv => "IPC_RECV",
        .ipc_reply => "IPC_REPLY",
        .process_create => "PROC_NEW",
        .process_exit => "PROC_EXIT",
        .page_fault => "PG_FAULT",
        .timer_tick => "TIMER",
    };
}

/// Format trace entries for a single core into a text buffer.
/// Returns the number of bytes written.
pub fn formatCoreEntries(core_id: u8, buf: []u8) usize {
    const count = trace_count[core_id];
    if (count == 0) return 0;

    var pos: usize = 0;

    // Determine oldest entry index
    const start: u32 = if (count < TRACE_BUF_ENTRIES)
        0
    else
        trace_write_pos[core_id];

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const idx = (start + i) % TRACE_BUF_ENTRIES;
        const ev = &trace_bufs[core_id][idx];

        // Timestamp (decimal)
        pos = appendDec64(buf, pos, ev.timestamp);
        if (pos >= buf.len) return pos;
        pos = appendByte(buf, pos, ' ');

        // Event name
        pos = appendSlice(buf, pos, eventName(ev.event_type));
        if (pos >= buf.len) return pos;
        pos = appendByte(buf, pos, ' ');

        // PID
        pos = appendDec64(buf, pos, ev.pid);
        pos = appendByte(buf, pos, ' ');

        // Data
        pos = appendDec64(buf, pos, ev.data);
        pos = appendByte(buf, pos, '\n');
    }
    return pos;
}

/// Get the entry count for a core.
pub fn getCount(core_id: u8) u32 {
    return trace_count[core_id];
}

fn appendByte(buf: []u8, pos: usize, c: u8) usize {
    if (pos >= buf.len) return pos;
    buf[pos] = c;
    return pos + 1;
}

fn appendSlice(buf: []u8, pos: usize, s: []const u8) usize {
    var p = pos;
    for (s) |c| {
        if (p >= buf.len) break;
        buf[p] = c;
        p += 1;
    }
    return p;
}

fn appendDec64(buf: []u8, pos: usize, val: u64) usize {
    if (val == 0) return appendByte(buf, pos, '0');
    var tmp: [20]u8 = undefined;
    var n = val;
    var i: usize = 0;
    while (n > 0) : (i += 1) {
        tmp[i] = @intCast(n % 10 + '0');
        n /= 10;
    }
    var p = pos;
    var j = i;
    while (j > 0) {
        j -= 1;
        if (p >= buf.len) break;
        buf[p] = tmp[j];
        p += 1;
    }
    return p;
}
