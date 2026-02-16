/// virtio-blk block device driver.
///
/// Runs kernel-side (needs I/O port access).
/// Provides readBlock/writeBlock for 4096-byte blocks.
///
/// virtio-blk legacy device config (at io_base + 0x14):
///   0x14  capacity  — total sectors (u64, 512 bytes each)
const pmm = @import("pmm.zig");
const klog = @import("klog.zig");
const virtio = @import("virtio.zig");

const pci = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("arch/x86_64/pci.zig"),
    else => struct {
        pub const PciDevice = struct {};
    },
};

const cpu = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("arch/x86_64/cpu.zig"),
    else => struct {
        pub fn inb(_: u16) u8 {
            return 0;
        }
        pub fn inl(_: u16) u32 {
            return 0;
        }
    },
};

const VIRTIO_BLK_T_IN = 0; // read
const VIRTIO_BLK_T_OUT = 1; // write
const VIRTIO_BLK_S_OK = 0;

const SECTORS_PER_BLOCK = 8; // 4096 / 512

/// virtio-blk request header (16 bytes).
const VirtioBlkReq = extern struct {
    req_type: u32,
    reserved: u32,
    sector: u64,
};

pub const BlkDevice = struct {
    dev: virtio.VirtioDevice,
    queue: ?virtio.Virtqueue,
    capacity: u64, // in 512-byte sectors
    initialized: bool,
};

var blk_dev: BlkDevice = .{
    .dev = undefined,
    .queue = null,
    .capacity = 0,
    .initialized = false,
};

/// Initialize the virtio-blk device.
pub fn init() bool {
    if (@import("builtin").cpu.arch != .x86_64) return false;

    const pci_dev = pci.findVirtioBlk() orelse {
        klog.debug("virtio-blk: no device found\n");
        return false;
    };

    klog.debug("virtio-blk: found at PCI slot ");
    klog.debugDec(pci_dev.slot);
    klog.debug(", io_base=");
    klog.debugHex(pci_dev.ioBase() orelse 0);
    klog.debug("\n");

    var dev = virtio.initDevice(pci_dev) orelse {
        klog.err("virtio-blk: device init failed\n");
        return false;
    };

    // No special features needed for basic block I/O
    virtio.finishInit(&dev, 0);

    // Set up the single request queue (queue 0)
    blk_dev.queue = virtio.setupQueue(&dev, 0);
    if (blk_dev.queue == null) {
        klog.err("virtio-blk: failed to setup queue\n");
        return false;
    }

    // Read capacity from device config at io_base + 0x14 (u64 LE, sector count)
    const io_base = pci_dev.ioBase().?;
    const cap_lo: u64 = cpu.inl(io_base + 0x14);
    const cap_hi: u64 = cpu.inl(io_base + 0x18);
    blk_dev.capacity = cap_lo | (cap_hi << 32);

    blk_dev.dev = dev;
    blk_dev.initialized = true;

    const sectors = blk_dev.capacity;
    const mb = sectors / 2048; // sectors * 512 / 1048576
    klog.info("virtio-blk: ");
    klog.infoDec(sectors);
    klog.info(" sectors (");
    klog.infoDec(mb);
    klog.info(" MB)\n");

    return true;
}

/// Read a 4096-byte block from the device.
/// block is a 4K-block number (sector = block * 8).
pub fn readBlock(block: u64, buf: *[4096]u8) bool {
    if (!blk_dev.initialized) return false;

    const vq = &(blk_dev.queue.?);
    const sector = block * SECTORS_PER_BLOCK;

    if (sector + SECTORS_PER_BLOCK > blk_dev.capacity) return false;

    // Allocate DMA-safe pages (identity-mapped physical memory)
    const req_phys = pmm.allocPage() orelse return false;
    const data_phys = pmm.allocPage() orelse {
        pmm.freePage(req_phys);
        return false;
    };
    const req_ptr: [*]u8 = @ptrFromInt(req_phys);
    const data_ptr: [*]u8 = @ptrFromInt(data_phys);

    // Write request header at start of req page
    const hdr: *VirtioBlkReq = @ptrCast(@alignCast(req_ptr));
    hdr.* = .{
        .req_type = VIRTIO_BLK_T_IN,
        .reserved = 0,
        .sector = sector,
    };

    // Status byte at offset 16
    req_ptr[16] = 0xFF; // sentinel

    // 3-descriptor chain: header (r), data (w), status (w)
    // All addresses are physical (identity-mapped) — safe for DMA
    const head = virtio.addBufferChain3(
        vq,
        req_phys,
        @sizeOf(VirtioBlkReq),
        false, // device-readable
        data_phys,
        4096,
        true, // device-writable (read into DMA buf)
        req_phys + 16,
        1,
        true, // device-writable
    ) orelse {
        pmm.freePage(data_phys);
        pmm.freePage(req_phys);
        return false;
    };

    virtio.notify(vq);

    // Poll for completion
    var spins: u32 = 0;
    while (virtio.pollUsed(vq) == null) : (spins += 1) {
        if (spins > 10_000_000) {
            klog.err("virtio-blk: read timeout\n");
            pmm.freePage(data_phys);
            pmm.freePage(req_phys);
            return false;
        }
        asm volatile ("pause");
    }

    // Reclaim descriptors — synchronous polling means no other requests
    // are outstanding, so we can reuse from this head index onward.
    vq.next_desc = head;

    const status = req_ptr[16];

    // Copy DMA buffer to caller's buffer (which may be a userspace address)
    if (status == VIRTIO_BLK_S_OK) {
        @memcpy(buf, data_ptr[0..4096]);
    }

    pmm.freePage(data_phys);
    pmm.freePage(req_phys);

    return status == VIRTIO_BLK_S_OK;
}

/// Write a 4096-byte block to the device.
/// block is a 4K-block number (sector = block * 8).
pub fn writeBlock(block: u64, buf: *const [4096]u8) bool {
    if (!blk_dev.initialized) return false;

    const vq = &(blk_dev.queue.?);
    const sector = block * SECTORS_PER_BLOCK;

    if (sector + SECTORS_PER_BLOCK > blk_dev.capacity) return false;

    // Allocate DMA-safe pages (identity-mapped physical memory)
    const req_phys = pmm.allocPage() orelse return false;
    const data_phys = pmm.allocPage() orelse {
        pmm.freePage(req_phys);
        return false;
    };
    const req_ptr: [*]u8 = @ptrFromInt(req_phys);
    const data_ptr: [*]u8 = @ptrFromInt(data_phys);

    // Copy caller's buffer to DMA buffer (caller may be userspace address)
    @memcpy(data_ptr[0..4096], buf);

    // Write request header
    const hdr: *VirtioBlkReq = @ptrCast(@alignCast(req_ptr));
    hdr.* = .{
        .req_type = VIRTIO_BLK_T_OUT,
        .reserved = 0,
        .sector = sector,
    };

    // Status byte at offset 16
    req_ptr[16] = 0xFF;

    // 3-descriptor chain: header (r), data (r), status (w)
    _ = virtio.addBufferChain3(
        vq,
        req_phys,
        @sizeOf(VirtioBlkReq),
        false, // device-readable
        data_phys,
        4096,
        false, // device-readable (write from DMA buf)
        req_phys + 16,
        1,
        true, // device-writable
    ) orelse {
        pmm.freePage(data_phys);
        pmm.freePage(req_phys);
        return false;
    };

    virtio.notify(vq);

    // Poll for completion
    var spins: u32 = 0;
    while (virtio.pollUsed(vq) == null) : (spins += 1) {
        if (spins > 10_000_000) {
            klog.err("virtio-blk: write timeout\n");
            pmm.freePage(data_phys);
            pmm.freePage(req_phys);
            return false;
        }
        asm volatile ("pause");
    }

    const status = req_ptr[16];
    pmm.freePage(data_phys);
    pmm.freePage(req_phys);

    return status == VIRTIO_BLK_S_OK;
}

pub fn isInitialized() bool {
    return blk_dev.initialized;
}

pub fn getCapacitySectors() u64 {
    return blk_dev.capacity;
}

pub fn getCapacityBlocks() u64 {
    return blk_dev.capacity / SECTORS_PER_BLOCK;
}
