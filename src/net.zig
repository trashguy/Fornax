/// Network frame delivery stub.
///
/// All TCP/IP processing now lives in userspace (netd).
/// The kernel only reads the MAC, delivers raw frames to /dev/ether0 clients,
/// and exposes getMac()/isInitialized() for sysinfo.
const klog = @import("klog.zig");
const virtio_net = @import("virtio_net.zig");

pub const ethernet = @import("net/ethernet.zig");

var our_mac: [6]u8 = .{ 0, 0, 0, 0, 0, 0 };
var initialized: bool = false;

pub fn init() void {
    if (!virtio_net.isInitialized()) {
        klog.debug("net: no NIC, skipping init\n");
        return;
    }

    our_mac = virtio_net.getMac();
    klog.info("net: MAC ");
    for (our_mac, 0..) |b, i| {
        if (i > 0) klog.info(":");
        klog.infoHex(b);
    }
    klog.info("\n");
    initialized = true;
}

pub fn getMac() [6]u8 {
    return our_mac;
}

pub fn isInitialized() bool {
    return initialized;
}

/// Poll for incoming frames and deliver to /dev/ether0 clients.
pub fn poll() void {
    if (!initialized) return;

    const ether_mod = @import("ether.zig");
    var frames: usize = 0;
    while (frames < 64) : (frames += 1) {
        const frame = virtio_net.poll() orelse break;
        _ = ether_mod.deliverFrame(frame);
    }
}
