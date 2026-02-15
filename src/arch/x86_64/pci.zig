/// PCI configuration space access for x86_64.
///
/// Uses I/O ports 0xCF8 (CONFIG_ADDRESS) and 0xCFC (CONFIG_DATA).
/// Enumerates bus 0 to discover devices. Sufficient for QEMU which
/// puts all devices on bus 0.
const cpu = @import("cpu.zig");
const console = @import("../../console.zig");
const serial = @import("../../serial.zig");

const CONFIG_ADDRESS: u16 = 0x0CF8;
const CONFIG_DATA: u16 = 0x0CFC;

pub const MAX_DEVICES = 32;

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

/// Read a 32-bit value from PCI configuration space.
pub fn configRead(bus: u8, slot: u8, func: u8, offset: u8) u32 {
    const address: u32 = @as(u32, 1) << 31 | // enable bit
        @as(u32, bus) << 16 |
        @as(u32, slot) << 11 |
        @as(u32, func) << 8 |
        (@as(u32, offset) & 0xFC);

    cpu.outb(CONFIG_ADDRESS, @truncate(address));
    cpu.outb(CONFIG_ADDRESS + 1, @truncate(address >> 8));
    cpu.outb(CONFIG_ADDRESS + 2, @truncate(address >> 16));
    cpu.outb(CONFIG_ADDRESS + 3, @truncate(address >> 24));

    const b0: u32 = cpu.inb(CONFIG_DATA);
    const b1: u32 = cpu.inb(CONFIG_DATA + 1);
    const b2: u32 = cpu.inb(CONFIG_DATA + 2);
    const b3: u32 = cpu.inb(CONFIG_DATA + 3);
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
}

/// Write a 32-bit value to PCI configuration space.
pub fn configWrite(bus: u8, slot: u8, func: u8, offset: u8, value: u32) void {
    const address: u32 = @as(u32, 1) << 31 |
        @as(u32, bus) << 16 |
        @as(u32, slot) << 11 |
        @as(u32, func) << 8 |
        (@as(u32, offset) & 0xFC);

    cpu.outb(CONFIG_ADDRESS, @truncate(address));
    cpu.outb(CONFIG_ADDRESS + 1, @truncate(address >> 8));
    cpu.outb(CONFIG_ADDRESS + 2, @truncate(address >> 16));
    cpu.outb(CONFIG_ADDRESS + 3, @truncate(address >> 24));

    cpu.outb(CONFIG_DATA, @truncate(value));
    cpu.outb(CONFIG_DATA + 1, @truncate(value >> 8));
    cpu.outb(CONFIG_DATA + 2, @truncate(value >> 16));
    cpu.outb(CONFIG_DATA + 3, @truncate(value >> 24));
}

/// Read a 16-bit value from PCI config (reads 32 bits, extracts the right half).
pub fn configRead16(bus: u8, slot: u8, func: u8, offset: u8) u16 {
    const val = configRead(bus, slot, func, offset & 0xFC);
    if (offset & 2 != 0) {
        return @truncate(val >> 16);
    }
    return @truncate(val);
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

var devices: [MAX_DEVICES]PciDevice = undefined;
var device_count: u8 = 0;

/// Enumerate PCI bus 0 and discover all devices.
pub fn enumerate() void {
    device_count = 0;
    serial.puts("PCI: scanning bus 0...\n");

    for (0..32) |slot_usize| {
        const slot: u8 = @intCast(slot_usize);
        const vendor_id = configRead16(0, slot, 0, 0x00);

        if (vendor_id == 0xFFFF) continue; // No device

        if (device_count >= MAX_DEVICES) break;

        const device_id = configRead16(0, slot, 0, 0x02);
        const class_rev = configRead(0, slot, 0, 0x08);
        const header_type = configRead8(0, slot, 0, 0x0E);
        const interrupt = configRead(0, slot, 0, 0x3C);

        var dev = &devices[device_count];
        dev.bus = 0;
        dev.slot = slot;
        dev.func = 0;
        dev.vendor_id = vendor_id;
        dev.device_id = device_id;
        dev.revision = @truncate(class_rev);
        dev.prog_if = @truncate(class_rev >> 8);
        dev.subclass = @truncate(class_rev >> 16);
        dev.class_code = @truncate(class_rev >> 24);
        dev.header_type = header_type & 0x7F;
        dev.interrupt_line = @truncate(interrupt);
        dev.interrupt_pin = @truncate(interrupt >> 8);

        // Read BARs (only for header type 0)
        for (0..6) |i| {
            if (dev.header_type == 0) {
                dev.bar[i] = configRead(0, slot, 0, @intCast(0x10 + i * 4));
            } else {
                dev.bar[i] = 0;
            }
        }

        serial.puts("  [");
        serial.putDec(slot_usize);
        serial.puts("] ");
        serial.putHex(vendor_id);
        serial.puts(":");
        serial.putHex(device_id);
        serial.puts(" class=");
        serial.putHex(dev.class_code);
        serial.puts(":");
        serial.putHex(dev.subclass);
        if (dev.isVirtioNet()) {
            serial.puts(" (virtio-net)");
        } else if (dev.isVirtio()) {
            serial.puts(" (virtio)");
        }
        serial.puts("\n");

        device_count += 1;
    }

    console.puts("PCI: found ");
    console.putDec(device_count);
    console.puts(" devices\n");
}

/// Find the first device matching a vendor/device ID pair.
pub fn findDevice(vendor_id: u16, device_id: u16) ?*PciDevice {
    for (0..device_count) |i| {
        if (devices[i].vendor_id == vendor_id and devices[i].device_id == device_id) {
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

/// Get all discovered devices.
pub fn getDevices() []PciDevice {
    return devices[0..device_count];
}
