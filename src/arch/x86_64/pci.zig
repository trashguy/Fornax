/// PCI configuration space access for x86_64.
///
/// Uses I/O ports 0xCF8 (CONFIG_ADDRESS) and 0xCFC (CONFIG_DATA).
/// Enumerates all PCI buses via bridge traversal, supports multi-function
/// devices, BAR size probing, capabilities list, and MSI-X detection.
const cpu = @import("cpu.zig");
const klog = @import("../../klog.zig");

const CONFIG_ADDRESS: u16 = 0x0CF8;
const CONFIG_DATA: u16 = 0x0CFC;

pub const MAX_DEVICES = 64;

const MAX_BUS_DEPTH = 8;
const MAX_CAP_WALK = 48;

pub const MsixCapability = struct {
    cap_offset: u8,
    table_size: u16,
    table_bar: u3,
    table_offset: u32,
    pba_bar: u3,
    pba_offset: u32,
};

/// A discovered PCI device.
pub const PciDevice = struct {
    bus: u8,
    slot: u8,
    func: u8,
    vendor_id: u16,
    device_id: u16,
    class_code: u8,
    subclass: u8,
    prog_if: u8,
    revision: u8,
    header_type: u8,
    interrupt_line: u8,
    interrupt_pin: u8,
    bar: [6]u32,
    bar_size: [6]u64,
    msix: ?MsixCapability,

    /// Check if this is a virtio device (vendor 0x1AF4).
    pub fn isVirtio(self: *const PciDevice) bool {
        return self.vendor_id == 0x1AF4;
    }

    /// Check if this is a virtio-net device.
    /// Legacy device ID 0x1000 or modern 0x1041.
    pub fn isVirtioNet(self: *const PciDevice) bool {
        return self.vendor_id == 0x1AF4 and
            (self.device_id == 0x1000 or self.device_id == 0x1041);
    }

    /// Check if this is a virtio-blk device.
    /// Legacy device ID 0x1001 or modern 0x1042.
    pub fn isVirtioBlk(self: *const PciDevice) bool {
        return self.vendor_id == 0x1AF4 and
            (self.device_id == 0x1001 or self.device_id == 0x1042);
    }

    /// Check if this is an xHCI USB 3.0 controller (class 0x0C, subclass 0x03, prog_if 0x30).
    pub fn isXhci(self: *const PciDevice) bool {
        return self.class_code == 0x0C and self.subclass == 0x03 and self.prog_if == 0x30;
    }

    pub fn isNvme(self: *const PciDevice) bool {
        return self.class_code == 0x01 and self.subclass == 0x08 and self.prog_if == 0x02;
    }

    pub fn isAhci(self: *const PciDevice) bool {
        return self.class_code == 0x01 and self.subclass == 0x06 and self.prog_if == 0x01;
    }

    /// Get the I/O port base from BAR0 (for legacy virtio devices).
    pub fn ioBase(self: *const PciDevice) ?u16 {
        const bar0 = self.bar[0];
        if (bar0 & 1 == 1) {
            // I/O space BAR
            return @truncate(bar0 & 0xFFFC);
        }
        return null; // Memory-mapped BAR, not I/O
    }

    /// Get the memory base from a BAR (for MMIO devices).
    pub fn memBase(self: *const PciDevice, bar_index: u3) ?u64 {
        const bar = self.bar[bar_index];
        if (bar & 1 == 0) {
            // Memory space BAR
            const base: u64 = bar & 0xFFFFFFF0;
            // Check if 64-bit BAR (type bits [2:1] == 0b10)
            if ((bar >> 1) & 3 == 2 and bar_index < 5) {
                return base | (@as(u64, self.bar[bar_index + 1]) << 32);
            }
            return base;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Configuration space access
// ---------------------------------------------------------------------------

/// Read a 32-bit value from PCI configuration space.
pub fn configRead(bus: u8, slot: u8, func: u8, offset: u8) u32 {
    const address: u32 = @as(u32, 1) << 31 | // enable bit
        @as(u32, bus) << 16 |
        @as(u32, slot) << 11 |
        @as(u32, func) << 8 |
        (@as(u32, offset) & 0xFC);

    cpu.outl(CONFIG_ADDRESS, address);
    return cpu.inl(CONFIG_DATA);
}

/// Write a 32-bit value to PCI configuration space.
pub fn configWrite(bus: u8, slot: u8, func: u8, offset: u8, value: u32) void {
    const address: u32 = @as(u32, 1) << 31 |
        @as(u32, bus) << 16 |
        @as(u32, slot) << 11 |
        @as(u32, func) << 8 |
        (@as(u32, offset) & 0xFC);

    cpu.outl(CONFIG_ADDRESS, address);
    cpu.outl(CONFIG_DATA, value);
}

/// Read a 16-bit value from PCI config (reads 32 bits, extracts the right half).
pub fn configRead16(bus: u8, slot: u8, func: u8, offset: u8) u16 {
    const val = configRead(bus, slot, func, offset & 0xFC);
    if (offset & 2 != 0) {
        return @truncate(val >> 16);
    }
    return @truncate(val);
}

/// Write a 16-bit value to PCI config via read-modify-write on 32-bit register.
pub fn configWrite16(bus: u8, slot: u8, func: u8, offset: u8, value: u16) void {
    const aligned = offset & 0xFC;
    var dword = configRead(bus, slot, func, aligned);
    if (offset & 2 != 0) {
        dword = (dword & 0x0000FFFF) | (@as(u32, value) << 16);
    } else {
        dword = (dword & 0xFFFF0000) | @as(u32, value);
    }
    configWrite(bus, slot, func, aligned, dword);
}

/// Read an 8-bit value from PCI config.
pub fn configRead8(bus: u8, slot: u8, func: u8, offset: u8) u8 {
    const val = configRead(bus, slot, func, offset & 0xFC);
    const shift: u5 = @intCast((offset & 3) * 8);
    return @truncate(val >> shift);
}

/// Enable bus mastering for a PCI device (required for DMA).
pub fn enableBusMastering(dev: *const PciDevice) void {
    const command = configRead16(dev.bus, dev.slot, dev.func, 0x04);
    // Set bit 2 (Bus Master) and bit 0 (I/O Space) and bit 1 (Memory Space)
    const new_command: u32 = @as(u32, command) | 0x07;
    configWrite(dev.bus, dev.slot, dev.func, 0x04, new_command);
}

// ---------------------------------------------------------------------------
// BAR size probing
// ---------------------------------------------------------------------------

/// Probe the size of a BAR by writing all-ones and reading back the mask.
/// Returns the size in bytes, or 0 if the BAR is not implemented.
pub fn probeBarSize(bus: u8, slot: u8, func: u8, bar_index: u3) u64 {
    const bar_offset: u8 = 0x10 + @as(u8, bar_index) * 4;

    // Save original BAR and command register
    const orig_bar = configRead(bus, slot, func, bar_offset);
    const orig_cmd = configRead16(bus, slot, func, 0x04);

    // Disable Memory Space + I/O Space to prevent spurious decode
    configWrite16(bus, slot, func, 0x04, orig_cmd & ~@as(u16, 0x03));

    // Write all-ones to BAR
    configWrite(bus, slot, func, bar_offset, 0xFFFFFFFF);
    const mask_lo = configRead(bus, slot, func, bar_offset);

    // Restore original BAR
    configWrite(bus, slot, func, bar_offset, orig_bar);

    if (mask_lo == 0 or mask_lo == 0xFFFFFFFF) {
        // Restore command register
        configWrite16(bus, slot, func, 0x04, orig_cmd);
        return 0;
    }

    var size: u64 = 0;

    if (orig_bar & 1 == 1) {
        // I/O BAR: size from lower 16 bits, mask off bottom 2 bits
        const io_mask = mask_lo & 0xFFFC;
        if (io_mask == 0) {
            configWrite16(bus, slot, func, 0x04, orig_cmd);
            return 0;
        }
        size = @as(u64, (~io_mask & 0xFFFF) + 1) & 0xFFFF;
    } else {
        // Memory BAR
        const is_64bit = ((orig_bar >> 1) & 3) == 2;
        const mem_mask_lo: u64 = mask_lo & 0xFFFFFFF0;

        if (is_64bit and bar_index < 5) {
            const next_offset: u8 = bar_offset + 4;
            const orig_bar_hi = configRead(bus, slot, func, next_offset);
            configWrite(bus, slot, func, next_offset, 0xFFFFFFFF);
            const mask_hi: u64 = configRead(bus, slot, func, next_offset);
            configWrite(bus, slot, func, next_offset, orig_bar_hi);

            const full_mask = (mask_hi << 32) | mem_mask_lo;
            size = (~full_mask) +% 1;
        } else {
            if (mem_mask_lo == 0) {
                configWrite16(bus, slot, func, 0x04, orig_cmd);
                return 0;
            }
            size = (~mem_mask_lo & 0xFFFFFFFF) + 1;
        }
    }

    // Restore command register
    configWrite16(bus, slot, func, 0x04, orig_cmd);
    return size;
}

// ---------------------------------------------------------------------------
// PCI capabilities list
// ---------------------------------------------------------------------------

/// Walk the PCI capabilities linked list to find a capability by ID.
/// Returns the config space offset of the capability, or null if not found.
pub fn findCapability(bus: u8, slot: u8, func: u8, cap_id: u8) ?u8 {
    // Check status register bit 4 (capabilities list present)
    const status = configRead16(bus, slot, func, 0x06);
    if (status & (1 << 4) == 0) return null;

    // Read capabilities pointer at offset 0x34, mask to dword-aligned
    var ptr = configRead8(bus, slot, func, 0x34) & 0xFC;
    var count: u32 = 0;

    while (ptr != 0 and count < MAX_CAP_WALK) : (count += 1) {
        const id = configRead8(bus, slot, func, ptr);
        if (id == cap_id) return ptr;
        ptr = configRead8(bus, slot, func, ptr + 1) & 0xFC;
    }

    return null;
}

/// Parse an MSI-X capability structure at the given config space offset.
pub fn parseMsixCap(bus: u8, slot: u8, func: u8, cap_offset: u8) MsixCapability {
    // Message control at cap_offset + 2
    const msg_ctrl = configRead16(bus, slot, func, cap_offset + 2);
    const table_size: u16 = (msg_ctrl & 0x7FF) + 1;

    // Table offset/BIR at cap_offset + 4
    const table_dword = configRead(bus, slot, func, cap_offset + 4);
    const table_bar: u3 = @truncate(table_dword & 0x07);
    const table_offset: u32 = table_dword & 0xFFFFFFF8;

    // PBA offset/BIR at cap_offset + 8
    const pba_dword = configRead(bus, slot, func, cap_offset + 8);
    const pba_bar: u3 = @truncate(pba_dword & 0x07);
    const pba_offset: u32 = pba_dword & 0xFFFFFFF8;

    return .{
        .cap_offset = cap_offset,
        .table_size = table_size,
        .table_bar = table_bar,
        .table_offset = table_offset,
        .pba_bar = pba_bar,
        .pba_offset = pba_offset,
    };
}

// ---------------------------------------------------------------------------
// Enumeration
// ---------------------------------------------------------------------------

var devices: [MAX_DEVICES]PciDevice = undefined;
var device_count: u8 = 0;

/// Enumerate all PCI buses and discover devices.
pub fn enumerate() void {
    device_count = 0;
    klog.debug("PCI: scanning buses...\n");
    scanBus(0, 0);

    klog.info("PCI: found ");
    klog.infoDec(device_count);
    klog.info(" devices\n");
}

fn scanBus(bus: u8, depth: u8) void {
    if (depth >= MAX_BUS_DEPTH) return;

    for (0..32) |slot_usize| {
        const slot: u8 = @intCast(slot_usize);
        const vendor_id = configRead16(bus, slot, 0, 0x00);
        if (vendor_id == 0xFFFF) continue;

        const ht = configRead8(bus, slot, 0, 0x0E);
        const is_multifunction = (ht & 0x80) != 0;
        const max_func: u8 = if (is_multifunction) 8 else 1;

        for (0..max_func) |func_usize| {
            const func: u8 = @intCast(func_usize);

            // Function 0 vendor already checked above
            if (func != 0) {
                const fv = configRead16(bus, slot, func, 0x00);
                if (fv == 0xFFFF) continue;
            }

            scanFunction(bus, slot, func, depth);
        }
    }
}

fn scanFunction(bus: u8, slot: u8, func: u8, depth: u8) void {
    if (device_count >= MAX_DEVICES) return;

    const vendor_id = configRead16(bus, slot, func, 0x00);
    const device_id = configRead16(bus, slot, func, 0x02);
    const class_rev = configRead(bus, slot, func, 0x08);
    const header_type = configRead8(bus, slot, func, 0x0E) & 0x7F;
    const interrupt = configRead(bus, slot, func, 0x3C);

    var dev = &devices[device_count];
    dev.bus = bus;
    dev.slot = slot;
    dev.func = func;
    dev.vendor_id = vendor_id;
    dev.device_id = device_id;
    dev.revision = @truncate(class_rev);
    dev.prog_if = @truncate(class_rev >> 8);
    dev.subclass = @truncate(class_rev >> 16);
    dev.class_code = @truncate(class_rev >> 24);
    dev.header_type = header_type;
    dev.interrupt_line = @truncate(interrupt);
    dev.interrupt_pin = @truncate(interrupt >> 8);

    // Read BARs and probe sizes (only for header type 0 — endpoints)
    for (0..6) |i| {
        if (header_type == 0) {
            dev.bar[i] = configRead(bus, slot, func, @intCast(0x10 + i * 4));
            dev.bar_size[i] = probeBarSize(bus, slot, func, @intCast(i));
        } else {
            dev.bar[i] = 0;
            dev.bar_size[i] = 0;
        }
    }

    // Check for MSI-X capability (ID 0x11)
    if (findCapability(bus, slot, func, 0x11)) |cap_off| {
        dev.msix = parseMsixCap(bus, slot, func, cap_off);
    } else {
        dev.msix = null;
    }

    // Enable Memory Space + Bus Master for all endpoint devices.
    // VFIO passthrough / FLR can leave these disabled, causing BAR
    // reads to return 0xFFFFFFFF.
    if (header_type == 0) {
        enableBusMastering(dev);
    }

    klog.debug("  ");
    klog.debugHex(bus);
    klog.debug(":");
    klog.debugHex(slot);
    klog.debug(".");
    klog.debugDec(func);
    klog.debug(" ");
    klog.debugHex(vendor_id);
    klog.debug(":");
    klog.debugHex(device_id);
    klog.debug(" class=");
    klog.debugHex(dev.class_code);
    klog.debug(":");
    klog.debugHex(dev.subclass);
    if (dev.isVirtioNet()) {
        klog.debug(" (virtio-net)");
    } else if (dev.isVirtio()) {
        klog.debug(" (virtio)");
    }
    if (dev.msix) |mx| {
        klog.debug(" MSI-X:");
        klog.debugDec(mx.table_size);
    }
    klog.debug("\n");

    device_count += 1;

    // If this is a PCI-to-PCI bridge (header type 1), recurse into secondary bus
    if (header_type == 1) {
        const secondary_bus = configRead8(bus, slot, func, 0x19);
        if (secondary_bus != 0) {
            klog.debug("PCI: bridge -> bus ");
            klog.debugDec(secondary_bus);
            klog.debug("\n");
            scanBus(secondary_bus, depth + 1);
        }
    }
}

// ---------------------------------------------------------------------------
// Device lookup
// ---------------------------------------------------------------------------

/// Find the first device matching a vendor/device ID pair.
pub fn findDevice(vendor_id: u16, device_id: u16) ?*PciDevice {
    for (0..device_count) |i| {
        if (devices[i].vendor_id == vendor_id and devices[i].device_id == device_id) {
            return &devices[i];
        }
    }
    return null;
}

/// Find the first device matching a class/subclass (and optionally prog_if).
pub fn findByClass(class: u8, subclass: u8, prog_if: ?u8) ?*PciDevice {
    for (0..device_count) |i| {
        if (devices[i].class_code == class and devices[i].subclass == subclass) {
            if (prog_if) |pif| {
                if (devices[i].prog_if != pif) continue;
            }
            return &devices[i];
        }
    }
    return null;
}

/// Find the first virtio-net device.
pub fn findVirtioNet() ?*PciDevice {
    for (0..device_count) |i| {
        if (devices[i].isVirtioNet()) return &devices[i];
    }
    return null;
}

pub fn findVirtioBlk() ?*PciDevice {
    for (0..device_count) |i| {
        if (devices[i].isVirtioBlk()) return &devices[i];
    }
    return null;
}

pub fn findXhci() ?*PciDevice {
    for (0..device_count) |i| {
        if (devices[i].isXhci()) return &devices[i];
    }
    return null;
}

pub fn findNvme() ?*PciDevice {
    for (0..device_count) |i| {
        if (devices[i].isNvme()) return &devices[i];
    }
    return null;
}

pub fn findAhci() ?*PciDevice {
    for (0..device_count) |i| {
        if (devices[i].isAhci()) return &devices[i];
    }
    return null;
}

/// Get all discovered devices.
pub fn getDevices() []PciDevice {
    return devices[0..device_count];
}

const mem = @import("../../mem.zig");

/// MSI-X table entry layout (16 bytes per entry, MMIO).
const MsixTableEntry = extern struct {
    msg_addr_lo: u32 align(1),
    msg_addr_hi: u32 align(1),
    msg_data: u32 align(1),
    vector_control: u32 align(1),
};

/// Enable MSI-X on a device for a single table entry (entry 0).
/// Configures the MSI-X table to deliver the given vector to the given LAPIC ID.
/// Disables legacy INTx in the PCI command register.
/// Returns false if the device has no MSI-X capability or the BAR is unmappable.
pub fn enableMsix(dev: *const PciDevice, vector: u8, dest_apic_id: u8) bool {
    const msix_cap = dev.msix orelse return false;

    // Get physical base of the BAR containing the MSI-X table
    const bar_phys = dev.memBase(msix_cap.table_bar) orelse return false;
    const table_phys = bar_phys + msix_cap.table_offset;
    const table_virt = table_phys +% mem.KERNEL_VIRT_BASE;

    // Write entry 0: message address, message data, unmask
    const entry: *volatile MsixTableEntry = @ptrFromInt(table_virt);
    // Message address: 0xFEE00000 | (dest_apic_id << 12), physical destination mode
    entry.msg_addr_lo = 0xFEE00000 | (@as(u32, dest_apic_id) << 12);
    entry.msg_addr_hi = 0;
    // Message data: vector number, fixed delivery mode
    entry.msg_data = @as(u32, vector);
    // Unmask this entry (clear bit 0 of vector_control)
    entry.vector_control = 0;

    // Enable MSI-X in the message control register (bit 15)
    const msg_ctrl = configRead16(dev.bus, dev.slot, dev.func, msix_cap.cap_offset + 2);
    configWrite16(dev.bus, dev.slot, dev.func, msix_cap.cap_offset + 2, msg_ctrl | (1 << 15));

    // Disable legacy INTx: set bit 10 in PCI command register
    const command = configRead16(dev.bus, dev.slot, dev.func, 0x04);
    configWrite16(dev.bus, dev.slot, dev.func, 0x04, command | (1 << 10));

    klog.info("PCI: MSI-X enabled ");
    klog.infoHex(dev.bus);
    klog.info(":");
    klog.infoHex(dev.slot);
    klog.info(".");
    klog.infoHex(dev.func);
    klog.info(" vec=");
    klog.infoDec(vector);
    klog.info(" dest=");
    klog.infoDec(dest_apic_id);
    klog.info("\n");

    return true;
}

/// Enable a specific MSI-X table entry (for devices with multiple interrupt sources).
pub fn enableMsixEntry(dev: *const PciDevice, entry_index: u16, vector: u8, dest_apic_id: u8) bool {
    const msix_cap = dev.msix orelse return false;
    if (entry_index >= msix_cap.table_size) return false;

    const bar_phys = dev.memBase(msix_cap.table_bar) orelse return false;
    const table_phys = bar_phys + msix_cap.table_offset;
    const table_virt = table_phys +% mem.KERNEL_VIRT_BASE;

    const entry: *volatile MsixTableEntry = @ptrFromInt(table_virt + @as(u64, entry_index) * 16);
    entry.msg_addr_lo = 0xFEE00000 | (@as(u32, dest_apic_id) << 12);
    entry.msg_addr_hi = 0;
    entry.msg_data = @as(u32, vector);
    entry.vector_control = 0;

    // Ensure MSI-X is globally enabled
    const msg_ctrl = configRead16(dev.bus, dev.slot, dev.func, msix_cap.cap_offset + 2);
    if (msg_ctrl & (1 << 15) == 0) {
        configWrite16(dev.bus, dev.slot, dev.func, msix_cap.cap_offset + 2, msg_ctrl | (1 << 15));
        // Disable legacy INTx
        const command = configRead16(dev.bus, dev.slot, dev.func, 0x04);
        configWrite16(dev.bus, dev.slot, dev.func, 0x04, command | (1 << 10));
    }

    return true;
}

/// Disable MSI-X on a device: mask all entries and clear the enable bit.
pub fn disableMsix(dev: *const PciDevice) void {
    const msix_cap = dev.msix orelse return;

    // Clear MSI-X enable bit (bit 15 of message control)
    const msg_ctrl = configRead16(dev.bus, dev.slot, dev.func, msix_cap.cap_offset + 2);
    configWrite16(dev.bus, dev.slot, dev.func, msix_cap.cap_offset + 2, msg_ctrl & ~@as(u16, 1 << 15));

    // Re-enable legacy INTx: clear bit 10 in PCI command register
    const command = configRead16(dev.bus, dev.slot, dev.func, 0x04);
    configWrite16(dev.bus, dev.slot, dev.func, 0x04, command & ~@as(u16, 1 << 10));
}
