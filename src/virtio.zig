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
    .aarch64 => @import("arch/aarch64/pci.zig"),
    else => struct {
        pub const PciDevice = struct {};
    },
};

const cpu = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("arch/x86_64/cpu.zig"),
    .riscv64 => @import("arch/riscv64/cpu.zig"),
    .aarch64 => @import("arch/aarch64/cpu.zig"),
    else => struct {
        pub fn outb(_: u16, _: u8) void {}
        pub fn inb(_: u16) u8 {
            return 0;
        }
    },
};

const builtin_arch = @import("builtin").cpu.arch;

/// PCI I/O port space is mapped to MMIO at this CPU address.
/// riscv64 virt: device tree ranges → 0x03000000
/// aarch64 virt: device tree ranges → 0x3eff0000
const PCI_IO_WINDOW: u64 = switch (builtin_arch) {
    .aarch64 => 0x3eff_0000,
    else => 0x0300_0000,
};

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
pub const VIRTIO_NET_F_CSUM: u32 = 1 << 0;
pub const VIRTIO_NET_F_GUEST_CSUM: u32 = 1 << 1;
pub const VIRTIO_NET_F_HOST_TSO4: u32 = 1 << 11;
pub const VIRTIO_NET_HDR_F_NEEDS_CSUM: u8 = 1;
pub const VIRTIO_NET_HDR_GSO_NONE: u8 = 0;
pub const VIRTIO_NET_HDR_GSO_TCPV4: u8 = 1;

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

    // On riscv64/aarch64, set the global MMIO address for I/O helpers.
    // I/O BAR port address → PCI I/O window MMIO address.
    if (comptime builtin_arch == .riscv64 or builtin_arch == .aarch64)
        setMmioBase(PCI_IO_WINDOW + @as(u64, io_base));

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

    klog.debug("virtio: negotiated features = ");
    klog.debugHex(dev.negotiated_features);
    klog.debug("\n");
}

/// Set DRIVER_OK status. Call this AFTER setting up all virtqueues.
pub fn setDriverOk(dev: *VirtioDevice) void {
    write8(dev.io_base, REG_DEVICE_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_DRIVER_OK);
    klog.debug("virtio: status = DRIVER_OK\n");
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

    klog.debug("virtio: q");
    klog.debugDec(queue_index);
    klog.debug(" io=");
    klog.debugHex(dev.io_base);
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

    klog.debug("virtio: q");
    klog.debugDec(queue_index);
    klog.debug(" phys=");
    klog.debugHex(@as(u32, @truncate(phys_addr)));
    klog.debug(" pages=");
    klog.debugDec(total_pages);
    klog.debug("\n");

    // Use higher-half pointers for CPU access — immune to identity-map modifications
    // by user ELF mappings (huge page splits in per-process page tables).
    const base: u64 = first_page + @import("mem.zig").KERNEL_VIRT_BASE;

    // Zero all queue memory
    const ptr: [*]u8 = @ptrFromInt(base);
    @memset(ptr[0 .. total_pages * 4096], 0);

    // On aarch64, the @memset may use SIMD stores that go through a different
    // softmmu path in QEMU TCG than the scalar stores used in addBuffer().
    // Flush the TLB so subsequent scalar stores get fresh translations.
    if (@import("builtin").cpu.arch == .aarch64) {
        asm volatile ("dsb sy" ::: .{ .memory = true });
        asm volatile ("tlbi vmalle1" ::: .{ .memory = true });
        asm volatile ("dsb sy" ::: .{ .memory = true });
        asm volatile ("isb" ::: .{ .memory = true });
    }

    // Set up pointers (all higher-half)
    const desc_ptr: [*]VirtqDesc = @ptrFromInt(base);
    const avail_ptr: *VirtqAvail = @ptrFromInt(base + desc_size);
    const avail_ring_ptr: [*]u16 = @ptrFromInt(base + desc_size + 4);
    const used_virt = (base + desc_size + avail_size + 4095) & ~@as(usize, 4095);
    const used_ptr: *VirtqUsed = @ptrFromInt(used_virt);
    const used_ring_ptr: [*]VirtqUsedElem = @ptrFromInt(used_virt + 4);

    // Tell device the queue address (in units of 4096 bytes)
    const pfn: u32 = @intCast(phys_addr / 4096);
    write32(dev.io_base, REG_QUEUE_ADDRESS, pfn);

    // Verify PFN was accepted — read it back (legacy virtio PCI allows this)
    const readback = read32(dev.io_base, REG_QUEUE_ADDRESS);
    if (readback != pfn) {
        klog.err("virtio: queue ");
        klog.errDec(queue_index);
        klog.err(" PFN mismatch: wrote ");
        klog.errHex(pfn);
        klog.err(" read ");
        klog.errHex(readback);
        klog.err("\n");
    }

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

    // Write descriptor fields via volatile to prevent reordering/elision.
    const desc: *volatile VirtqDesc = @ptrCast(&vq.desc[idx]);
    desc.addr = phys_addr;
    desc.len = len;
    desc.flags = if (device_writable) VRING_DESC_F_WRITE else 0;
    desc.next = 0;

    // AArch64: clean the descriptor cache line to PoC so QEMU TCG's DMA
    // sees the writes even after a TTBR0 switch flushes the softmmu TLB.
    if (comptime @import("builtin").cpu.arch == .aarch64) {
        asm volatile ("dc cvac, %[addr]" : : [addr] "r" (@intFromPtr(desc)));
        asm volatile ("dsb sy" ::: .{ .memory = true });
    }

    // Add to available ring
    const avail_idx = @as(*volatile u16, @ptrCast(&vq.avail.idx)).*;
    @as(*volatile u16, @ptrFromInt(@intFromPtr(&vq.avail_ring[avail_idx % vq.size]))).* = idx;

    memoryBarrier();

    @as(*volatile u16, @ptrCast(&vq.avail.idx)).* = avail_idx +% 1;

    // Clean avail ring writes to PoC (aarch64 DMA coherency)
    if (comptime @import("builtin").cpu.arch == .aarch64) {
        asm volatile ("dc cvac, %[addr]" : : [addr] "r" (@intFromPtr(&vq.avail.idx)));
        asm volatile ("dsb sy" ::: .{ .memory = true });
    }

    vq.next_desc = idx + 1;

    return idx;
}

/// Add a buffer at a specific descriptor index (for pre-allocated TX pools).
/// Unlike `addBuffer`, does NOT increment `next_desc` — caller manages descriptor ownership.
pub fn addBufferAt(vq: *Virtqueue, idx: u16, phys_addr: u64, len: u32, device_writable: bool) bool {
    if (idx >= vq.size) return false;

    const desc: *volatile VirtqDesc = @ptrCast(&vq.desc[idx]);
    desc.addr = phys_addr;
    desc.len = len;
    desc.flags = if (device_writable) VRING_DESC_F_WRITE else 0;
    desc.next = 0;

    if (comptime @import("builtin").cpu.arch == .aarch64) {
        asm volatile ("dc cvac, %[addr]" : : [addr] "r" (@intFromPtr(desc)));
        asm volatile ("dsb sy" ::: .{ .memory = true });
    }

    const avail_idx = @as(*volatile u16, @ptrCast(&vq.avail.idx)).*;
    @as(*volatile u16, @ptrFromInt(@intFromPtr(&vq.avail_ring[avail_idx % vq.size]))).* = idx;

    memoryBarrier();

    @as(*volatile u16, @ptrCast(&vq.avail.idx)).* = avail_idx +% 1;

    if (comptime @import("builtin").cpu.arch == .aarch64) {
        asm volatile ("dc cvac, %[addr]" : : [addr] "r" (@intFromPtr(&vq.avail.idx)));
        asm volatile ("dsb sy" ::: .{ .memory = true });
    }

    return true;
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

    const d0: *volatile VirtqDesc = @ptrCast(&vq.desc[head]);
    d0.addr = addr0;
    d0.len = len0;
    d0.flags = (if (writable0) VRING_DESC_F_WRITE else 0) | VRING_DESC_F_NEXT;
    d0.next = head + 1;

    const d1: *volatile VirtqDesc = @ptrCast(&vq.desc[head + 1]);
    d1.addr = addr1;
    d1.len = len1;
    d1.flags = (if (writable1) VRING_DESC_F_WRITE else 0) | VRING_DESC_F_NEXT;
    d1.next = head + 2;

    const d2: *volatile VirtqDesc = @ptrCast(&vq.desc[head + 2]);
    d2.addr = addr2;
    d2.len = len2;
    d2.flags = if (writable2) VRING_DESC_F_WRITE else 0;
    d2.next = 0;

    // AArch64: clean descriptor cache lines to PoC (see docs/aarch64-gotchas.md §2)
    if (comptime @import("builtin").cpu.arch == .aarch64) {
        asm volatile ("dc cvac, %[addr]" : : [addr] "r" (@intFromPtr(d0)));
        asm volatile ("dc cvac, %[addr]" : : [addr] "r" (@intFromPtr(d1)));
        asm volatile ("dc cvac, %[addr]" : : [addr] "r" (@intFromPtr(d2)));
        asm volatile ("dsb sy" ::: .{ .memory = true });
    }

    // Add head to available ring
    const avail_idx = @as(*volatile u16, @ptrCast(&vq.avail.idx)).*;
    @as(*volatile u16, @ptrFromInt(@intFromPtr(&vq.avail_ring[avail_idx % vq.size]))).* = head;

    memoryBarrier();

    @as(*volatile u16, @ptrCast(&vq.avail.idx)).* = avail_idx +% 1;

    // Clean avail ring writes to PoC (aarch64 DMA coherency)
    if (comptime @import("builtin").cpu.arch == .aarch64) {
        asm volatile ("dc cvac, %[addr]" : : [addr] "r" (@intFromPtr(&vq.avail.idx)));
        asm volatile ("dsb sy" ::: .{ .memory = true });
    }

    vq.next_desc = head + 3;

    return head;
}

/// Notify the device that there are new available buffers.
pub fn notify(vq: *Virtqueue) void {
    // Ensure all descriptor/avail ring writes are visible before notifying device
    memoryBarrier();
    write16(vq.io_base, REG_QUEUE_NOTIFY, vq.queue_index);
}

/// Check if the device has returned any used buffers.
pub fn pollUsed(vq: *Virtqueue) ?VirtqUsedElem {
    // Memory barrier — ensure we see the latest used index
    memoryBarrier();

    // Volatile read of used.idx to prevent compiler from caching the value
    const used_idx = @as(*volatile u16, @ptrCast(&vq.used.idx)).*;
    if (vq.last_used_idx == used_idx) return null;

    const elem_ptr: *volatile VirtqUsedElem = @ptrCast(&vq.used_ring[vq.last_used_idx % vq.size]);
    const elem = elem_ptr.*;
    vq.last_used_idx +%= 1;
    return elem;
}

/// Re-post an existing descriptor to the available ring without allocating a new
/// descriptor slot. Used for recycling RX buffers that have already been set up.
pub fn recycleDesc(vq: *Virtqueue, desc_idx: u16) void {
    const avail_idx = @as(*volatile u16, @ptrCast(&vq.avail.idx)).*;
    const ring_slot: *volatile u16 = @ptrCast(&vq.avail_ring[avail_idx % vq.size]);
    ring_slot.* = desc_idx;
    memoryBarrier();
    @as(*volatile u16, @ptrCast(&vq.avail.idx)).* = avail_idx +% 1;

    // Clean avail ring writes to PoC (aarch64 DMA coherency)
    if (comptime @import("builtin").cpu.arch == .aarch64) {
        asm volatile ("dc cvac, %[addr]" : : [addr] "r" (@intFromPtr(&vq.avail.idx)));
        asm volatile ("dsb sy" ::: .{ .memory = true });
    }
}

/// Read the ISR status register (clears interrupt).
pub fn readIsr(dev: *VirtioDevice) u8 {
    return read8(dev.io_base, REG_ISR_STATUS);
}

/// Force an I/O access to the device.  In emulators (QEMU TCG), MMIO/PIO
/// accesses exit the translation block, giving the event loop a chance to
/// run pending bottom-halves (e.g. virtio-net TX completion).  Call this
/// periodically in spin-wait loops that poll for used descriptors.
pub fn ioKick(vq: *Virtqueue) void {
    _ = read8(vq.io_base, REG_ISR_STATUS);
}

pub fn memoryBarrier() void {
    switch (@import("builtin").cpu.arch) {
        .x86_64 => asm volatile ("mfence" ::: .{ .memory = true }),
        // dsb sy — Data Synchronization Barrier: ensures all memory writes
        // (including DMA-visible stores to descriptor/avail rings) complete
        // before subsequent MMIO writes (e.g. queue notify) reach the device.
        // Linux virtio uses dsb sy here; dmb sy only orders accesses as seen
        // by the CPU and is insufficient for device-visible ordering.
        .aarch64 => asm volatile ("dsb sy" ::: .{ .memory = true }),
        .riscv64 => asm volatile ("fence rw, rw" ::: .{ .memory = true }),
        else => {},
    }
}

// I/O helpers for legacy virtio.
// x86_64: I/O port. riscv64: MMIO (base comes from VirtioDevice.mmio_base).
fn read8(base: u16, offset: u16) u8 {
    return switch (builtin_arch) {
        .riscv64, .aarch64 => cpu.mmioRead8(mmioDevAddr(base, offset)),
        else => cpu.inb(base + offset),
    };
}

fn read16(base: u16, offset: u16) u16 {
    return switch (builtin_arch) {
        .riscv64, .aarch64 => cpu.mmioRead16(mmioDevAddr(base, offset)),
        else => cpu.inw(base + offset),
    };
}

fn read32(base: u16, offset: u16) u32 {
    return switch (builtin_arch) {
        .riscv64, .aarch64 => cpu.mmioRead32(mmioDevAddr(base, offset)),
        else => cpu.inl(base + offset),
    };
}

fn write8(base: u16, offset: u16, val: u8) void {
    switch (builtin_arch) {
        .riscv64, .aarch64 => cpu.mmioWrite8(mmioDevAddr(base, offset), val),
        else => cpu.outb(base + offset, val),
    }
}

fn write16(base: u16, offset: u16, val: u16) void {
    switch (builtin_arch) {
        .riscv64, .aarch64 => cpu.mmioWrite16(mmioDevAddr(base, offset), val),
        else => cpu.outw(base + offset, val),
    }
}

fn write32(base: u16, offset: u16, val: u32) void {
    switch (builtin_arch) {
        .riscv64, .aarch64 => cpu.mmioWrite32(mmioDevAddr(base, offset), val),
        else => cpu.outl(base + offset, val),
    }
}

/// Global MMIO base for device-config reads during init (getMmioBase).
/// Set by initDevice(), used by virtio_net/virtio_blk for MAC/capacity reads.
/// Queue operations use mmioDevAddr() which computes per-device addresses from PCI_IO_WINDOW.
var global_mmio_base: u64 = 0;

fn mmioDevAddr(base_lo: u16, offset: u16) u64 {
    const paging_mod = switch (builtin_arch) {
        .aarch64 => @import("arch/aarch64/paging.zig"),
        else => @import("arch/riscv64/paging.zig"),
    };
    const mem = @import("mem.zig");
    // Compute address from PCI I/O window + device port base + register offset.
    // This is correct for multi-device scenarios (each virtqueue stores its own io_base).
    const addr = PCI_IO_WINDOW + @as(u64, base_lo) + @as(u64, offset);
    return if (paging_mod.isInitialized()) addr +% mem.KERNEL_VIRT_BASE else addr;
}

/// Set the global MMIO base for virtio I/O helpers (called during initDevice on riscv64).
pub fn setMmioBase(base: u64) void {
    global_mmio_base = base;
}

pub fn getMmioBase() u64 {
    const paging_mod = switch (builtin_arch) {
        .aarch64 => @import("arch/aarch64/paging.zig"),
        else => @import("arch/riscv64/paging.zig"),
    };
    const mem_mod = @import("mem.zig");
    return if (paging_mod.isInitialized()) global_mmio_base +% mem_mod.KERNEL_VIRT_BASE else global_mmio_base;
}
