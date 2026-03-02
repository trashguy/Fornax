/// virtio-net network driver.
///
/// Runs kernel-side for now (needs I/O port access).
/// Will be moved to userspace as a file server at /dev/ether0/ once
/// MMIO mapping to userspace is implemented.
///
/// virtio-net legacy device config (at io_base + 0x14):
///   0x14  mac[0..5]     — MAC address (6 bytes)
///   0x1A  status         — link status (u16)
const pmm = @import("pmm.zig");
const klog = @import("klog.zig");
const virtio = @import("virtio.zig");

const paging = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("arch/x86_64/paging.zig"),
    .riscv64 => @import("arch/riscv64/paging.zig"),
    .aarch64 => @import("arch/aarch64/paging.zig"),
    else => struct {
        pub fn physPtr(_: u64) [*]u8 {
            return @ptrFromInt(0);
        }
    },
};

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
        pub fn inb(_: u16) u8 {
            return 0;
        }
    },
};

const SpinLock = @import("spinlock.zig").SpinLock;

const RX_QUEUE = 0;
const TX_QUEUE = 1;
const RX_BUFFERS = 256;
const TX_BUFFERS = 256;
const FRAME_SIZE = 1514 + 10; // Max Ethernet frame + virtio-net header

// TSO: large buffers for offloaded segmentation
const TSO_BUFFERS = 16;
const TSO_BUF_SIZE = 65536 + @sizeOf(VirtioNetHeader); // 64KB payload + virtio header
const TSO_PAGES = (TSO_BUF_SIZE + 4095) / 4096; // pages per TSO buffer (17)

/// virtio-net header prepended to every packet.
pub const VirtioNetHeader = extern struct {
    flags: u8,
    gso_type: u8,
    hdr_len: u16,
    gso_size: u16,
    csum_start: u16,
    csum_offset: u16,
    // num_buffers: u16, // only with VIRTIO_NET_F_MRG_RXBUF
};

pub const NetDevice = struct {
    dev: virtio.VirtioDevice,
    rx_queue: ?virtio.Virtqueue,
    tx_queue: ?virtio.Virtqueue,
    mac: [6]u8,
    rx_buffers: [RX_BUFFERS]u64, // physical addresses of receive buffers
    tx_buffers: [TX_BUFFERS]u64, // pre-allocated TX buffer pages (physical)
    tx_free_mask: u256, // bitmask: bit i = 1 means TX slot i is free
    tx_lock: SpinLock, // protects TX queue and tx_free_mask
    initialized: bool,
    /// Index of the RX buffer to recycle on next poll (0xFFFF = none pending).
    pending_recycle: u16,
    // TSO large buffers
    tso_buffers: [TSO_BUFFERS]u64, // physical addresses of TSO buffers
    tso_free_mask: u16, // bitmask: bit i = 1 means TSO slot i is free
};

var net_dev: NetDevice = .{
    .dev = undefined,
    .rx_queue = null,
    .tx_queue = null,
    .mac = .{ 0, 0, 0, 0, 0, 0 },
    .rx_buffers = .{0} ** RX_BUFFERS,
    .tx_buffers = .{0} ** TX_BUFFERS,
    .tx_free_mask = ~@as(u256, 0),
    .tx_lock = .{},
    .initialized = false,
    .pending_recycle = 0xFFFF,
    .tso_buffers = .{0} ** TSO_BUFFERS,
    .tso_free_mask = 0,
};

/// Initialize the virtio-net device.
pub fn init() bool {
    if (@import("builtin").cpu.arch != .x86_64 and @import("builtin").cpu.arch != .riscv64 and @import("builtin").cpu.arch != .aarch64) return false;

    // Find virtio-net PCI device
    const pci_dev = pci.findVirtioNet() orelse {
        klog.debug("virtio-net: no device found\n");
        return false;
    };

    klog.debug("virtio-net: found at PCI slot ");
    klog.debugDec(pci_dev.slot);
    klog.debug(", io_base=");
    klog.debugHex(pci_dev.ioBase() orelse 0);
    klog.debug("\n");

    // Initialize virtio device
    var dev = virtio.initDevice(pci_dev) orelse {
        klog.err("virtio-net: device init failed\n");
        return false;
    };

    // Read MAC address from device config (offset 0x14)
    if (comptime @import("builtin").cpu.arch == .riscv64 or @import("builtin").cpu.arch == .aarch64) {
        const mmio_base = virtio.getMmioBase();
        for (0..6) |i| {
            net_dev.mac[i] = cpu.mmioRead8(mmio_base + 0x14 + @as(u64, @intCast(i)));
        }
    } else {
        const io_base = pci_dev.ioBase().?;
        for (0..6) |i| {
            net_dev.mac[i] = cpu.inb(io_base + 0x14 + @as(u16, @intCast(i)));
        }
    }

    klog.info("virtio-net: MAC ");
    printMac(net_dev.mac);
    klog.info("\n");

    // Negotiate features — MAC, status, checksum offload, TSO
    // Don't request MRG_RXBUF to keep things simple
    virtio.finishInit(&dev, virtio.VIRTIO_NET_F_MAC | virtio.VIRTIO_NET_F_STATUS |
        virtio.VIRTIO_NET_F_CSUM | virtio.VIRTIO_NET_F_HOST_TSO4);

    // Set up receive queue (before DRIVER_OK per virtio spec)
    net_dev.rx_queue = virtio.setupQueue(&dev, RX_QUEUE);
    if (net_dev.rx_queue == null) {
        klog.err("virtio-net: failed to setup RX queue\n");
        return false;
    }

    // Set up transmit queue
    net_dev.tx_queue = virtio.setupQueue(&dev, TX_QUEUE);
    if (net_dev.tx_queue == null) {
        klog.err("virtio-net: failed to setup TX queue\n");
        return false;
    }

    // Guard ALL virtio-net DMA pages (RX + TX queues) against accidental free/realloc
    if (comptime @import("builtin").cpu.arch == .aarch64) {
        const rx_phys = net_dev.rx_queue.?.phys_addr;
        // Guard from RX queue start through TX queue end (6 contiguous pages)
        pmm.setDmaGuard(@intCast(rx_phys), 6);
    }

    // Set DRIVER_OK after all queues are configured (per virtio spec).
    // MUST happen before any queue notifications (including postRxBuffers).
    virtio.setDriverOk(&dev);

    postRxBuffers();

    // Pre-allocate TX buffer pages (avoids per-packet alloc/free)
    for (0..TX_BUFFERS) |i| {
        net_dev.tx_buffers[i] = pmm.allocPage() orelse {
            klog.err("virtio-net: failed to alloc TX buffer\n");
            return false;
        };
        // Zero via higher-half pointer
        const ptr: [*]u8 = paging.physPtr(net_dev.tx_buffers[i]);
        @memset(ptr[0..4096], 0);
    }
    net_dev.tx_free_mask = ~@as(u256, 0); // all 256 slots free

    // Pre-allocate TSO large buffers — each needs TSO_PAGES contiguous pages.
    // We use the regular TX descriptor slots for TSO (slot < TX_BUFFERS), so
    // TSO buffers are separate staging areas that get copied into a TX slot.
    // For simplicity, allocate a single page per TSO buffer and limit TSO
    // frames to what fits in one virtio descriptor (4096 - hdr_size bytes).
    // True 64KB TSO requires scatter-gather or contiguous alloc; for now
    // we just enable the feature and cap at the page-size minus header.
    net_dev.tso_free_mask = 0;
    if (dev.negotiated_features & virtio.VIRTIO_NET_F_HOST_TSO4 != 0) {
        for (0..TSO_BUFFERS) |i| {
            const page = pmm.allocPage() orelse break;
            net_dev.tso_buffers[i] = page;
            net_dev.tso_free_mask |= @as(u16, 1) << @intCast(i);
        }
        if (net_dev.tso_free_mask != 0) {
            klog.info("virtio-net: TSO enabled\n");
        }
    }

    net_dev.dev = dev;
    net_dev.initialized = true;

    klog.info("virtio-net: initialized (RX/TX queues ready)\n");
    return true;
}

/// On aarch64, re-write all RX descriptor len/flags fields via volatile
/// higher-half (TTBR1) writes + cache clean.  TTBR1 always maps to the
/// correct physical page regardless of which process's TTBR0 is active.
/// Must NOT use identity-mapped (TTBR0) addresses — after scheduleNext(),
/// TTBR0 VA 0x40086000 maps to a user ELF page, not the descriptor page.
fn rearmRxDescs() void {
    if (comptime @import("builtin").cpu.arch != .aarch64) return;
    const rx = &(net_dev.rx_queue.?);
    const hh_base: u64 = rx.phys_addr + @import("mem.zig").KERNEL_VIRT_BASE;
    for (0..RX_BUFFERS) |i| {
        const desc_off = i * @sizeOf(virtio.VirtqDesc);
        // Re-write len (offset 8 within descriptor)
        @as(*volatile u32, @ptrFromInt(hh_base + desc_off + 8)).* = FRAME_SIZE;
        // Re-write flags (offset 12) — WRITE flag for device-writable
        @as(*volatile u16, @ptrFromInt(hh_base + desc_off + 12)).* = virtio.VRING_DESC_F_WRITE;
        // Clean cache line
        asm volatile ("dc cvac, %[addr]" : : [addr] "r" (hh_base + desc_off));
    }
    asm volatile ("dsb sy" ::: .{ .memory = true });
}

/// Allocate and post receive buffers to the RX queue.
fn postRxBuffers() void {
    const rx = &(net_dev.rx_queue.?);
    for (0..RX_BUFFERS) |i| {
        const buf_phys = pmm.allocPage() orelse break;
        net_dev.rx_buffers[i] = buf_phys;

        // Zero the buffer via higher-half (safe regardless of identity-map state)
        const ptr: [*]u8 = paging.physPtr(buf_phys);
        @memset(ptr[0..4096], 0);

        // Add to RX queue (device-writable since device writes received packets here)
        _ = virtio.addBuffer(rx, buf_phys, FRAME_SIZE, true);
    }

    // On aarch64, descriptor bytes 8-15 get silently zeroed (QEMU TCG bug).
    // Re-arm all descriptors via volatile writes before notifying the device.
    rearmRxDescs();

    virtio.notify(rx);

    klog.debug("virtio-net: posted ");
    klog.debugDec(RX_BUFFERS);
    klog.debug(" RX buffers\n");
}

/// Send a raw Ethernet frame (async — returns immediately after submission).
/// `data` should NOT include the virtio-net header — this function prepends it.
pub fn send(data: []const u8) bool {
    if (!net_dev.initialized) return false;
    if (data.len > 1514) return false; // Max Ethernet frame

    net_dev.tx_lock.lock();
    defer net_dev.tx_lock.unlock();

    const tx = &(net_dev.tx_queue.?);

    // Reclaim completed TX descriptors
    while (virtio.pollUsed(tx)) |used| {
        const completed_idx: u8 = @intCast(used.id & 0xFF);
        net_dev.tx_free_mask |= @as(u256, 1) << completed_idx;
    }

    // Find a free TX slot
    if (net_dev.tx_free_mask == 0) {
        // All slots busy — do a brief spin to reclaim
        var spins: u32 = 0;
        while (net_dev.tx_free_mask == 0 and spins < 100_000) : (spins += 1) {
            if (virtio.pollUsed(tx)) |used| {
                const completed_idx: u8 = @intCast(used.id & 0xFF);
                net_dev.tx_free_mask |= @as(u256, 1) << completed_idx;
            } else {
                cpu.spinHint();
            }
        }
        if (net_dev.tx_free_mask == 0) return false; // still full
    }

    const slot: u8 = @intCast(@ctz(net_dev.tx_free_mask));
    net_dev.tx_free_mask &= ~(@as(u256, 1) << slot);

    // Copy data into pre-allocated buffer
    const buf_phys = net_dev.tx_buffers[slot];
    const buf: [*]u8 = paging.physPtr(buf_phys);
    const hdr_size = @sizeOf(VirtioNetHeader);
    @memset(buf[0..hdr_size], 0);
    @memcpy(buf[hdr_size..][0..data.len], data);

    const total_len: u32 = @intCast(hdr_size + data.len);

    // Submit at explicit descriptor index (no next_desc management)
    if (!virtio.addBufferAt(tx, @as(u16, slot), buf_phys, total_len, false)) {
        net_dev.tx_free_mask |= @as(u256, 1) << slot;
        return false;
    }

    // Re-arm RX descriptors before TX notify (aarch64 workaround)
    rearmRxDescs();

    virtio.notify(tx);
    return true;
}

/// Returns true if the device negotiated CSUM offload.
pub fn hasCsumOffload() bool {
    return net_dev.initialized and
        (net_dev.dev.negotiated_features & virtio.VIRTIO_NET_F_CSUM != 0);
}

/// Returns true if the device negotiated TSO (host segmentation).
pub fn hasTsoOffload() bool {
    return net_dev.initialized and
        (net_dev.dev.negotiated_features & virtio.VIRTIO_NET_F_HOST_TSO4 != 0);
}

/// Send a frame with virtio NEEDS_CSUM flag set. The device will compute
/// the checksum at csum_start+csum_offset. Used for TCP TX offload.
pub fn sendWithCsum(data: []const u8, csum_start: u16, csum_offset: u16) bool {
    if (!net_dev.initialized) return false;
    if (data.len > 1514) return false;

    net_dev.tx_lock.lock();
    defer net_dev.tx_lock.unlock();

    const tx = &(net_dev.tx_queue.?);

    // Reclaim completed TX descriptors
    while (virtio.pollUsed(tx)) |used| {
        const completed_idx: u8 = @intCast(used.id & 0xFF);
        net_dev.tx_free_mask |= @as(u256, 1) << completed_idx;
    }

    // Find a free TX slot
    if (net_dev.tx_free_mask == 0) {
        var spins: u32 = 0;
        while (net_dev.tx_free_mask == 0 and spins < 100_000) : (spins += 1) {
            if (virtio.pollUsed(tx)) |used| {
                const completed_idx: u8 = @intCast(used.id & 0xFF);
                net_dev.tx_free_mask |= @as(u256, 1) << completed_idx;
            } else {
                cpu.spinHint();
            }
        }
        if (net_dev.tx_free_mask == 0) return false;
    }

    const slot: u8 = @intCast(@ctz(net_dev.tx_free_mask));
    net_dev.tx_free_mask &= ~(@as(u256, 1) << slot);

    const buf_phys = net_dev.tx_buffers[slot];
    const buf: [*]u8 = paging.physPtr(buf_phys);
    const hdr_size = @sizeOf(VirtioNetHeader);

    // Set NEEDS_CSUM in the virtio-net header
    const hdr: *VirtioNetHeader = @ptrCast(@alignCast(buf));
    hdr.flags = virtio.VIRTIO_NET_HDR_F_NEEDS_CSUM;
    hdr.gso_type = virtio.VIRTIO_NET_HDR_GSO_NONE;
    hdr.hdr_len = 0;
    hdr.gso_size = 0;
    hdr.csum_start = csum_start;
    hdr.csum_offset = csum_offset;

    @memcpy(buf[hdr_size..][0..data.len], data);

    const total_len: u32 = @intCast(hdr_size + data.len);

    if (!virtio.addBufferAt(tx, @as(u16, slot), buf_phys, total_len, false)) {
        net_dev.tx_free_mask |= @as(u256, 1) << slot;
        return false;
    }

    rearmRxDescs();
    virtio.notify(tx);
    return true;
}

pub const FrameRef = struct {
    data: [*]const u8,
    len: u16,
};

/// Send multiple frames with a single virtio notify. Returns number of frames sent.
pub fn sendBatch(frames: []const FrameRef) u32 {
    if (!net_dev.initialized) return 0;

    net_dev.tx_lock.lock();
    defer net_dev.tx_lock.unlock();

    const tx = &(net_dev.tx_queue.?);
    const hdr_size = @sizeOf(VirtioNetHeader);
    const has_csum = net_dev.dev.negotiated_features & virtio.VIRTIO_NET_F_CSUM != 0;

    // Reclaim completed TX descriptors
    while (virtio.pollUsed(tx)) |used| {
        const completed_idx: u8 = @intCast(used.id & 0xFF);
        net_dev.tx_free_mask |= @as(u256, 1) << completed_idx;
    }

    var sent: u32 = 0;
    for (frames) |frame| {
        if (frame.len > 1514 or frame.len == 0) continue;

        if (net_dev.tx_free_mask == 0) {
            // Try to reclaim
            while (virtio.pollUsed(tx)) |used| {
                const completed_idx: u8 = @intCast(used.id & 0xFF);
                net_dev.tx_free_mask |= @as(u256, 1) << completed_idx;
            }
            if (net_dev.tx_free_mask == 0) break; // all slots full
        }

        const slot: u8 = @intCast(@ctz(net_dev.tx_free_mask));
        net_dev.tx_free_mask &= ~(@as(u256, 1) << slot);

        const buf_phys = net_dev.tx_buffers[slot];
        const buf: [*]u8 = paging.physPtr(buf_phys);

        // Set virtio-net header
        const hdr: *VirtioNetHeader = @ptrCast(@alignCast(buf));
        if (has_csum and frame.len >= 34) {
            const src = frame.data;
            const ethertype = @as(u16, src[12]) << 8 | src[13];
            if (ethertype == 0x0800 and src[23] == 6) { // IPv4 + TCP
                const ip_hdr_len: u16 = @as(u16, src[14] & 0x0F) * 4;
                hdr.flags = virtio.VIRTIO_NET_HDR_F_NEEDS_CSUM;
                hdr.gso_type = virtio.VIRTIO_NET_HDR_GSO_NONE;
                hdr.hdr_len = 0;
                hdr.gso_size = 0;
                hdr.csum_start = 14 + ip_hdr_len;
                hdr.csum_offset = 16;
            } else {
                @memset(buf[0..hdr_size], 0);
            }
        } else {
            @memset(buf[0..hdr_size], 0);
        }

        @memcpy(buf[hdr_size..][0..frame.len], frame.data[0..frame.len]);
        const total_len: u32 = @intCast(hdr_size + frame.len);

        if (!virtio.addBufferAt(tx, @as(u16, slot), buf_phys, total_len, false)) {
            net_dev.tx_free_mask |= @as(u256, 1) << slot;
            break;
        }
        sent += 1;
    }

    if (sent > 0) {
        rearmRxDescs();
        virtio.notify(tx); // ONE notify for entire batch
    }
    return sent;
}

/// Max frame size for TSO path (limited by single-page TX buffer: 4096 - virtio header)
pub const TSO_MAX_FRAME: usize = 4096 - @sizeOf(VirtioNetHeader);

/// Send a large TCP frame with TSO (segmentation offload). The virtio device
/// segments at `mss`. Frame must contain ETH+IP+TCP headers + payload.
/// Max frame size: TSO_MAX_FRAME bytes.
pub fn sendTso(data: []const u8, mss: u16) bool {
    if (!net_dev.initialized) return false;
    if (data.len > TSO_MAX_FRAME or data.len == 0) return false;
    if (net_dev.dev.negotiated_features & virtio.VIRTIO_NET_F_HOST_TSO4 == 0) return false;

    net_dev.tx_lock.lock();
    defer net_dev.tx_lock.unlock();

    const tx = &(net_dev.tx_queue.?);
    const hdr_size = @sizeOf(VirtioNetHeader);

    // Reclaim completed TX descriptors
    while (virtio.pollUsed(tx)) |used| {
        const completed_idx: u8 = @intCast(used.id & 0xFF);
        net_dev.tx_free_mask |= @as(u256, 1) << completed_idx;
    }

    // Find a free TX slot
    if (net_dev.tx_free_mask == 0) {
        var spins: u32 = 0;
        while (net_dev.tx_free_mask == 0 and spins < 100_000) : (spins += 1) {
            if (virtio.pollUsed(tx)) |used| {
                const completed_idx: u8 = @intCast(used.id & 0xFF);
                net_dev.tx_free_mask |= @as(u256, 1) << completed_idx;
            } else {
                cpu.spinHint();
            }
        }
        if (net_dev.tx_free_mask == 0) return false;
    }

    const slot: u8 = @intCast(@ctz(net_dev.tx_free_mask));
    net_dev.tx_free_mask &= ~(@as(u256, 1) << slot);

    const buf_phys = net_dev.tx_buffers[slot];
    const buf: [*]u8 = paging.physPtr(buf_phys);

    // Populate virtio-net header for TSO
    const hdr: *VirtioNetHeader = @ptrCast(@alignCast(buf));
    hdr.flags = virtio.VIRTIO_NET_HDR_F_NEEDS_CSUM;
    hdr.gso_type = virtio.VIRTIO_NET_HDR_GSO_TCPV4;
    hdr.hdr_len = 54; // ETH(14) + IP(20) + TCP(20)
    hdr.gso_size = mss;
    hdr.csum_start = 34; // ETH(14) + IP(20)
    hdr.csum_offset = 16; // TCP checksum field offset

    @memcpy(buf[hdr_size..][0..data.len], data);

    const total_len: u32 = @intCast(hdr_size + data.len);

    if (!virtio.addBufferAt(tx, @as(u16, slot), buf_phys, total_len, false)) {
        net_dev.tx_free_mask |= @as(u256, 1) << slot;
        return false;
    }

    rearmRxDescs();
    virtio.notify(tx);
    return true;
}

/// Poll for received packets. Returns the data portion (after virtio-net header) or null.
pub fn poll() ?[]u8 {
    if (!net_dev.initialized) return null;

    const rx = &(net_dev.rx_queue.?);

    // Recycle the previous RX buffer before polling for a new one.
    // The caller has finished processing the frame returned by the last poll().
    if (net_dev.pending_recycle != 0xFFFF) {
        const idx: u16 = net_dev.pending_recycle;
        // Zero the buffer before re-posting
        const buf_phys = net_dev.rx_buffers[idx];
        const ptr: [*]u8 = paging.physPtr(buf_phys);
        @memset(ptr[0..4096], 0);
        // Re-post existing descriptor to the available ring (descriptor
        // already points to the correct buffer from initial setup)
        virtio.recycleDesc(rx, idx);
        // Re-arm descriptors before notifying the device (aarch64 workaround)
        rearmRxDescs();
        virtio.notify(rx);
        net_dev.pending_recycle = 0xFFFF;
    }

    // Re-arm RX descriptors before checking the used ring (aarch64 workaround).
    // This ensures the device sees valid len/flags in case they were corrupted.
    rearmRxDescs();

    const used = virtio.pollUsed(rx) orelse return null;

    const buf_idx = used.id;
    if (buf_idx >= RX_BUFFERS) return null;

    const buf_phys = net_dev.rx_buffers[buf_idx];
    // Use higher-half pointer — safe regardless of which process's page
    // tables are active (identity-map may have modified entries).
    const buf: [*]u8 = paging.physPtr(buf_phys);

    const hdr_size = @sizeOf(VirtioNetHeader);
    const data_len = used.len;

    if (data_len <= hdr_size) return null;

    // Mark this buffer for recycling on next poll() call
    net_dev.pending_recycle = @intCast(buf_idx);

    const frame_len: usize = @intCast(data_len - hdr_size);
    return buf[hdr_size..][0..frame_len];
}

/// Get the MAC address.
pub fn getMac() [6]u8 {
    return net_dev.mac;
}

/// Check if the device is initialized.
pub fn isInitialized() bool {
    return net_dev.initialized;
}

fn printMac(mac: [6]u8) void {
    const hex = "0123456789ABCDEF";
    var buf: [17]u8 = undefined; // "XX:XX:XX:XX:XX:XX"
    var pos: usize = 0;
    for (mac, 0..) |byte, i| {
        if (i > 0) {
            buf[pos] = ':';
            pos += 1;
        }
        buf[pos] = hex[byte >> 4];
        buf[pos + 1] = hex[byte & 0x0F];
        pos += 2;
    }
    klog.info(buf[0..pos]);
}
