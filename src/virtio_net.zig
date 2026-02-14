/// virtio-net network driver.
///
/// Runs kernel-side for now (needs I/O port access).
/// Will be moved to userspace as a file server at /dev/ether0/ once
/// MMIO mapping to userspace is implemented.
///
/// virtio-net legacy device config (at io_base + 0x14):
///   0x14  mac[0..5]     — MAC address (6 bytes)
///   0x1A  status         — link status (u16)
const console = @import("console.zig");
const serial = @import("serial.zig");
const pmm = @import("pmm.zig");
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
};

var net_dev: NetDevice = .{
    .dev = undefined,
    .rx_queue = null,
    .tx_queue = null,
    .mac = .{ 0, 0, 0, 0, 0, 0 },
    .rx_buffers = .{0} ** RX_BUFFERS,
    .initialized = false,
};

/// Initialize the virtio-net device.
pub fn init() bool {
    if (@import("builtin").cpu.arch != .x86_64) return false;

    // Find virtio-net PCI device
    const pci_dev = pci.findVirtioNet() orelse {
        serial.puts("virtio-net: no device found\n");
        return false;
    };

    serial.puts("virtio-net: found at PCI slot ");
    serial.putDec(pci_dev.slot);
    serial.puts(", io_base=");
    serial.putHex(pci_dev.ioBase() orelse 0);
    serial.puts("\n");

    // Initialize virtio device
    var dev = virtio.initDevice(pci_dev) orelse {
        serial.puts("virtio-net: device init failed\n");
        return false;
    };

    // Read MAC address from device config (offset 0x14)
    const io_base = pci_dev.ioBase().?;
    for (0..6) |i| {
        net_dev.mac[i] = cpu.inb(io_base + 0x14 + @as(u16, @intCast(i)));
    }

    console.puts("virtio-net: MAC ");
    printMac(net_dev.mac);
    console.puts("\n");

    // Negotiate features — we want MAC and basic packet support
    // Don't request MRG_RXBUF to keep things simple
    virtio.finishInit(&dev, virtio.VIRTIO_NET_F_MAC | virtio.VIRTIO_NET_F_STATUS);

    // Set up receive queue
    net_dev.rx_queue = virtio.setupQueue(&dev, RX_QUEUE);
    if (net_dev.rx_queue == null) {
        serial.puts("virtio-net: failed to setup RX queue\n");
        return false;
    }

    // Set up transmit queue
    net_dev.tx_queue = virtio.setupQueue(&dev, TX_QUEUE);
    if (net_dev.tx_queue == null) {
        serial.puts("virtio-net: failed to setup TX queue\n");
        return false;
    }

    // Post receive buffers
    postRxBuffers();

    net_dev.dev = dev;
    net_dev.initialized = true;

    console.puts("virtio-net: initialized (RX/TX queues ready)\n");
    return true;
}

/// Allocate and post receive buffers to the RX queue.
fn postRxBuffers() void {
    const rx = &(net_dev.rx_queue.?);
    for (0..RX_BUFFERS) |i| {
        const buf_phys = pmm.allocPage() orelse break;
        net_dev.rx_buffers[i] = buf_phys;

        // Zero the buffer
        const ptr: [*]u8 = @ptrFromInt(buf_phys);
        @memset(ptr[0..4096], 0);

        // Add to RX queue (device-writable since device writes received packets here)
        _ = virtio.addBuffer(rx, buf_phys, FRAME_SIZE, true);
    }

    // Notify device that buffers are available
    virtio.notify(rx);

    serial.puts("virtio-net: posted ");
    serial.putDec(RX_BUFFERS);
    serial.puts(" RX buffers\n");
}

/// Send a raw Ethernet frame.
/// `data` should NOT include the virtio-net header — this function prepends it.
pub fn send(data: []const u8) bool {
    if (!net_dev.initialized) return false;
    if (data.len > 1514) return false; // Max Ethernet frame

    const tx = &(net_dev.tx_queue.?);

    // Allocate a page for the TX buffer
    const buf_phys = pmm.allocPage() orelse return false;
    const buf: [*]u8 = @ptrFromInt(buf_phys);

    // Write virtio-net header (all zeros = no offloading)
    const hdr_size = @sizeOf(VirtioNetHeader);
    @memset(buf[0..hdr_size], 0);

    // Copy frame data after header
    @memcpy(buf[hdr_size..][0..data.len], data);

    const total_len: u32 = @intCast(hdr_size + data.len);

    // Add to TX queue
    _ = virtio.addBuffer(tx, buf_phys, total_len, false) orelse return false;
    virtio.notify(tx);

    return true;
}

/// Poll for received packets. Returns the data portion (after virtio-net header) or null.
pub fn poll() ?[]u8 {
    if (!net_dev.initialized) return null;

    const rx = &(net_dev.rx_queue.?);
    const used = virtio.pollUsed(rx) orelse return null;

    const buf_idx = used.id;
    if (buf_idx >= RX_BUFFERS) return null;

    const buf_phys = net_dev.rx_buffers[buf_idx];
    const buf: [*]u8 = @ptrFromInt(buf_phys);

    const hdr_size = @sizeOf(VirtioNetHeader);
    const data_len = used.len;

    if (data_len <= hdr_size) return null;

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
    for (mac, 0..) |byte, i| {
        if (i > 0) console.putChar(':');
        console.putChar(hex[byte >> 4]);
        console.putChar(hex[byte & 0x0F]);
    }
}
