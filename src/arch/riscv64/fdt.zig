/// Minimal FDT (Flattened Device Tree) parser for memory discovery.
///
/// Walks the DTB structure block to find `/memory@...` nodes and
/// extracts the `reg` property (base + size).  No heap allocation —
/// pure pointer-walking over the FDT blob in place.
///
/// Reference: Devicetree Specification v0.4, Chapter 5 (Flattened Devicetree)
const klog = @import("../../klog.zig");

const FDT_MAGIC: u32 = 0xD00DFEED;

// Structure block tokens
const FDT_BEGIN_NODE: u32 = 0x00000001;
const FDT_END_NODE: u32 = 0x00000002;
const FDT_PROP: u32 = 0x00000003;
const FDT_NOP: u32 = 0x00000004;
const FDT_END: u32 = 0x00000009;

pub const MemoryRegion = struct {
    base: u64,
    size: u64,
};

/// Read a big-endian u32 from an unaligned pointer.
fn readBe32(ptr: [*]const u8) u32 {
    return @as(u32, ptr[0]) << 24 |
        @as(u32, ptr[1]) << 16 |
        @as(u32, ptr[2]) << 8 |
        @as(u32, ptr[3]);
}

/// Read a big-endian u64 from two consecutive big-endian u32 cells.
fn readBe64(ptr: [*]const u8) u64 {
    const hi: u64 = readBe32(ptr);
    const lo: u64 = readBe32(ptr + 4);
    return (hi << 32) | lo;
}

/// Align `offset` up to a 4-byte boundary.
fn align4(offset: u32) u32 {
    return (offset + 3) & ~@as(u32, 3);
}

/// Check if a NUL-terminated C string starts with `prefix`.
fn startsWith(s: [*]const u8, prefix: []const u8) bool {
    for (prefix, 0..) |c, i| {
        if (s[i] != c) return false;
    }
    return true;
}

/// Look up a string in the FDT strings block by offset.
fn getString(blob: [*]const u8, strings_off: u32, name_off: u32) [*]const u8 {
    return blob + strings_off + name_off;
}

/// Compare a NUL-terminated C string with a Zig slice.
fn strEql(s: [*]const u8, expected: []const u8) bool {
    for (expected, 0..) |c, i| {
        if (s[i] != c) return false;
    }
    return s[expected.len] == 0;
}

/// Probe the FDT blob at `dtb_addr` for the first memory region.
///
/// Returns the base address and size from the `reg` property of the
/// first node whose name starts with "memory", or null if parsing fails.
pub fn probeMemory(dtb_addr: u64) ?MemoryRegion {
    if (dtb_addr == 0) return null;

    const blob: [*]const u8 = @ptrFromInt(dtb_addr);

    // Validate magic
    const magic = readBe32(blob);
    if (magic != FDT_MAGIC) {
        klog.warn("FDT: bad magic 0x");
        klog.warnHex(@as(u64, magic));
        klog.warn("\n");
        return null;
    }

    const totalsize = readBe32(blob + 4);
    const off_dt_struct = readBe32(blob + 8);
    const off_dt_strings = readBe32(blob + 12);

    // Sanity: totalsize should be reasonable (< 16 MB)
    if (totalsize > 16 * 1024 * 1024) return null;

    // Walk the structure block
    var offset: u32 = off_dt_struct;
    const end_offset: u32 = off_dt_struct + totalsize; // conservative upper bound
    var in_memory_node = false;
    var depth: u32 = 0;
    var memory_depth: u32 = 0;

    while (offset + 4 <= end_offset) {
        const token = readBe32(blob + offset);
        offset += 4;

        switch (token) {
            FDT_BEGIN_NODE => {
                depth += 1;
                // Node name follows the token (NUL-terminated, 4-byte aligned)
                const name_ptr = blob + offset;

                // Advance past the NUL-terminated name string
                var name_len: u32 = 0;
                while (offset + name_len < end_offset and (blob + offset)[name_len] != 0) {
                    name_len += 1;
                }
                offset = align4(offset + name_len + 1); // +1 for NUL

                // Check if this is a top-level "memory" or "memory@..." node
                if (depth == 1 and startsWith(name_ptr, "memory")) {
                    in_memory_node = true;
                    memory_depth = depth;
                }
            },
            FDT_END_NODE => {
                if (in_memory_node and depth == memory_depth) {
                    in_memory_node = false;
                }
                if (depth > 0) depth -= 1;
            },
            FDT_PROP => {
                // Property: u32 len, u32 nameoff, then len bytes of data (4-byte aligned)
                if (offset + 8 > end_offset) return null;
                const prop_len = readBe32(blob + offset);
                const name_off = readBe32(blob + offset + 4);
                offset += 8;

                if (in_memory_node and depth == memory_depth) {
                    const prop_name = getString(blob, off_dt_strings, name_off);
                    if (strEql(prop_name, "reg")) {
                        // Standard: #address-cells=2, #size-cells=2 → 16 bytes
                        if (prop_len >= 16 and offset + 16 <= end_offset) {
                            const base = readBe64(blob + offset);
                            const size = readBe64(blob + offset + 8);
                            return MemoryRegion{ .base = base, .size = size };
                        }
                    }
                }

                offset = align4(offset + prop_len);
            },
            FDT_NOP => {},
            FDT_END => break,
            else => {
                // Unknown token — bail out
                klog.warn("FDT: unknown token 0x");
                klog.warnHex(@as(u64, token));
                klog.warn("\n");
                return null;
            },
        }
    }

    return null;
}
