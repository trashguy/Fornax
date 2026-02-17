/// PCI ECAM (Enhanced Configuration Access Mechanism) for RISC-V.
///
/// QEMU virt machine ECAM base: 0x30000000
/// Address formula: base + (bus<<20 | slot<<15 | func<<12 | offset)
const klog = @import("../../klog.zig");
const mem = @import("../../mem.zig");
const paging = @import("paging.zig");

const ECAM_BASE: u64 = 0x3000_0000;

pub const MAX_DEVICES = 32;

/// A discovered PCI device (identical to x86_64 version).
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

    pub fn isVirtio(self: *const PciDevice) bool {
        return self.vendor_id == 0x1AF4;
    }

    pub fn isVirtioNet(self: *const PciDevice) bool {
        return self.vendor_id == 0x1AF4 and
            (self.device_id == 0x1000 or self.device_id == 0x1041);
    }

    pub fn isVirtioBlk(self: *const PciDevice) bool {
        return self.vendor_id == 0x1AF4 and
            (self.device_id == 0x1001 or self.device_id == 0x1042);
    }

    pub fn isXhci(self: *const PciDevice) bool {
        return self.class_code == 0x0C and self.subclass == 0x03 and self.prog_if == 0x30;
    }

    pub fn ioBase(self: *const PciDevice) ?u16 {
        const bar0 = self.bar[0];
        if (bar0 & 1 == 1) {
            return @truncate(bar0 & 0xFFFC);
        }
        return null;
    }

    pub fn memBase(self: *const PciDevice, bar_index: u3) ?u64 {
        const bar = self.bar[bar_index];
        if (bar & 1 == 0) {
            const base: u64 = bar & 0xFFFFFFF0;
            if ((bar >> 1) & 3 == 2 and bar_index < 5) {
                return base | (@as(u64, self.bar[bar_index + 1]) << 32);
            }
            return base;
        }
        return null;
    }
};

/// Get the effective ECAM address for a config register.
inline fn ecamAddr(bus: u8, slot: u8, func: u8, offset: u8) u64 {
    const addr = ECAM_BASE +
        (@as(u64, bus) << 20) |
        (@as(u64, slot) << 15) |
        (@as(u64, func) << 12) |
        @as(u64, offset);
    return if (paging.isInitialized()) addr +% mem.KERNEL_VIRT_BASE else addr;
}

/// Read a 32-bit value from PCI configuration space via ECAM MMIO.
pub fn configRead(bus: u8, slot: u8, func: u8, offset: u8) u32 {
    const addr = ecamAddr(bus, slot, func, offset & 0xFC);
    return @as(*volatile u32, @ptrFromInt(addr)).*;
}

/// Write a 32-bit value to PCI configuration space via ECAM MMIO.
pub fn configWrite(bus: u8, slot: u8, func: u8, offset: u8, value: u32) void {
    const addr = ecamAddr(bus, slot, func, offset & 0xFC);
    @as(*volatile u32, @ptrFromInt(addr)).* = value;
}

/// Read a 16-bit value from PCI config.
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
    const new_command: u32 = @as(u32, command) | 0x07;
    configWrite(dev.bus, dev.slot, dev.func, 0x04, new_command);
}

var devices: [MAX_DEVICES]PciDevice = undefined;
var device_count: u8 = 0;

/// Enumerate PCI bus 0 and discover all devices.
pub fn enumerate() void {
    device_count = 0;
    klog.debug("PCI ECAM: scanning bus 0...\n");

    for (0..32) |slot_usize| {
        const slot: u8 = @intCast(slot_usize);
        const vendor_id = configRead16(0, slot, 0, 0x00);

        if (vendor_id == 0xFFFF) continue;

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

        for (0..6) |i| {
            if (dev.header_type == 0) {
                dev.bar[i] = configRead(0, slot, 0, @intCast(0x10 + i * 4));
            } else {
                dev.bar[i] = 0;
            }
        }

        klog.debug("  [");
        klog.debugDec(slot_usize);
        klog.debug("] ");
        klog.debugHex(vendor_id);
        klog.debug(":");
        klog.debugHex(device_id);
        klog.debug(" class=");
        klog.debugHex(dev.class_code);
        klog.debug(":");
        klog.debugHex(dev.subclass);
        if (dev.isVirtioNet()) {
            klog.debug(" (virtio-net)");
        } else if (dev.isVirtioBlk()) {
            klog.debug(" (virtio-blk)");
        } else if (dev.isVirtio()) {
            klog.debug(" (virtio)");
        }
        klog.debug("\n");

        device_count += 1;
    }

    klog.info("PCI ECAM: found ");
    klog.infoDec(device_count);
    klog.info(" devices\n");
}

pub fn findDevice(vendor_id: u16, device_id: u16) ?*PciDevice {
    for (0..device_count) |i| {
        if (devices[i].vendor_id == vendor_id and devices[i].device_id == device_id) {
            return &devices[i];
        }
    }
    return null;
}

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

pub fn getDevices() []PciDevice {
    return devices[0..device_count];
}
