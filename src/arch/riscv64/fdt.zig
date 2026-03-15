/// FDT (Flattened Device Tree) parser for hardware discovery.
///
/// Walks the DTB structure block to discover memory, UART, PLIC, CPUs,
/// ethernet, and MMC from FDT properties.  No heap allocation — pure
/// pointer-walking over the FDT blob in place.
///
/// Board config constants (board/) serve as fallbacks; FDT overrides them.
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

/// Maximum RAM regions to track.
const MAX_RAM_REGIONS = 4;

/// Maximum CPUs to track.
const MAX_CPUS = 16;

pub const MemoryRegion = struct {
    base: u64,
    size: u64,
};

/// Discovered hardware configuration from FDT.
pub const FdtConfig = struct {
    /// UART base address (0 = not found).
    uart_base: u64 = 0,
    /// PLIC base address (0 = not found).
    plic_base: u64 = 0,
    /// Timer / timebase frequency (0 = not found).
    timer_freq: u32 = 0,
    /// Discovered RAM regions.
    ram_regions: [MAX_RAM_REGIONS]MemoryRegion = [_]MemoryRegion{.{ .base = 0, .size = 0 }} ** MAX_RAM_REGIONS,
    ram_count: u8 = 0,
    /// Discovered CPU hart IDs (only rv64-capable harts).
    cpu_harts: [MAX_CPUS]u32 = [_]u32{0} ** MAX_CPUS,
    cpu_count: u8 = 0,
    /// Ethernet base address (0 = not found).
    ethernet_base: u64 = 0,
    /// MMC base address (0 = not found).
    mmc_base: u64 = 0,

    /// Whether any fields were populated from FDT.
    pub fn valid(self: *const FdtConfig) bool {
        return self.ram_count > 0 or self.uart_base != 0 or self.plic_base != 0;
    }
};

/// Global FDT config — populated by probe(), read by boot/driver init.
pub var fdt_config: FdtConfig = .{};

// ── Low-level helpers ──────────────────────────────────────────────

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

/// Read a value from `ptr` respecting cell count (1 = u32, 2 = u64).
fn readCells(ptr: [*]const u8, cells: u32) u64 {
    return if (cells == 2) readBe64(ptr) else @as(u64, readBe32(ptr));
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

/// Compare a NUL-terminated C string with a Zig slice.
fn strEql(s: [*]const u8, expected: []const u8) bool {
    for (expected, 0..) |c, i| {
        if (s[i] != c) return false;
    }
    return s[expected.len] == 0;
}

/// Look up a string in the FDT strings block by offset.
fn getString(blob: [*]const u8, strings_off: u32, name_off: u32) [*]const u8 {
    return blob + strings_off + name_off;
}

/// Check if a `compatible` property value (concatenated NUL-terminated strings)
/// contains the given string.
fn compatibleContains(data: [*]const u8, data_len: u32, needle: []const u8) bool {
    var pos: u32 = 0;
    while (pos < data_len) {
        const s = data + pos;
        if (strEql(s, needle)) return true;
        // Advance past NUL-terminated string
        while (pos < data_len and data[pos] != 0) : (pos += 1) {}
        pos += 1; // skip NUL
    }
    return false;
}

/// Extract the unit address from a node name like "serial@10000000".
/// Returns 0 if no '@' found or parse fails.
fn parseNodeAddr(name: [*]const u8) u64 {
    // Find '@'
    var i: u32 = 0;
    while (name[i] != 0 and name[i] != '@') : (i += 1) {}
    if (name[i] != '@') return 0;
    i += 1; // skip '@'

    // Parse hex digits
    var val: u64 = 0;
    while (name[i] != 0) : (i += 1) {
        const c = name[i];
        const digit: u64 = if (c >= '0' and c <= '9')
            c - '0'
        else if (c >= 'a' and c <= 'f')
            c - 'a' + 10
        else if (c >= 'A' and c <= 'F')
            c - 'A' + 10
        else
            break;
        val = (val << 4) | digit;
    }
    return val;
}

// ── FDT walker state ───────────────────────────────────────────────

/// Per-depth tracking of #address-cells and #size-cells.
const MAX_DEPTH = 16;

const NodeContext = struct {
    address_cells: u32 = 2,
    size_cells: u32 = 2,
};

/// State machine for the FDT walk — what kind of node we're inside.
const NodeKind = enum {
    none,
    root,
    memory,
    soc,
    uart,
    plic,
    cpus,
    cpu,
    ethernet,
    mmc,
    other,
};

// ── Main probe function ────────────────────────────────────────────

/// Probe the FDT blob at `dtb_addr` for hardware configuration.
/// Populates the global `fdt_config`. Returns it for convenience.
pub fn probe(dtb_addr: u64) *FdtConfig {
    fdt_config = .{};

    if (dtb_addr == 0) return &fdt_config;

    const blob: [*]const u8 = @ptrFromInt(dtb_addr);

    // Validate magic
    const magic = readBe32(blob);
    if (magic != FDT_MAGIC) {
        klog.warn("FDT: bad magic ");
        klog.warnHex(@as(u64, magic));
        klog.warn("\n");
        return &fdt_config;
    }

    const totalsize = readBe32(blob + 4);
    const off_dt_struct = readBe32(blob + 8);
    const off_dt_strings = readBe32(blob + 12);

    // Sanity: totalsize should be reasonable (< 16 MB)
    if (totalsize > 16 * 1024 * 1024) return &fdt_config;

    // Walk state
    var depth: u32 = 0;
    var node_stack: [MAX_DEPTH]NodeKind = [_]NodeKind{.none} ** MAX_DEPTH;
    var cell_stack: [MAX_DEPTH]NodeContext = [_]NodeContext{.{}} ** MAX_DEPTH;
    // Track node name pointer for current depth (for reg address extraction)
    var name_stack: [MAX_DEPTH][*]const u8 = undefined;

    // Properties accumulated for the current node (reset on FDT_BEGIN_NODE)
    var cur_compatible: ?[*]const u8 = null;
    var cur_compatible_len: u32 = 0;
    var cur_reg: ?[*]const u8 = null;
    var cur_reg_len: u32 = 0;

    var offset: u32 = off_dt_struct;
    const end_offset: u32 = off_dt_struct + totalsize;

    while (offset + 4 <= end_offset) {
        const token = readBe32(blob + offset);
        offset += 4;

        switch (token) {
            FDT_BEGIN_NODE => {
                const name_ptr = blob + offset;

                // Advance past NUL-terminated name
                var name_len: u32 = 0;
                while (offset + name_len < end_offset and (blob + offset)[name_len] != 0) {
                    name_len += 1;
                }
                offset = align4(offset + name_len + 1);

                // Inherit cell sizes from parent
                if (depth < MAX_DEPTH) {
                    cell_stack[depth] = if (depth > 0) cell_stack[depth - 1] else .{};
                    name_stack[depth] = name_ptr;
                }

                // Classify node
                const kind: NodeKind = classify: {
                    if (depth == 0) break :classify .root;
                    if (startsWith(name_ptr, "memory")) break :classify .memory;
                    if (startsWith(name_ptr, "soc")) break :classify .soc;
                    if (startsWith(name_ptr, "cpus")) break :classify .cpus;
                    if (startsWith(name_ptr, "cpu@")) break :classify .cpu;
                    // Within /soc, look for serial/interrupt-controller/ethernet/mmc
                    if (depth >= 1 and depth < MAX_DEPTH and node_stack[depth - 1] == .soc) {
                        if (startsWith(name_ptr, "serial@")) break :classify .uart;
                        if (startsWith(name_ptr, "interrupt-controller@")) break :classify .plic;
                        if (startsWith(name_ptr, "ethernet@")) break :classify .ethernet;
                        if (startsWith(name_ptr, "mmc@")) break :classify .mmc;
                    }
                    break :classify .other;
                };

                if (depth < MAX_DEPTH) node_stack[depth] = kind;
                depth += 1;

                // Reset per-node property accumulators
                cur_compatible = null;
                cur_compatible_len = 0;
                cur_reg = null;
                cur_reg_len = 0;
            },

            FDT_END_NODE => {
                if (depth > 0) depth -= 1;

                if (depth < MAX_DEPTH) {
                    const kind = node_stack[depth];
                    const cells = if (depth > 0) cell_stack[depth - 1] else NodeContext{};

                    switch (kind) {
                        .memory => {
                            // Extract reg property using parent's cell sizes
                            if (cur_reg) |reg| {
                                const tuple_size = (cells.address_cells + cells.size_cells) * 4;
                                if (cur_reg_len >= tuple_size) {
                                    const base = readCells(reg, cells.address_cells);
                                    const size = readCells(reg + cells.address_cells * 4, cells.size_cells);
                                    if (fdt_config.ram_count < MAX_RAM_REGIONS) {
                                        fdt_config.ram_regions[fdt_config.ram_count] = .{ .base = base, .size = size };
                                        fdt_config.ram_count += 1;
                                    }
                                }
                            }
                        },
                        .uart => {
                            if (fdt_config.uart_base == 0) {
                                // Accept any 16550-compatible UART
                                const dominated = if (cur_compatible) |compat|
                                    compatibleContains(compat, cur_compatible_len, "snps,dw-apb-uart") or
                                        compatibleContains(compat, cur_compatible_len, "ns16550a") or
                                        compatibleContains(compat, cur_compatible_len, "ns16550")
                                else
                                    false;
                                if (dominated) {
                                    // Use reg property or fall back to node unit address
                                    if (cur_reg) |reg| {
                                        fdt_config.uart_base = readCells(reg, cells.address_cells);
                                    } else {
                                        fdt_config.uart_base = parseNodeAddr(name_stack[depth]);
                                    }
                                }
                            }
                        },
                        .plic => {
                            if (fdt_config.plic_base == 0) {
                                const is_plic = if (cur_compatible) |compat|
                                    compatibleContains(compat, cur_compatible_len, "sifive,plic-1.0.0") or
                                        compatibleContains(compat, cur_compatible_len, "riscv,plic0")
                                else
                                    false;
                                if (is_plic) {
                                    if (cur_reg) |reg| {
                                        fdt_config.plic_base = readCells(reg, cells.address_cells);
                                    } else {
                                        fdt_config.plic_base = parseNodeAddr(name_stack[depth]);
                                    }
                                }
                            }
                        },
                        .ethernet => {
                            if (fdt_config.ethernet_base == 0) {
                                const is_eth = if (cur_compatible) |compat|
                                    compatibleContains(compat, cur_compatible_len, "starfive,jh7110-dwmac") or
                                        compatibleContains(compat, cur_compatible_len, "snps,dwmac-5.10a") or
                                        compatibleContains(compat, cur_compatible_len, "snps,dwmac")
                                else
                                    false;
                                if (is_eth) {
                                    if (cur_reg) |reg| {
                                        fdt_config.ethernet_base = readCells(reg, cells.address_cells);
                                    } else {
                                        fdt_config.ethernet_base = parseNodeAddr(name_stack[depth]);
                                    }
                                }
                            }
                        },
                        .mmc => {
                            if (fdt_config.mmc_base == 0) {
                                const is_mmc = if (cur_compatible) |compat|
                                    compatibleContains(compat, cur_compatible_len, "starfive,jh7110-mmc") or
                                        compatibleContains(compat, cur_compatible_len, "snps,dw-mshc")
                                else
                                    false;
                                if (is_mmc) {
                                    if (cur_reg) |reg| {
                                        fdt_config.mmc_base = readCells(reg, cells.address_cells);
                                    } else {
                                        fdt_config.mmc_base = parseNodeAddr(name_stack[depth]);
                                    }
                                }
                            }
                        },
                        .cpu => {
                            // Accumulate hart — filter out non-rv64 harts below
                            if (fdt_config.cpu_count < MAX_CPUS) {
                                // Hart ID from reg property or unit address
                                var hartid: u32 = 0;
                                if (cur_reg) |reg| {
                                    hartid = @truncate(readCells(reg, cells.address_cells));
                                } else {
                                    hartid = @truncate(parseNodeAddr(name_stack[depth]));
                                }
                                // Check compatible — only accept riscv (or absence = assume ok)
                                var dominated = true;
                                if (cur_compatible) |compat| {
                                    dominated = compatibleContains(compat, cur_compatible_len, "riscv");
                                }
                                if (dominated) {
                                    fdt_config.cpu_harts[fdt_config.cpu_count] = hartid;
                                    fdt_config.cpu_count += 1;
                                }
                            }
                        },
                        else => {},
                    }
                    node_stack[depth] = .none;
                }
            },

            FDT_PROP => {
                if (offset + 8 > end_offset) return &fdt_config;
                const prop_len = readBe32(blob + offset);
                const name_off = readBe32(blob + offset + 4);
                offset += 8;

                const prop_data = blob + offset;
                const prop_name = getString(blob, off_dt_strings, name_off);

                if (depth > 0 and depth <= MAX_DEPTH) {
                    // Update cell sizes for current node
                    if (strEql(prop_name, "#address-cells") and prop_len == 4) {
                        cell_stack[depth - 1].address_cells = readBe32(prop_data);
                    } else if (strEql(prop_name, "#size-cells") and prop_len == 4) {
                        cell_stack[depth - 1].size_cells = readBe32(prop_data);
                    }

                    // Accumulate interesting properties
                    if (strEql(prop_name, "compatible")) {
                        cur_compatible = prop_data;
                        cur_compatible_len = prop_len;
                    } else if (strEql(prop_name, "reg")) {
                        cur_reg = prop_data;
                        cur_reg_len = prop_len;
                    }

                    // /cpus/timebase-frequency (directly under /cpus node)
                    if (depth - 1 < MAX_DEPTH and node_stack[depth - 1] == .cpus) {
                        if (strEql(prop_name, "timebase-frequency") and prop_len == 4) {
                            fdt_config.timer_freq = readBe32(prop_data);
                        }
                    }
                }

                offset = align4(offset + prop_len);
            },

            FDT_NOP => {},
            FDT_END => break,
            else => {
                klog.warn("FDT: unknown token 0x");
                klog.warnHex(@as(u64, token));
                klog.warn("\n");
                return &fdt_config;
            },
        }
    }

    return &fdt_config;
}

/// Legacy shim — returns first memory region (backward compatible with old callers).
pub fn probeMemory(dtb_addr: u64) ?MemoryRegion {
    const cfg = probe(dtb_addr);
    if (cfg.ram_count > 0) return cfg.ram_regions[0];
    return null;
}

/// Dump discovered FDT config to serial (debug aid).
pub fn dumpConfig() void {
    const cfg = &fdt_config;
    klog.info("FDT config:\n");

    if (cfg.uart_base != 0) {
        klog.info("  UART:     ");
        klog.infoHex(cfg.uart_base);
        klog.info("\n");
    }
    if (cfg.plic_base != 0) {
        klog.info("  PLIC:     ");
        klog.infoHex(cfg.plic_base);
        klog.info("\n");
    }
    if (cfg.timer_freq != 0) {
        klog.info("  Timebase: ");
        klog.infoDec(cfg.timer_freq);
        klog.info(" Hz\n");
    }
    for (0..cfg.ram_count) |i| {
        klog.info("  RAM[");
        klog.infoDec(i);
        klog.info("]:   ");
        klog.infoHex(cfg.ram_regions[i].base);
        klog.info(" size ");
        klog.infoDec(cfg.ram_regions[i].size / (1024 * 1024));
        klog.info(" MB\n");
    }
    if (cfg.cpu_count > 0) {
        klog.info("  CPUs:     ");
        klog.infoDec(cfg.cpu_count);
        klog.info(" hart(s):");
        for (0..cfg.cpu_count) |i| {
            klog.info(" ");
            klog.infoDec(cfg.cpu_harts[i]);
        }
        klog.info("\n");
    }
    if (cfg.ethernet_base != 0) {
        klog.info("  Ethernet: ");
        klog.infoHex(cfg.ethernet_base);
        klog.info("\n");
    }
    if (cfg.mmc_base != 0) {
        klog.info("  MMC:      ");
        klog.infoHex(cfg.mmc_base);
        klog.info("\n");
    }
}
