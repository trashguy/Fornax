/// Network stack integration.
///
/// Ties together ethernet, ARP, IPv4, ICMP, and UDP with the virtio-net driver.
/// Provides a poll loop and high-level send/receive operations.
const console = @import("console.zig");
const serial = @import("serial.zig");
const virtio_net = @import("virtio_net.zig");

pub const ethernet = @import("net/ethernet.zig");
pub const arp = @import("net/arp.zig");
pub const ipv4 = @import("net/ipv4.zig");
pub const icmp = @import("net/icmp.zig");
pub const udp = @import("net/udp.zig");

var our_mac: [6]u8 = .{ 0, 0, 0, 0, 0, 0 };
var our_ip: [4]u8 = .{ 10, 0, 2, 15 }; // QEMU user-mode default
var gateway_ip: [4]u8 = .{ 10, 0, 2, 2 }; // QEMU user-mode default gateway
var subnet_mask: [4]u8 = .{ 255, 255, 255, 0 };
var initialized: bool = false;

pub fn init() void {
    if (!virtio_net.isInitialized()) {
        serial.puts("net: no NIC, skipping init\n");
        return;
    }

    our_mac = virtio_net.getMac();

    console.puts("net: IP ");
    printIpConsole(our_ip);
    console.puts(" gateway ");
    printIpConsole(gateway_ip);
    console.puts("\n");

    initialized = true;
}

/// Configure IP address.
pub fn setIp(ip: [4]u8) void {
    our_ip = ip;
}

/// Configure gateway.
pub fn setGateway(ip: [4]u8) void {
    gateway_ip = ip;
}

/// Configure subnet mask.
pub fn setSubnetMask(mask: [4]u8) void {
    subnet_mask = mask;
}

pub fn getIp() [4]u8 {
    return our_ip;
}

pub fn getMac() [6]u8 {
    return our_mac;
}

pub fn isInitialized() bool {
    return initialized;
}

/// Poll for incoming packets and process them.
/// Call this from the main loop or a timer interrupt.
pub fn poll() void {
    if (!initialized) return;

    const frame = virtio_net.poll() orelse return;
    handleFrame(frame);
}

/// Process a raw Ethernet frame.
fn handleFrame(frame: []u8) void {
    const parsed = ethernet.parse(frame) orelse return;

    // Check if frame is for us or broadcast
    if (!ethernet.macEqual(parsed.header.dst, our_mac) and
        !ethernet.isBroadcast(parsed.header.dst))
    {
        return;
    }

    switch (parsed.header.ethertype) {
        ethernet.ETHER_ARP => handleArp(parsed.payload),
        ethernet.ETHER_IPV4 => handleIpv4(parsed.payload),
        else => {},
    }
}

fn handleArp(payload: []const u8) void {
    var reply_buf: [ethernet.HEADER_SIZE + 64]u8 = undefined;
    const reply_len = arp.handlePacket(payload, our_mac, our_ip, &reply_buf) orelse return;
    _ = virtio_net.send(reply_buf[0..reply_len]);
}

fn handleIpv4(payload: []const u8) void {
    const ip_pkt = ipv4.parse(payload) orelse return;

    // Check if addressed to us
    if (!ipv4.ipEqual(ip_pkt.header.dst, our_ip)) return;

    switch (ip_pkt.header.protocol) {
        ipv4.PROTO_ICMP => handleIcmp(ip_pkt.payload, ip_pkt.header),
        ipv4.PROTO_UDP => udp.handlePacket(ip_pkt.payload, ip_pkt.header),
        else => {
            serial.puts("ipv4: unknown protocol ");
            serial.putDec(ip_pkt.header.protocol);
            serial.puts("\n");
        },
    }
}

fn handleIcmp(payload: []const u8, ip_hdr: ipv4.Header) void {
    var reply_buf: [1600]u8 = undefined;
    const ip_reply_len = icmp.handlePacket(payload, ip_hdr, our_ip, &reply_buf) orelse return;

    // Wrap in Ethernet and send
    sendIpPacket(ip_hdr.src, reply_buf[0..ip_reply_len]);
}

/// Send an IP packet (already built) to the given destination.
/// Handles ARP resolution and Ethernet framing.
pub fn sendIpPacket(dst_ip: [4]u8, ip_packet: []const u8) void {
    // Determine next-hop: if on same subnet, send directly; otherwise use gateway
    const next_hop = if (sameSubnet(dst_ip, our_ip, subnet_mask)) dst_ip else gateway_ip;

    // Look up MAC for next hop
    const dst_mac = arp.lookup(next_hop) orelse {
        // Send ARP request and drop this packet (caller should retry)
        var arp_buf: [ethernet.HEADER_SIZE + 64]u8 = undefined;
        const arp_len = arp.buildRequest(&arp_buf, our_mac, our_ip, next_hop) orelse return;
        _ = virtio_net.send(arp_buf[0..arp_len]);
        serial.puts("net: ARP miss for ");
        printIpSerial(next_hop);
        serial.puts(", packet dropped\n");
        return;
    };

    var frame_buf: [1600]u8 = undefined;
    const frame_len = ethernet.build(&frame_buf, dst_mac, our_mac, ethernet.ETHER_IPV4, ip_packet) orelse return;
    _ = virtio_net.send(frame_buf[0..frame_len]);
}

/// Send a UDP datagram.
pub fn sendUdp(dst_ip: [4]u8, src_port: u16, dst_port: u16, data: []const u8) bool {
    var ip_buf: [1600]u8 = undefined;
    const ip_len = udp.buildPacket(&ip_buf, our_ip, dst_ip, src_port, dst_port, data) orelse return false;
    sendIpPacket(dst_ip, ip_buf[0..ip_len]);
    return true;
}

fn sameSubnet(a: [4]u8, b: [4]u8, mask: [4]u8) bool {
    return (a[0] & mask[0]) == (b[0] & mask[0]) and
        (a[1] & mask[1]) == (b[1] & mask[1]) and
        (a[2] & mask[2]) == (b[2] & mask[2]) and
        (a[3] & mask[3]) == (b[3] & mask[3]);
}

fn printIpConsole(ip: [4]u8) void {
    console.putDec(ip[0]);
    console.putChar('.');
    console.putDec(ip[1]);
    console.putChar('.');
    console.putDec(ip[2]);
    console.putChar('.');
    console.putDec(ip[3]);
}

fn printIpSerial(ip: [4]u8) void {
    serial.putDec(ip[0]);
    serial.putChar('.');
    serial.putDec(ip[1]);
    serial.putChar('.');
    serial.putDec(ip[2]);
    serial.putChar('.');
    serial.putDec(ip[3]);
}
