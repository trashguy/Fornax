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

const RX_QUEUE = 0;
const TX_QUEUE = 1;
const RX_BUFFERS = 16;
const TX_BUFFERS = 16;
const FRAME_SIZE = 1514 + 10; // Max Ethernet frame + virtio-net header

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
    initialized: bool,
    /// Index of the RX buffer to recycle on next poll (0xFF = none pending).
    pending_recycle: u8,
};

var net_dev: NetDevice = .{
    .dev = undefined,
    .rx_queue = null,
    .tx_queue = null,
    .mac = .{ 0, 0, 0, 0, 0, 0 },
    .rx_buffers = .{0} ** RX_BUFFERS,
    .initialized = false,
    .pending_recycle = 0xFF,
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

    // Negotiate features — we want MAC and basic packet support
    // Don't request MRG_RXBUF to keep things simple
    virtio.finishInit(&dev, virtio.VIRTIO_NET_F_MAC | virtio.VIRTIO_NET_F_STATUS);

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

/// Send a raw Ethernet frame.
/// `data` should NOT include the virtio-net header — this function prepends it.
pub fn send(data: []const u8) bool {
    if (!net_dev.initialized) return false;
    if (data.len > 1514) return false; // Max Ethernet frame

    const tx = &(net_dev.tx_queue.?);

    // Allocate a page for the TX buffer
    const buf_phys = pmm.allocPage() orelse return false;
    // Use higher-half pointer — identity-map may have been modified by user
    // ELF mappings (huge page splits), so @ptrFromInt(buf_phys) can write
    // to the wrong physical page.
    const buf: [*]u8 = paging.physPtr(buf_phys);

    // Write virtio-net header (all zeros = no offloading)
    const hdr_size = @sizeOf(VirtioNetHeader);
    @memset(buf[0..hdr_size], 0);

    // Copy frame data after header
    @memcpy(buf[hdr_size..][0..data.len], data);

    const total_len: u32 = @intCast(hdr_size + data.len);

    // Add to TX queue
    _ = virtio.addBuffer(tx, buf_phys, total_len, false) orelse {
        pmm.freePage(buf_phys);
        return false;
    };

    // Re-arm RX descriptors before TX notify — the TX triggers SLIRP to
    // respond (ARP reply, TCP SYN-ACK), and the device reads RX descriptors
    // to deliver the response.  On aarch64, descriptors may be corrupted.
    rearmRxDescs();

    virtio.notify(tx);

    // Poll for TX completion so we can free the buffer page.
    var spins: u32 = 0;
    while (virtio.pollUsed(tx) == null) : (spins += 1) {
        if (spins > 10_000_000) {
            klog.err("virtio-net: TX timeout\n");
            tx.next_desc = 0;
            pmm.freePage(buf_phys);
            return false;
        }
        if (spins % 4096 == 0) {
            // On QEMU TCG, virtio TX is processed in a bottom-half that
            // only runs when QEMU's main loop iterates.  Halting the vCPU
            // (wfi/hlt) forces QEMU to exit the execution loop and process
            // pending bottom-halves.  Brief enable/halt/disable keeps the
            // re-entrancy window minimal.
            cpu.enableInterrupts();
            cpu.hltOnce();
            cpu.disableInterrupts();
        } else {
            cpu.spinHint();
        }
    }

    // Synchronous TX complete — recycle descriptor for next send
    tx.next_desc = 0;

    pmm.freePage(buf_phys);
    return true;
}

/// Poll for received packets. Returns the data portion (after virtio-net header) or null.
pub fn poll() ?[]u8 {
    if (!net_dev.initialized) return null;

    const rx = &(net_dev.rx_queue.?);

    // Recycle the previous RX buffer before polling for a new one.
    // The caller has finished processing the frame returned by the last poll().
    if (net_dev.pending_recycle != 0xFF) {
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
        net_dev.pending_recycle = 0xFF;
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
