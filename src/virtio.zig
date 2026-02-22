/// Generic virtio device support (legacy I/O port interface).
///
/// virtio 0.9.5 legacy interface — simpler than modern MMIO, suitable for QEMU.
///
/// Legacy virtio I/O port layout (from BAR0):
///   0x00  device_features  (R)   — features the device supports
///   0x04  guest_features   (R/W) — features the driver accepts
///   0x08  queue_address    (R/W) — physical address of virtqueue / 4096
///   0x0C  queue_size       (R)   — max entries in current queue
///   0x0E  queue_select     (R/W) — select which queue to configure
///   0x10  queue_notify     (W)   — notify device that queue has new buffers
///   0x12  device_status    (R/W) — device status register
///   0x13  isr_status       (R)   — interrupt status
///   0x14+ device-specific config (varies by device type)
const pmm = @import("pmm.zig");
const klog = @import("klog.zig");

const pci = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("arch/x86_64/pci.zig"),
    .riscv64 => @import("arch/riscv64/pci.zig"),
    else => struct {
        pub const PciDevice = struct {};
    },
};

const cpu = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("arch/x86_64/cpu.zig"),
    .riscv64 => @import("arch/riscv64/cpu.zig"),
    else => struct {
        pub fn outb(_: u16, _: u8) void {}
        pub fn inb(_: u16) u8 {
            return 0;
        }
    },
};

const builtin_arch = @import("builtin").cpu.arch;

/// QEMU riscv64 virt: PCI I/O port space is mapped to MMIO at this CPU address.
/// From device tree: ranges = <0x01000000 ... 0x03000000 ... 0x10000>
const PCI_IO_WINDOW: u64 = 0x0300_0000;

// Legacy virtio register offsets
const REG_DEVICE_FEATURES: u16 = 0x00;
const REG_GUEST_FEATURES: u16 = 0x04;
const REG_QUEUE_ADDRESS: u16 = 0x08;
const REG_QUEUE_SIZE: u16 = 0x0C;
const REG_QUEUE_SELECT: u16 = 0x0E;
const REG_QUEUE_NOTIFY: u16 = 0x10;
const REG_DEVICE_STATUS: u16 = 0x12;
const REG_ISR_STATUS: u16 = 0x13;
const REG_DEVICE_CONFIG: u16 = 0x14;

// Device status bits
pub const STATUS_ACKNOWLEDGE: u8 = 1;
pub const STATUS_DRIVER: u8 = 2;
pub const STATUS_DRIVER_OK: u8 = 4;
pub const STATUS_FEATURES_OK: u8 = 8;
pub const STATUS_FAILED: u8 = 128;

// virtio-net feature bits
pub const VIRTIO_NET_F_MAC: u32 = 1 << 5;
pub const VIRTIO_NET_F_STATUS: u32 = 1 << 16;
pub const VIRTIO_NET_F_MRG_RXBUF: u32 = 1 << 15;

/// A virtqueue descriptor.
pub const VirtqDesc = extern struct {
    addr: u64, // physical address of buffer
    len: u32, // buffer length
    flags: u16, // NEXT, WRITE, INDIRECT
    next: u16, // next descriptor index (if NEXT flag set)
};

pub const VRING_DESC_F_NEXT: u16 = 1;
pub const VRING_DESC_F_WRITE: u16 = 2;

/// Available ring — guest tells device which descriptors are ready.
pub const VirtqAvail = extern struct {
    flags: u16,
    idx: u16,
    // ring: [queue_size]u16 follows
};

/// Used ring entry.
pub const VirtqUsedElem = extern struct {
    id: u32, // descriptor chain head index
    len: u32, // bytes written by device
};

/// Used ring — device tells guest which descriptors it's done with.
pub const VirtqUsed = extern struct {
    flags: u16,
    idx: u16,
    // ring: [queue_size]VirtqUsedElem follows
};

/// A virtqueue with all its components.
pub const Virtqueue = struct {
    /// Number of entries (must be power of 2).
    size: u16,
    /// Physical address of the virtqueue memory.
    phys_addr: u64,

    // Pointers into the queue memory
    desc: [*]VirtqDesc,
    avail: *VirtqAvail,
    avail_ring: [*]u16,
    used: *VirtqUsed,
    used_ring: [*]VirtqUsedElem,

    /// Next descriptor index to allocate.
    next_desc: u16,
    /// Last used index we've seen.
    last_used_idx: u16,

    /// I/O port base of the parent device.
    io_base: u16,
    /// Queue index (for notify).
    queue_index: u16,
};

/// A virtio device.
pub const VirtioDevice = struct {
    io_base: u16,
    pci_dev: *pci.PciDevice,
    device_features: u32,
    negotiated_features: u32,
};

/// Initialize a legacy virtio device via PCI.
pub fn initDevice(pci_dev: *pci.PciDevice) ?VirtioDevice {
    var io_base: u16 = 0;

    // Legacy virtio always uses an I/O BAR. On riscv64, the PCI controller
    // maps I/O port space to MMIO at PCI_IO_WINDOW (0x03000000).
    io_base = pci_dev.ioBase() orelse {
        klog.debug("virtio: device has no I/O BAR\n");
        return null;
    };

    // Enable PCI bus mastering (required for DMA)
    pci.enableBusMastering(pci_dev);

    // On riscv64, set the global MMIO address for I/O helpers.
    // I/O BAR port address → PCI I/O window MMIO address.
    if (comptime builtin_arch == .riscv64) setMmioBase(PCI_IO_WINDOW + @as(u64, io_base));

    // Reset device
    write8(io_base, REG_DEVICE_STATUS, 0);

    // Acknowledge device
    write8(io_base, REG_DEVICE_STATUS, STATUS_ACKNOWLEDGE);

    // Tell device we're a driver
    write8(io_base, REG_DEVICE_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER);

    // Read device features
    const device_features = read32(io_base, REG_DEVICE_FEATURES);

    klog.debug("virtio: device features = ");
    klog.debugHex(device_features);
    klog.debug("\n");

    return VirtioDevice{
        .io_base = io_base,
        .pci_dev = pci_dev,
        .device_features = device_features,
        .negotiated_features = 0,
    };
}

/// Negotiate features and mark driver ready.
pub fn finishInit(dev: *VirtioDevice, wanted_features: u32) void {
    // Accept only the features we want that the device also supports
    dev.negotiated_features = dev.device_features & wanted_features;
    write32(dev.io_base, REG_GUEST_FEATURES, dev.negotiated_features);

    // Mark driver OK
    write8(dev.io_base, REG_DEVICE_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_DRIVER_OK);

    klog.debug("virtio: negotiated features = ");
    klog.debugHex(dev.negotiated_features);
    klog.debug(", status = DRIVER_OK\n");
}

/// Set up a virtqueue.
pub fn setupQueue(dev: *VirtioDevice, queue_index: u16) ?Virtqueue {
    // Select the queue
    write16(dev.io_base, REG_QUEUE_SELECT, queue_index);

    // Read queue size
    const queue_size = read16(dev.io_base, REG_QUEUE_SIZE);
    if (queue_size == 0) {
        klog.debug("virtio: queue ");
        klog.debugDec(queue_index);
        klog.debug(" size is 0\n");
        return null;
    }

    klog.debug("virtio: queue ");
    klog.debugDec(queue_index);
    klog.debug(" size = ");
    klog.debugDec(queue_size);
    klog.debug("\n");

    // Calculate memory layout sizes
    // Descriptor table: 16 bytes per entry
    const desc_size: usize = @as(usize, queue_size) * @sizeOf(VirtqDesc);
    // Available ring: 2 + 2 + 2*queue_size + 2 (padding to next page)
    const avail_size: usize = 4 + @as(usize, queue_size) * 2 + 2;
    // Used ring: 2 + 2 + 8*queue_size + 2
    const used_size: usize = 4 + @as(usize, queue_size) * @sizeOf(VirtqUsedElem) + 2;

    // Total: desc + avail must be on one set of pages, used ring page-aligned after
    const desc_avail_pages = (desc_size + avail_size + 4095) / 4096;
    const used_pages = (used_size + 4095) / 4096;
    const total_pages = desc_avail_pages + used_pages;

    // Allocate guaranteed-contiguous pages (device DMA requires contiguous physical memory)
    const first_page = pmm.allocContiguousPages(total_pages) orelse return null;

    const phys_addr: u64 = first_page;

    // Use higher-half pointers for CPU access — immune to identity-map modifications
    // by user ELF mappings (huge page splits in per-process page tables).
    const base: u64 = first_page + @import("mem.zig").KERNEL_VIRT_BASE;

    // Zero all queue memory
    const ptr: [*]u8 = @ptrFromInt(base);
    @memset(ptr[0 .. total_pages * 4096], 0);

    // Set up pointers (all higher-half)
    const desc_ptr: [*]VirtqDesc = @ptrFromInt(base);
    const avail_ptr: *VirtqAvail = @ptrFromInt(base + desc_size);
    const avail_ring_ptr: [*]u16 = @ptrFromInt(base + desc_size + 4);
    const used_virt = (base + desc_size + avail_size + 4095) & ~@as(usize, 4095);
    const used_ptr: *VirtqUsed = @ptrFromInt(used_virt);
    const used_ring_ptr: [*]VirtqUsedElem = @ptrFromInt(used_virt + 4);

    // Tell device the queue address (in units of 4096 bytes)
    write32(dev.io_base, REG_QUEUE_ADDRESS, @intCast(phys_addr / 4096));

    return Virtqueue{
        .size = queue_size,
        .phys_addr = phys_addr,
        .desc = desc_ptr,
        .avail = avail_ptr,
        .avail_ring = avail_ring_ptr,
        .used = used_ptr,
        .used_ring = used_ring_ptr,
        .next_desc = 0,
        .last_used_idx = 0,
        .io_base = dev.io_base,
        .queue_index = queue_index,
    };
}

/// Add a buffer to a virtqueue and make it available to the device.
pub fn addBuffer(vq: *Virtqueue, phys_addr: u64, len: u32, device_writable: bool) ?u16 {
    const idx = vq.next_desc;
    if (idx >= vq.size) return null;

    vq.desc[idx] = .{
        .addr = phys_addr,
        .len = len,
        .flags = if (device_writable) VRING_DESC_F_WRITE else 0,
        .next = 0,
    };

    // Add to available ring
    const avail_idx = vq.avail.idx;
    vq.avail_ring[avail_idx % vq.size] = idx;

    // Memory barrier — ensure descriptor is written before updating index
    memoryBarrier();

    vq.avail.idx = avail_idx +% 1;
    vq.next_desc = idx + 1;

    return idx;
}

/// Add a 3-descriptor chain to the virtqueue (for virtio-blk requests).
/// Returns the head descriptor index, or null if not enough descriptors.
pub fn addBufferChain3(
    vq: *Virtqueue,
    addr0: u64,
    len0: u32,
    writable0: bool,
    addr1: u64,
    len1: u32,
    writable1: bool,
    addr2: u64,
    len2: u32,
    writable2: bool,
) ?u16 {
    const head = vq.next_desc;
    if (head + 2 >= vq.size) return null;

    // Descriptor 0 -> 1 -> 2
    vq.desc[head] = .{
        .addr = addr0,
        .len = len0,
        .flags = (if (writable0) VRING_DESC_F_WRITE else 0) | VRING_DESC_F_NEXT,
        .next = head + 1,
    };
    vq.desc[head + 1] = .{
        .addr = addr1,
        .len = len1,
        .flags = (if (writable1) VRING_DESC_F_WRITE else 0) | VRING_DESC_F_NEXT,
        .next = head + 2,
    };
    vq.desc[head + 2] = .{
        .addr = addr2,
        .len = len2,
        .flags = if (writable2) VRING_DESC_F_WRITE else 0,
        .next = 0,
    };

    // Add head to available ring
    const avail_idx = vq.avail.idx;
    vq.avail_ring[avail_idx % vq.size] = head;

    memoryBarrier();

    vq.avail.idx = avail_idx +% 1;
    vq.next_desc = head + 3;

    return head;
}

/// Notify the device that there are new available buffers.
pub fn notify(vq: *Virtqueue) void {
    write16(vq.io_base, REG_QUEUE_NOTIFY, vq.queue_index);
}

/// Check if the device has returned any used buffers.
pub fn pollUsed(vq: *Virtqueue) ?VirtqUsedElem {
    // Memory barrier — ensure we see the latest used index
    memoryBarrier();

    // Volatile read of used.idx to prevent compiler from caching the value
    const used_idx = @as(*volatile u16, @ptrCast(&vq.used.idx)).*;
    if (vq.last_used_idx == used_idx) return null;

    const elem = vq.used_ring[vq.last_used_idx % vq.size];
    vq.last_used_idx +%= 1;
    return elem;
}

/// Re-post an existing descriptor to the available ring without allocating a new
/// descriptor slot. Used for recycling RX buffers that have already been set up.
pub fn recycleDesc(vq: *Virtqueue, desc_idx: u16) void {
    const avail_idx = vq.avail.idx;
    vq.avail_ring[avail_idx % vq.size] = desc_idx;
    memoryBarrier();
    vq.avail.idx = avail_idx +% 1;
}

/// Read the ISR status register (clears interrupt).
pub fn readIsr(dev: *VirtioDevice) u8 {
    return read8(dev.io_base, REG_ISR_STATUS);
}

pub fn memoryBarrier() void {
    switch (@import("builtin").cpu.arch) {
        .x86_64 => asm volatile ("mfence" ::: .{ .memory = true }),
        .aarch64 => asm volatile ("dmb sy" ::: .{ .memory = true }),
        .riscv64 => asm volatile ("fence rw, rw" ::: .{ .memory = true }),
        else => {},
    }
}

// I/O helpers for legacy virtio.
// x86_64: I/O port. riscv64: MMIO (base comes from VirtioDevice.mmio_base).
fn read8(base: u16, offset: u16) u8 {
    return switch (builtin_arch) {
        .riscv64 => cpu.mmioRead8(mmioDevAddr(base, offset)),
        else => cpu.inb(base + offset),
    };
}

fn read16(base: u16, offset: u16) u16 {
    return switch (builtin_arch) {
        .riscv64 => cpu.mmioRead16(mmioDevAddr(base, offset)),
        else => cpu.inw(base + offset),
    };
}

fn read32(base: u16, offset: u16) u32 {
    return switch (builtin_arch) {
        .riscv64 => cpu.mmioRead32(mmioDevAddr(base, offset)),
        else => cpu.inl(base + offset),
    };
}

fn write8(base: u16, offset: u16, val: u8) void {
    switch (builtin_arch) {
        .riscv64 => cpu.mmioWrite8(mmioDevAddr(base, offset), val),
        else => cpu.outb(base + offset, val),
    }
}

fn write16(base: u16, offset: u16, val: u16) void {
    switch (builtin_arch) {
        .riscv64 => cpu.mmioWrite16(mmioDevAddr(base, offset), val),
        else => cpu.outw(base + offset, val),
    }
}

fn write32(base: u16, offset: u16, val: u32) void {
    switch (builtin_arch) {
        .riscv64 => cpu.mmioWrite32(mmioDevAddr(base, offset), val),
        else => cpu.outl(base + offset, val),
    }
}

/// On riscv64, the "io_base" field stores a truncated u16. Recover the full MMIO addr.
/// For virtqueue ops that only get the u16 io_base, we need the full MMIO address.
/// We store the low 16 bits of the MMIO BAR address in io_base and reconstruct here.
/// NOTE: QEMU virt PCI MMIO BARs are in the 0x40000000+ range, so truncation loses data.
/// This helper is only correct if mmio_base was stored somewhere accessible.
/// For simplicity, we use a global that initDevice sets.
var global_mmio_base: u64 = 0;

fn mmioDevAddr(base_lo: u16, offset: u16) u64 {
    // On riscv64, io_base is 0 (not used). Use the global MMIO base.
    _ = base_lo;
    const paging_mod = @import("arch/riscv64/paging.zig");
    const mem = @import("mem.zig");
    const addr = global_mmio_base + @as(u64, offset);
    return if (paging_mod.isInitialized()) addr +% mem.KERNEL_VIRT_BASE else addr;
}

/// Set the global MMIO base for virtio I/O helpers (called during initDevice on riscv64).
pub fn setMmioBase(base: u64) void {
    global_mmio_base = base;
}

pub fn getMmioBase() u64 {
    const paging_mod = @import("arch/riscv64/paging.zig");
    const mem = @import("mem.zig");
    return if (paging_mod.isInitialized()) global_mmio_base +% mem.KERNEL_VIRT_BASE else global_mmio_base;
}
