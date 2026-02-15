/// Fixed buffer allocator for Fornax userspace.
///
/// Simple bump allocator over a caller-provided buffer.
/// No free/reuse — call reset() to reclaim all memory.

pub const FixedBufferAllocator = struct {
    buf: []u8,
    pos: usize = 0,

    pub fn init(buf: []u8) FixedBufferAllocator {
        return .{ .buf = buf };
    }

    /// Allocate `len` bytes with the given alignment.
    pub fn alloc(self: *FixedBufferAllocator, len: usize, alignment: usize) ?[*]u8 {
        // Align up
        const aligned_pos = (self.pos + alignment - 1) & ~(alignment - 1);
        if (aligned_pos + len > self.buf.len) return null;
        const result = self.buf.ptr + aligned_pos;
        self.pos = aligned_pos + len;
        return result;
    }

    /// Allocate a single instance of type T.
    pub fn create(self: *FixedBufferAllocator, comptime T: type) ?*T {
        const ptr = self.alloc(@sizeOf(T), @alignOf(T)) orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    /// Allocate a slice of type T with the given length.
    pub fn allocSlice(self: *FixedBufferAllocator, comptime T: type, len: usize) ?[]T {
        const ptr = self.alloc(@sizeOf(T) * len, @alignOf(T)) orelse return null;
        const typed: [*]T = @ptrCast(@alignCast(ptr));
        return typed[0..len];
    }

    /// Reset the allocator, reclaiming all memory.
    pub fn reset(self: *FixedBufferAllocator) void {
        self.pos = 0;
    }
};
