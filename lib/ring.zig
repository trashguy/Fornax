/// SPSC (Single-Producer Single-Consumer) ring buffer over shared memory.
///
/// Lock-free ring buffer for zero-copy bulk data transfer between processes.
/// Uses atomic head/tail pointers and futex for wake/wait signaling.
///
/// Shared memory layout:
///   offset  0: write_pos  (u32, atomic) — producer increments
///   offset  4: read_pos   (u32, atomic) — consumer increments
///   offset  8: buf_size   (u32) — power of 2, set once at init
///   offset 12: buf_mask   (u32) — buf_size - 1
///   offset 16: futex_word (u32) — for wake/wait signaling
///   offset 64: data[buf_size] — ring buffer payload
const syscall = @import("syscall.zig");

const HEADER_SIZE: u32 = 64;

/// Futex operations (matching kernel).
const FUTEX_WAIT: u64 = 0;
const FUTEX_WAKE: u64 = 1;

pub const Ring = struct {
    base: [*]u8,
    buf_size: u32,
    buf_mask: u32,

    fn writePos(self: *const Ring) *align(1) volatile u32 {
        return @ptrCast(@alignCast(self.base));
    }

    fn readPos(self: *const Ring) *align(1) volatile u32 {
        return @ptrCast(@alignCast(self.base + 4));
    }

    fn futexWord(self: *const Ring) *align(1) volatile u32 {
        return @ptrCast(@alignCast(self.base + 16));
    }

    fn dataPtr(self: *const Ring) [*]u8 {
        return self.base + HEADER_SIZE;
    }

    /// Initialize as producer — sets up the header in shared memory.
    pub fn initProducer(ptr: [*]u8, total_size: u32) Ring {
        // buf_size must be power of 2 and fit in total_size - HEADER_SIZE
        const data_space = total_size -| HEADER_SIZE;
        // Round down to power of 2
        var bs: u32 = 1;
        while (bs * 2 <= data_space) : (bs *= 2) {}
        const mask = bs - 1;

        // Write header
        const wp: *align(1) volatile u32 = @ptrCast(@alignCast(ptr));
        wp.* = 0;
        const rp: *align(1) volatile u32 = @ptrCast(@alignCast(ptr + 4));
        rp.* = 0;
        const sz: *align(1) u32 = @ptrCast(@alignCast(ptr + 8));
        sz.* = bs;
        const mk: *align(1) u32 = @ptrCast(@alignCast(ptr + 12));
        mk.* = mask;
        const fw: *align(1) volatile u32 = @ptrCast(@alignCast(ptr + 16));
        fw.* = 0;

        return .{ .base = ptr, .buf_size = bs, .buf_mask = mask };
    }

    /// Initialize as consumer — reads existing header from shared memory.
    pub fn initConsumer(ptr: [*]u8) Ring {
        const sz: *align(1) const u32 = @ptrCast(@alignCast(ptr + 8));
        const mk: *align(1) const u32 = @ptrCast(@alignCast(ptr + 12));
        return .{ .base = ptr, .buf_size = sz.*, .buf_mask = mk.* };
    }

    /// Write data into the ring buffer. Returns number of bytes written.
    pub fn write(self: *Ring, data: []const u8) u32 {
        const wp = self.writePos().*;
        const rp = self.readPos().*;
        const avail = self.buf_size - (wp -% rp);
        const to_write: u32 = @intCast(@min(data.len, avail));
        if (to_write == 0) return 0;

        const start = wp & self.buf_mask;
        const buf = self.dataPtr();

        // Write may wrap around the ring
        const first = @min(to_write, self.buf_size - start);
        @memcpy(buf[start..][0..first], data[0..first]);
        if (to_write > first) {
            const second = to_write - first;
            @memcpy(buf[0..second], data[first..][0..second]);
        }

        // Store with release semantics (volatile ensures ordering vs. consumer)
        self.writePos().* = wp +% to_write;
        return to_write;
    }

    /// Read data from the ring buffer. Returns number of bytes read.
    pub fn read(self: *Ring, buf: []u8) u32 {
        const wp = self.writePos().*;
        const rp = self.readPos().*;
        const avail = wp -% rp;
        const to_read: u32 = @intCast(@min(buf.len, avail));
        if (to_read == 0) return 0;

        const start = rp & self.buf_mask;
        const data = self.dataPtr();

        // Read may wrap around the ring
        const first = @min(to_read, self.buf_size - start);
        @memcpy(buf[0..first], data[start..][0..first]);
        if (to_read > first) {
            const second = to_read - first;
            @memcpy(buf[first..][0..second], data[0..second]);
        }

        // Store with release semantics
        self.readPos().* = rp +% to_read;
        return to_read;
    }

    /// Bytes available to read.
    pub fn available(self: *const Ring) u32 {
        return self.writePos().* -% self.readPos().*;
    }

    /// Bytes available to write.
    pub fn space(self: *const Ring) u32 {
        return self.buf_size - (self.writePos().* -% self.readPos().*);
    }

    /// Wake the consumer (via futex on the futex_word).
    pub fn wake(self: *Ring) void {
        const fw = self.futexWord();
        fw.* +%= 1;
        _ = syscall.futex(@intFromPtr(fw), FUTEX_WAKE, 1, 0);
    }

    /// Wait if the ring is empty (consumer side).
    pub fn waitIfEmpty(self: *Ring) void {
        if (self.available() > 0) return;
        const fw = self.futexWord();
        const val = fw.*;
        // If still empty after reading futex_word, sleep
        if (self.available() == 0) {
            _ = syscall.futex(@intFromPtr(fw), FUTEX_WAIT, val, 100_000_000); // 100ms timeout
        }
    }
};
