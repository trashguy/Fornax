/// Virtio 1.0 (modern) MMIO transport via PCI capabilities.
///
/// Parses PCI capability list (cap_id=0x09) to find common_cfg, notify, isr,
/// and device_cfg MMIO structures. Used for virtio-input which is modern-only.

const serial = @import("serial.zig");
const console = @import("console.zig");
const pci = @import("arch/x86_64/pci.zig");
const pmm = @import("pmm.zig");
const virtio = @import("virtio.zig");

/// Virtio PCI capability types (VIRTIO_PCI_CAP_*)
const VIRTIO_PCI_CAP_COMMON_CFG: u8 = 1;
const VIRTIO_PCI_CAP_NOTIFY_CFG: u8 = 2;
const VIRTIO_PCI_CAP_ISR_CFG: u8 = 3;
const VIRTIO_PCI_CAP_DEVICE_CFG: u8 = 4;

/// Virtio device status bits
const STATUS_ACKNOWLEDGE: u8 = 1;
const STATUS_DRIVER: u8 = 2;
const STATUS_DRIVER_OK: u8 = 4;
const STATUS_FEATURES_OK: u8 = 8;

/// Common configuration structure offsets (from MMIO base)
const COMMON_DFSELECT: usize = 0x00; // u32 — device feature select
const COMMON_DF: usize = 0x04; // u32 — device feature bits
const COMMON_GFSELECT: usize = 0x08; // u32 — driver feature select
const COMMON_GF: usize = 0x0C; // u32 — driver feature bits
const COMMON_MSIX: usize = 0x10; // u16 — MSI-X config vector
const COMMON_NUMQ: usize = 0x12; // u16 — number of queues
const COMMON_STATUS: usize = 0x14; // u8  — device status
const COMMON_CFGGEN: usize = 0x15; // u8  — config generation
const COMMON_QSELECT: usize = 0x16; // u16 — queue select
const COMMON_QSIZE: usize = 0x18; // u16 — queue size
const COMMON_QMSIX: usize = 0x1A; // u16 — queue MSI-X vector
const COMMON_QENABLE: usize = 0x1C; // u16 — queue enable
const COMMON_QNOTIFY: usize = 0x1E; // u16 — queue notify offset
const COMMON_QDESC_LO: usize = 0x20; // u32 — queue descriptors low
const COMMON_QDESC_HI: usize = 0x24; // u32 — queue descriptors high
const COMMON_QAVAIL_LO: usize = 0x28; // u32 — queue avail low
const COMMON_QAVAIL_HI: usize = 0x2C; // u32 — queue avail high
const COMMON_QUSED_LO: usize = 0x30; // u32 — queue used low
const COMMON_QUSED_HI: usize = 0x34; // u32 — queue used high

pub const VirtioModernDevice = struct {
    pci_dev: *pci.PciDevice,
    common_cfg: usize, // MMIO address of common config
    notify_base: usize, // MMIO address of notify region
    notify_off_multiplier: u32, // notify offset multiplier
    isr_base: usize, // MMIO address of ISR status
    device_cfg: usize, // MMIO address of device-specific config
    device_features: u32,
};

fn mmioRead8(addr: usize) u8 {
    return @as(*volatile u8, @ptrFromInt(addr)).*;
}

fn mmioRead16(addr: usize) u16 {
    return @as(*volatile u16, @ptrFromInt(addr)).*;
}

fn mmioRead32(addr: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(addr)).*;
}

fn mmioWrite8(addr: usize, val: u8) void {
    @as(*volatile u8, @ptrFromInt(addr)).* = val;
}

fn mmioWrite16(addr: usize, val: u16) void {
    @as(*volatile u16, @ptrFromInt(addr)).* = val;
}

fn mmioWrite32(addr: usize, val: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = val;
}

/// Resolve a BAR + offset to an MMIO address.
fn resolveBarOffset(dev: *pci.PciDevice, bar_index: u8, offset: u32) ?usize {
    if (bar_index >= 6) return null;
    const bar_base = dev.memBase(@intCast(bar_index)) orelse return null;
    const addr = bar_base + offset;
    // Only identity-mapped first 4 GB is accessible without extra page mappings
    if (addr >= 0x1_0000_0000) return null;
    return @intCast(addr);
}

/// Parse PCI capabilities to find virtio modern MMIO regions.
pub fn initDevice(pci_dev: *pci.PciDevice) ?VirtioModernDevice {
    // Check PCI status register for capability list support
    const status = pci.configRead16(pci_dev.bus, pci_dev.slot, pci_dev.func, 0x06);
    if (status & 0x10 == 0) {
        serial.puts("virtio-modern: no capabilities list\n");
        return null;
    }

    // Enable bus mastering + memory space access
    pci.enableBusMastering(pci_dev);

    var common_cfg: ?usize = null;
    var notify_base: ?usize = null;
    var notify_off_multiplier: u32 = 0;
    var isr_base: ?usize = null;
    var device_cfg: ?usize = null;

    // Walk PCI capability list
    var cap_offset = pci.configRead8(pci_dev.bus, pci_dev.slot, pci_dev.func, 0x34) & 0xFC;
    var iterations: u32 = 0;
    while (cap_offset != 0 and iterations < 48) : (iterations += 1) {
        const cap_id = pci.configRead8(pci_dev.bus, pci_dev.slot, pci_dev.func, cap_offset);
        const cap_next = pci.configRead8(pci_dev.bus, pci_dev.slot, pci_dev.func, cap_offset + 1);

        if (cap_id == 0x09) { // VIRTIO_PCI_CAP
            // Virtio capability structure layout:
            //   +0: cap_id (u8), +1: cap_next (u8), +2: cap_len (u8), +3: cfg_type (u8)
            //   +4: bar (u8), +5..+7: padding, +8: offset (u32), +12: length (u32)
            const cfg_type = pci.configRead8(pci_dev.bus, pci_dev.slot, pci_dev.func, cap_offset + 3);
            const bar_index = pci.configRead8(pci_dev.bus, pci_dev.slot, pci_dev.func, cap_offset + 4);
            const bar_offset = pci.configRead(pci_dev.bus, pci_dev.slot, pci_dev.func, cap_offset + 8);

            const addr = resolveBarOffset(pci_dev, bar_index, bar_offset);

            switch (cfg_type) {
                VIRTIO_PCI_CAP_COMMON_CFG => {
                    common_cfg = addr;
                    serial.puts("virtio-modern: common_cfg at BAR");
                    serial.putDec(bar_index);
                    serial.puts("+");
                    serial.putHex(bar_offset);
                    serial.puts("\n");
                },
                VIRTIO_PCI_CAP_NOTIFY_CFG => {
                    notify_base = addr;
                    // The notify_off_multiplier is at cap_offset + 16 (after the standard 16-byte cap)
                    notify_off_multiplier = pci.configRead(pci_dev.bus, pci_dev.slot, pci_dev.func, cap_offset + 16);
                    serial.puts("virtio-modern: notify at BAR");
                    serial.putDec(bar_index);
                    serial.puts("+");
                    serial.putHex(bar_offset);
                    serial.puts(" mult=");
                    serial.putDec(notify_off_multiplier);
                    serial.puts("\n");
                },
                VIRTIO_PCI_CAP_ISR_CFG => {
                    isr_base = addr;
                },
                VIRTIO_PCI_CAP_DEVICE_CFG => {
                    device_cfg = addr;
                },
                else => {},
            }
        }

        cap_offset = cap_next & 0xFC;
    }

    const common = common_cfg orelse {
        serial.puts("virtio-modern: no common_cfg found\n");
        return null;
    };
    const notify = notify_base orelse {
        serial.puts("virtio-modern: no notify region found\n");
        return null;
    };
    const isr = isr_base orelse {
        serial.puts("virtio-modern: no ISR region found\n");
        return null;
    };

    // Reset device
    mmioWrite8(common + COMMON_STATUS, 0);
    // Acknowledge
    mmioWrite8(common + COMMON_STATUS, STATUS_ACKNOWLEDGE);
    // Driver
    mmioWrite8(common + COMMON_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER);

    // Read device features (feature select 0 = bits 0-31)
    mmioWrite32(common + COMMON_DFSELECT, 0);
    const device_features = mmioRead32(common + COMMON_DF);

    serial.puts("virtio-modern: features = ");
    serial.putHex(device_features);
    serial.puts("\n");

    return VirtioModernDevice{
        .pci_dev = pci_dev,
        .common_cfg = common,
        .notify_base = notify,
        .notify_off_multiplier = notify_off_multiplier,
        .isr_base = isr,
        .device_cfg = device_cfg orelse 0,
        .device_features = device_features,
    };
}

/// Finish device initialization (feature negotiation + DRIVER_OK).
pub fn finishInit(dev: *VirtioModernDevice, wanted_features: u32) void {
    const negotiated = dev.device_features & wanted_features;

    // Write driver features
    mmioWrite32(dev.common_cfg + COMMON_GFSELECT, 0);
    mmioWrite32(dev.common_cfg + COMMON_GF, negotiated);

    // Set FEATURES_OK
    mmioWrite8(dev.common_cfg + COMMON_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK);

    // Verify FEATURES_OK stuck
    const status = mmioRead8(dev.common_cfg + COMMON_STATUS);
    if (status & STATUS_FEATURES_OK == 0) {
        serial.puts("virtio-modern: FEATURES_OK not accepted\n");
        mmioWrite8(dev.common_cfg + COMMON_STATUS, 0x80); // FAILED
        return;
    }

    // DRIVER_OK
    mmioWrite8(dev.common_cfg + COMMON_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK);

    serial.puts("virtio-modern: DRIVER_OK, negotiated=");
    serial.putHex(negotiated);
    serial.puts("\n");
}

/// Set up a virtqueue. Returns a Virtqueue struct compatible with legacy ring format.
pub fn setupQueue(dev: *VirtioModernDevice, queue_index: u16) ?virtio.Virtqueue {
    const common = dev.common_cfg;

    // Select queue
    mmioWrite16(common + COMMON_QSELECT, queue_index);

    // Read queue size
    const queue_size = mmioRead16(common + COMMON_QSIZE);
    if (queue_size == 0) {
        serial.puts("virtio-modern: queue ");
        serial.putDec(queue_index);
        serial.puts(" size is 0\n");
        return null;
    }

    serial.puts("virtio-modern: queue ");
    serial.putDec(queue_index);
    serial.puts(" size = ");
    serial.putDec(queue_size);
    serial.puts("\n");

    // Allocate descriptor table, available ring, and used ring separately
    // Descriptor table: 16 bytes per entry
    const desc_size: usize = @as(usize, queue_size) * @sizeOf(virtio.VirtqDesc);
    // Available ring: 2 + 2 + 2*queue_size + 2
    const avail_size: usize = 4 + @as(usize, queue_size) * 2 + 2;
    // Used ring: 2 + 2 + 8*queue_size + 2
    const used_size: usize = 4 + @as(usize, queue_size) * @sizeOf(virtio.VirtqUsedElem) + 2;

    const desc_avail_pages = (desc_size + avail_size + 4095) / 4096;
    const used_pages = (used_size + 4095) / 4096;
    const total_pages = desc_avail_pages + used_pages;

    const first_page = pmm.allocPage() orelse return null;
    var pages_got: usize = 1;
    while (pages_got < total_pages) : (pages_got += 1) {
        _ = pmm.allocPage() orelse return null;
    }

    // Zero all queue memory
    const ptr: [*]u8 = @ptrFromInt(first_page);
    @memset(ptr[0 .. total_pages * 4096], 0);

    // Set up pointers
    const desc_addr: u64 = first_page;
    const avail_addr: u64 = first_page + desc_size;
    const used_addr: u64 = (first_page + desc_size + avail_size + 4095) & ~@as(u64, 4095);

    const desc_ptr: [*]virtio.VirtqDesc = @ptrFromInt(first_page);
    const avail_ptr: *virtio.VirtqAvail = @ptrFromInt(@as(usize, @intCast(avail_addr)));
    const avail_ring_ptr: [*]u16 = @ptrFromInt(@as(usize, @intCast(avail_addr)) + 4);
    const used_ptr: *virtio.VirtqUsed = @ptrFromInt(@as(usize, @intCast(used_addr)));
    const used_ring_ptr: [*]virtio.VirtqUsedElem = @ptrFromInt(@as(usize, @intCast(used_addr)) + 4);

    // Tell device the queue addresses (64-bit physical addresses)
    mmioWrite32(common + COMMON_QDESC_LO, @truncate(desc_addr));
    mmioWrite32(common + COMMON_QDESC_HI, @truncate(desc_addr >> 32));
    mmioWrite32(common + COMMON_QAVAIL_LO, @truncate(avail_addr));
    mmioWrite32(common + COMMON_QAVAIL_HI, @truncate(avail_addr >> 32));
    mmioWrite32(common + COMMON_QUSED_LO, @truncate(used_addr));
    mmioWrite32(common + COMMON_QUSED_HI, @truncate(used_addr >> 32));

    // Enable the queue
    mmioWrite16(common + COMMON_QENABLE, 1);

    return virtio.Virtqueue{
        .size = queue_size,
        .phys_addr = desc_addr,
        .desc = desc_ptr,
        .avail = avail_ptr,
        .avail_ring = avail_ring_ptr,
        .used = used_ptr,
        .used_ring = used_ring_ptr,
        .next_desc = 0,
        .last_used_idx = 0,
        .io_base = 0, // not used for modern transport
        .queue_index = queue_index,
    };
}

/// Notify the device about a queue update.
pub fn notifyQueue(dev: *VirtioModernDevice, queue_index: u16) void {
    // Read the queue's notify offset
    mmioWrite16(dev.common_cfg + COMMON_QSELECT, queue_index);
    const queue_notify_off = mmioRead16(dev.common_cfg + COMMON_QNOTIFY);

    // Write to notify address = notify_base + queue_notify_off * notify_off_multiplier
    const notify_addr = dev.notify_base + @as(usize, queue_notify_off) * dev.notify_off_multiplier;
    mmioWrite16(notify_addr, queue_index);
}

/// Read ISR status (clears on read).
pub fn readIsr(dev: *VirtioModernDevice) u8 {
    return mmioRead8(dev.isr_base);
}
