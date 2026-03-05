// IOAPIC driver — routes PCI and legacy interrupts via redirection table entries.
// IOAPIC MMIO base is discovered from MADT and mapped into higher-half.

const mem = @import("../../mem.zig");
const klog = @import("../../klog.zig");
const apic = @import("apic.zig");

// IOAPIC registers (indirect access via IOREGSEL/IOWIN)
const IOREGSEL: u32 = 0x00;
const IOWIN: u32 = 0x10;

// IOAPIC register indices
const IOAPIC_ID: u32 = 0x00;
const IOAPIC_VER: u32 = 0x01;
const IOAPIC_ARB: u32 = 0x02;
const IOAPIC_REDTBL_BASE: u32 = 0x10; // Each entry is 2 DWORDs (low + high)

// Redirection table entry bits
const MASKED: u64 = 1 << 16;
const LEVEL_TRIGGER: u64 = 1 << 15;
const ACTIVE_LOW: u64 = 1 << 13;
const LOGICAL_DEST: u64 = 1 << 11;

// MADT interrupt source override tracking
const MAX_OVERRIDES = 16;

pub const IrqOverride = struct {
    bus: u8,
    source: u8, // ISA IRQ
    gsi: u32,
    flags: u16, // polarity/trigger from MADT
};

var overrides: [MAX_OVERRIDES]IrqOverride = undefined;
var override_count: u8 = 0;

var ioapic_virt: u64 = 0;
var ioapic_gsi_base: u32 = 0;
var max_redir_entries: u8 = 0;
var initialized: bool = false;

fn regRead(index: u32) u32 {
    const sel: *volatile u32 = @ptrFromInt(ioapic_virt + IOREGSEL);
    const win: *volatile u32 = @ptrFromInt(ioapic_virt + IOWIN);
    sel.* = index;
    return win.*;
}

fn regWrite(index: u32, value: u32) void {
    const sel: *volatile u32 = @ptrFromInt(ioapic_virt + IOREGSEL);
    const win: *volatile u32 = @ptrFromInt(ioapic_virt + IOWIN);
    sel.* = index;
    win.* = value;
}

pub fn init(ioapic_phys: u64, gsi_base: u32) void {
    ioapic_virt = ioapic_phys +% mem.KERNEL_VIRT_BASE;
    ioapic_gsi_base = gsi_base;

    const ver = regRead(IOAPIC_VER);
    max_redir_entries = @truncate((ver >> 16) & 0xFF);
    const ioapic_id = (regRead(IOAPIC_ID) >> 24) & 0x0F;

    klog.info("IOAPIC: ID=");
    klog.infoHex(ioapic_id);
    klog.info(" ver=");
    klog.infoHex(ver & 0xFF);
    klog.info(" entries=");
    klog.infoDec(@as(u64, max_redir_entries) + 1);
    klog.info(" GSI base=");
    klog.infoDec(@as(u64, gsi_base));
    klog.info("\n");

    // Mask all entries by default
    var i: u8 = 0;
    while (i <= max_redir_entries) : (i += 1) {
        maskIrq(gsi_base + i);
    }

    initialized = true;
}

/// Program a redirection table entry to route a GSI to a LAPIC vector.
pub fn routeIrq(gsi: u32, vector: u8, dest_apic_id: u8, level_triggered: bool, active_low: bool) void {
    if (!initialized) return;
    if (gsi < ioapic_gsi_base) return;
    const entry_idx = gsi - ioapic_gsi_base;
    if (entry_idx > max_redir_entries) return;

    var redir: u64 = @as(u64, vector);
    // Physical destination mode, fixed delivery
    if (level_triggered) redir |= LEVEL_TRIGGER;
    if (active_low) redir |= ACTIVE_LOW;
    // Destination APIC ID in bits 56-63
    redir |= @as(u64, dest_apic_id) << 56;
    // Not masked (bit 16 = 0)

    const reg_lo = IOAPIC_REDTBL_BASE + entry_idx * 2;
    const reg_hi = reg_lo + 1;
    regWrite(reg_hi, @truncate(redir >> 32));
    regWrite(reg_lo, @truncate(redir));
}

/// Mask a GSI (disable interrupt delivery).
pub fn maskIrq(gsi: u32) void {
    if (!initialized) return;
    if (gsi < ioapic_gsi_base) return;
    const entry_idx = gsi - ioapic_gsi_base;
    if (entry_idx > max_redir_entries) return;

    const reg_lo = IOAPIC_REDTBL_BASE + entry_idx * 2;
    var lo = regRead(reg_lo);
    lo |= @as(u32, 1) << 16;
    regWrite(reg_lo, lo);
}

/// Unmask a GSI (enable interrupt delivery).
pub fn unmaskIrq(gsi: u32) void {
    if (!initialized) return;
    if (gsi < ioapic_gsi_base) return;
    const entry_idx = gsi - ioapic_gsi_base;
    if (entry_idx > max_redir_entries) return;

    const reg_lo = IOAPIC_REDTBL_BASE + entry_idx * 2;
    var lo = regRead(reg_lo);
    lo &= ~(@as(u32, 1) << 16);
    regWrite(reg_lo, lo);
}

/// Record a MADT interrupt source override entry.
pub fn addOverride(bus: u8, source: u8, gsi: u32, flags: u16) void {
    if (override_count >= MAX_OVERRIDES) return;
    overrides[override_count] = .{
        .bus = bus,
        .source = source,
        .gsi = gsi,
        .flags = flags,
    };
    override_count += 1;

    klog.info("IOAPIC: override ISA IRQ ");
    klog.infoDec(@as(u64, source));
    klog.info(" -> GSI ");
    klog.infoDec(@as(u64, gsi));
    klog.info("\n");
}

/// Resolve an ISA IRQ to its GSI, accounting for source overrides.
pub fn isaToGsi(irq: u8) u32 {
    var i: u8 = 0;
    while (i < override_count) : (i += 1) {
        if (overrides[i].source == irq) {
            return overrides[i].gsi;
        }
    }
    // No override — identity mapping
    return @as(u32, irq);
}

/// Get trigger/polarity flags for a GSI from its override entry.
/// Returns (level_triggered, active_low).
pub fn getOverrideFlags(gsi: u32) struct { level: bool, low: bool } {
    var i: u8 = 0;
    while (i < override_count) : (i += 1) {
        if (overrides[i].gsi == gsi) {
            const flags = overrides[i].flags;
            // MADT flags: bits 0-1 = polarity (0=bus default, 1=active high, 3=active low)
            //             bits 2-3 = trigger  (0=bus default, 1=edge, 3=level)
            const polarity = flags & 0x03;
            const trigger = (flags >> 2) & 0x03;
            return .{
                .level = trigger == 3,
                .low = polarity == 3,
            };
        }
    }
    // ISA default: edge-triggered, active-high
    return .{ .level = false, .low = false };
}

pub fn isInitialized() bool {
    return initialized;
}
