/// Kernel pipe subsystem — ring-buffer pipes for inter-process communication.
///
/// Pipes are kernel-managed and do not require an IPC server. Each pipe has
/// a fixed-size buffer and reference-counted read/write ends.
///
/// Wake pattern: waker just marks the process as .ready. Actual data delivery
/// happens in process.switchTo() after the target's address space is loaded,
/// same as console_read and net_read.
///
/// SMP: Per-pipe spinlock guards all buffer/refcount operations. Global alloc
/// lock guards pipe slot allocation. Lock ordering: alloc_lock → pipe.lock.
const process = @import("process.zig");
const SpinLock = @import("spinlock.zig").SpinLock;

pub const MAX_PIPES = 32;
pub const PIPE_BUF_SIZE = 4096;

pub const Pipe = struct {
    buf: [PIPE_BUF_SIZE]u8 = undefined,
    read_pos: usize = 0,
    write_pos: usize = 0,
    count: usize = 0,
    readers: u8 = 0,
    writers: u8 = 0,
    read_waiters: [4]?u16 = [_]?u16{null} ** 4,
    write_waiters: [4]?u16 = [_]?u16{null} ** 4,
    active: bool = false,
    /// Per-pipe spinlock for SMP safety.
    lock: SpinLock = .{},
};

var pipes: [MAX_PIPES]Pipe = [_]Pipe{.{}} ** MAX_PIPES;

/// Global lock for pipe slot allocation.
var alloc_lock: SpinLock = .{};

/// Allocate a new pipe. Returns pipe_id or null if full.
pub fn alloc() ?u8 {
    alloc_lock.lock();
    defer alloc_lock.unlock();

    for (&pipes, 0..) |*p, i| {
        if (!p.active) {
            p.* = .{};
            p.active = true;
            p.readers = 1;
            p.writers = 1;
            return @intCast(i);
        }
    }
    return null;
}

/// Free a pipe slot. Caller must hold pipe lock or ensure exclusive access.
pub fn free(id: u8) void {
    if (id >= MAX_PIPES) return;
    pipes[id].active = false;
}

/// Read from pipe into dest. Returns bytes read, null if empty and writers
/// exist (caller should block), or 0 if EOF (no writers left).
pub fn pipeRead(id: u8, dest: []u8) ?usize {
    if (id >= MAX_PIPES) return 0;
    const p = &pipes[id];
    p.lock.lock();
    defer p.lock.unlock();

    if (!p.active) return 0;

    if (p.count == 0) {
        if (p.writers == 0) return 0; // EOF
        return null; // block — no data yet
    }

    const n = @min(dest.len, p.count);
    for (0..n) |i| {
        dest[i] = p.buf[p.read_pos];
        p.read_pos = (p.read_pos + 1) % PIPE_BUF_SIZE;
    }
    p.count -= n;

    // Wake all blocked writers — they'll retry in switchTo
    for (&p.write_waiters) |*slot| {
        if (slot.*) |wpid| {
            if (process.getByPid(wpid)) |wproc| {
                if (wproc.state == .blocked) process.markReady(wproc);
            }
            slot.* = null;
        }
    }

    return n;
}

/// Write src into pipe. Returns bytes written, null if full and readers
/// exist (caller should block), or error sentinel if no readers.
pub const EPIPE: usize = 0xFFFFFFFFFFFFFFFF;

pub fn pipeWrite(id: u8, src: []const u8) ?usize {
    if (id >= MAX_PIPES) return EPIPE;
    const p = &pipes[id];
    p.lock.lock();
    defer p.lock.unlock();

    if (!p.active) return EPIPE;

    if (p.readers == 0) return EPIPE;

    if (p.count >= PIPE_BUF_SIZE) {
        return null; // block — pipe full
    }

    const space = PIPE_BUF_SIZE - p.count;
    const n = @min(src.len, space);
    for (0..n) |i| {
        p.buf[p.write_pos] = src[i];
        p.write_pos = (p.write_pos + 1) % PIPE_BUF_SIZE;
    }
    p.count += n;

    // Wake all blocked readers — they'll get data in switchTo
    for (&p.read_waiters) |*slot| {
        if (slot.*) |rpid| {
            if (process.getByPid(rpid)) |rproc| {
                if (rproc.state == .blocked) process.markReady(rproc);
            }
            slot.* = null;
        }
    }

    return n;
}

/// Check if pipe has data or is at EOF (for delivery in switchTo).
pub fn hasDataOrEof(id: u8) bool {
    if (id >= MAX_PIPES) return true;
    const p = &pipes[id];
    p.lock.lock();
    defer p.lock.unlock();
    if (!p.active) return true;
    return p.count > 0 or p.writers == 0;
}

/// Check if pipe has space for writing (for delivery in switchTo).
pub fn hasSpaceOrBroken(id: u8) bool {
    if (id >= MAX_PIPES) return true;
    const p = &pipes[id];
    p.lock.lock();
    defer p.lock.unlock();
    if (!p.active) return true;
    return p.count < PIPE_BUF_SIZE or p.readers == 0;
}

/// Close the read end. Decrements readers, wakes blocked writer.
pub fn closeReadEnd(id: u8) void {
    if (id >= MAX_PIPES) return;
    const p = &pipes[id];
    p.lock.lock();
    defer p.lock.unlock();

    if (!p.active) return;
    if (p.readers > 0) p.readers -= 1;

    // Wake all blocked writers — they'll get EPIPE on retry in switchTo
    for (&p.write_waiters) |*slot| {
        if (slot.*) |wpid| {
            if (process.getByPid(wpid)) |wproc| {
                if (wproc.state == .blocked) process.markReady(wproc);
            }
            slot.* = null;
        }
    }

    if (p.readers == 0 and p.writers == 0) free(id);
}

/// Close the write end. Decrements writers, wakes blocked reader (EOF).
pub fn closeWriteEnd(id: u8) void {
    if (id >= MAX_PIPES) return;
    const p = &pipes[id];
    p.lock.lock();
    defer p.lock.unlock();

    if (!p.active) return;
    if (p.writers > 0) p.writers -= 1;

    // Wake all blocked readers — they'll get EOF in switchTo
    for (&p.read_waiters) |*slot| {
        if (slot.*) |rpid| {
            if (process.getByPid(rpid)) |rproc| {
                if (rproc.state == .blocked) process.markReady(rproc);
            }
            slot.* = null;
        }
    }

    if (p.readers == 0 and p.writers == 0) free(id);
}

/// Increment reader count (used when spawning child with pipe fd).
pub fn incrementReaders(id: u8) void {
    if (id >= MAX_PIPES) return;
    const p = &pipes[id];
    p.lock.lock();
    defer p.lock.unlock();
    if (p.active) p.readers += 1;
}

/// Increment writer count (used when spawning child with pipe fd).
pub fn incrementWriters(id: u8) void {
    if (id >= MAX_PIPES) return;
    const p = &pipes[id];
    p.lock.lock();
    defer p.lock.unlock();
    if (p.active) p.writers += 1;
}

pub fn setReadWaiter(id: u8, pid: u16) void {
    if (id >= MAX_PIPES) return;
    const p = &pipes[id];
    p.lock.lock();
    defer p.lock.unlock();
    for (&p.read_waiters) |*slot| {
        if (slot.* == null) {
            slot.* = pid;
            return;
        }
    }
    // All slots full — overwrite the first one (best effort)
    p.read_waiters[0] = pid;
}

pub fn setWriteWaiter(id: u8, pid: u16) void {
    if (id >= MAX_PIPES) return;
    const p = &pipes[id];
    p.lock.lock();
    defer p.lock.unlock();
    for (&p.write_waiters) |*slot| {
        if (slot.* == null) {
            slot.* = pid;
            return;
        }
    }
    // All slots full — overwrite the first one (best effort)
    p.write_waiters[0] = pid;
}
