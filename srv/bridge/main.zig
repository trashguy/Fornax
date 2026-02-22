/// Bridge server — Ethernet bridge + NAT for container networking.
/// Mounted at /bridge/ via IPC.
///
/// Architecture:
///   Container netd ──IPC──▶ bridge port N ──▶ bridge ──▶ /dev/ether0
///   Host netd      ──IPC──▶ bridge port 0 ──▶    │
///                                                 NAT table
///
/// Threads: main+worker (IPC), frame RX (ether→ports), timer (NAT expiry).
///
/// ctl files:
///   /bridge/clone       R  — allocate port, read returns ID
///   /bridge/N/ctl       W  — "mac XX...", "ip A.B.C.D"
///   /bridge/N/data      RW — raw Ethernet frame I/O
///   /bridge/status      R  — port list + NAT stats
///   /bridge/ctl         W  — "subnet A.B.C.D/M", "flush"
const fx = @import("fornax");
const net = fx.net;

const out = fx.io.Writer.stdout;
const err = fx.io.Writer.stderr;

// ── Constants ──

const SERVER_FD: i32 = 3;
const ETHER_FD: i32 = 4;

const MAX_PORTS = 16;
const MAX_HANDLES = 64;
const MAX_NAT = 128;
const MAX_MAC = 64;
const MAX_FRAME = 1518;
const PORT_RING_SIZE = 8;
const NUM_WORKERS = 1;
const MAX_POLL_ITERS: u32 = 3000;
const POLL_SLEEP_MS: u32 = 10;
const NAT_TTL_SECS: u32 = 300; // 5 minutes
const NAT_PORT_BASE: u16 = 40000;

// ── Data structures ──

const BridgePort = struct {
    active: bool,
    mac: [6]u8,
    ip: u32,
    // Frame ring buffer for incoming frames (ether → port)
    frame_ring: [PORT_RING_SIZE][MAX_FRAME]u8,
    frame_lens: [PORT_RING_SIZE]u16,
    ring_head: u8, // next write position
    ring_tail: u8, // next read position
    ring_count: u8,
};

const NatEntry = struct {
    active: bool,
    internal_ip: u32,
    internal_port: u16,
    external_port: u16,
    dest_ip: u32,
    dest_port: u16,
    protocol: u8, // 6=TCP, 17=UDP
    ttl: u32, // ticks remaining
};

const MacEntry = struct {
    valid: bool,
    mac: [6]u8,
    port_idx: u8,
    ttl: u32,
};

const HandleKind = enum(u8) {
    port_clone,
    port_ctl,
    port_data,
    bridge_status,
    bridge_ctl,
    bridge_dir,
};

const Handle = struct {
    active: bool,
    kind: HandleKind,
    port_idx: u8,
    read_done: bool,
};

// ── Global state (BSS) ──

var ports: [MAX_PORTS]BridgePort linksection(".bss") = undefined;
var nat_table: [MAX_NAT]NatEntry linksection(".bss") = undefined;
var mac_table: [MAX_MAC]MacEntry linksection(".bss") = undefined;
var handles: [MAX_HANDLES]Handle linksection(".bss") = undefined;

var host_ip: u32 = 0x0F02000A; // 10.0.2.15 in network byte order
var host_mac: [6]u8 = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 }; // QEMU default
var subnet_mask: u32 = 0x00FFFFFF; // 255.255.255.0
var next_nat_port: u16 = NAT_PORT_BASE;
var bridge_lock: fx.thread.Mutex = .{};

// ── Init ──

fn initState() void {
    for (&ports) |*p| {
        p.active = false;
        p.ring_count = 0;
        p.ring_head = 0;
        p.ring_tail = 0;
        p.ip = 0;
        @memset(&p.mac, 0);
    }
    for (&nat_table) |*n| n.active = false;
    for (&mac_table) |*m| m.valid = false;
    for (&handles) |*h| h.active = false;
}

// ── Handle management ──

fn allocHandle(kind: HandleKind, port_idx: u8) ?u32 {
    // Start from 1: handle 0 is reserved (kernel treats server_handle=0 as "no handle")
    for (handles[1..], 1..) |*h, i| {
        if (!h.active) {
            h.* = .{ .active = true, .kind = kind, .port_idx = port_idx, .read_done = false };
            return @intCast(i);
        }
    }
    return null;
}

fn getHandle(id: u32) ?*Handle {
    if (id >= MAX_HANDLES) return null;
    if (!handles[id].active) return null;
    return &handles[id];
}

fn freeHandle(id: u32) void {
    if (id < MAX_HANDLES) handles[id].active = false;
}

// ── Port management ──

fn allocPort() ?u8 {
    for (&ports, 0..) |*p, i| {
        if (!p.active) {
            p.active = true;
            p.ring_count = 0;
            p.ring_head = 0;
            p.ring_tail = 0;
            p.ip = 0;
            @memset(&p.mac, 0);
            return @intCast(i);
        }
    }
    return null;
}

fn freePort(idx: u8) void {
    if (idx < MAX_PORTS) {
        ports[idx].active = false;
        // Remove MAC entries for this port
        for (&mac_table) |*m| {
            if (m.valid and m.port_idx == idx) m.valid = false;
        }
        // Remove NAT entries for this port's IP
        const ip = ports[idx].ip;
        if (ip != 0) {
            for (&nat_table) |*n| {
                if (n.active and n.internal_ip == ip) n.active = false;
            }
        }
    }
}

fn enqueueFrame(port_idx: u8, frame: []const u8) bool {
    if (port_idx >= MAX_PORTS) return false;
    var p = &ports[port_idx];
    if (!p.active) return false;
    if (p.ring_count >= PORT_RING_SIZE) return false; // full, drop
    const slot = p.ring_head;
    const len = @min(frame.len, MAX_FRAME);
    @memcpy(p.frame_ring[slot][0..len], frame[0..len]);
    p.frame_lens[slot] = @intCast(len);
    p.ring_head = (slot + 1) % PORT_RING_SIZE;
    p.ring_count += 1;
    return true;
}

fn dequeueFrame(port_idx: u8, dest: []u8) u16 {
    if (port_idx >= MAX_PORTS) return 0;
    var p = &ports[port_idx];
    if (p.ring_count == 0) return 0;
    const slot = p.ring_tail;
    const len = p.frame_lens[slot];
    const copy_len = @min(len, @as(u16, @intCast(dest.len)));
    @memcpy(dest[0..copy_len], p.frame_ring[slot][0..copy_len]);
    p.ring_tail = (slot + 1) % PORT_RING_SIZE;
    p.ring_count -= 1;
    return copy_len;
}

// ── MAC table ──

fn macLearn(mac: [6]u8, port_idx: u8) void {
    // Update existing
    for (&mac_table) |*m| {
        if (m.valid and macEql(m.mac, mac)) {
            m.port_idx = port_idx;
            m.ttl = 300;
            return;
        }
    }
    // Insert new
    for (&mac_table) |*m| {
        if (!m.valid) {
            m.valid = true;
            m.mac = mac;
            m.port_idx = port_idx;
            m.ttl = 300;
            return;
        }
    }
}

fn macLookup(mac: [6]u8) ?u8 {
    for (&mac_table) |*m| {
        if (m.valid and macEql(m.mac, mac)) return m.port_idx;
    }
    return null;
}

fn macEql(a: [6]u8, b: [6]u8) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and
        a[3] == b[3] and a[4] == b[4] and a[5] == b[5];
}

fn isBroadcast(mac: [6]u8) bool {
    return mac[0] == 0xFF and mac[1] == 0xFF and mac[2] == 0xFF and
        mac[3] == 0xFF and mac[4] == 0xFF and mac[5] == 0xFF;
}

// ── NAT ──

fn natAllocPort() u16 {
    const port = next_nat_port;
    next_nat_port +%= 1;
    if (next_nat_port < NAT_PORT_BASE) next_nat_port = NAT_PORT_BASE;
    return port;
}

fn natFindOutbound(internal_ip: u32, internal_port: u16, dest_ip: u32, dest_port: u16, protocol: u8) ?*NatEntry {
    for (&nat_table) |*n| {
        if (n.active and n.internal_ip == internal_ip and n.internal_port == internal_port and
            n.dest_ip == dest_ip and n.dest_port == dest_port and n.protocol == protocol)
        {
            n.ttl = NAT_TTL_SECS;
            return n;
        }
    }
    return null;
}

fn natCreateOutbound(internal_ip: u32, internal_port: u16, dest_ip: u32, dest_port: u16, protocol: u8) ?*NatEntry {
    for (&nat_table) |*n| {
        if (!n.active) {
            n.* = .{
                .active = true,
                .internal_ip = internal_ip,
                .internal_port = internal_port,
                .external_port = natAllocPort(),
                .dest_ip = dest_ip,
                .dest_port = dest_port,
                .protocol = protocol,
                .ttl = NAT_TTL_SECS,
            };
            return n;
        }
    }
    return null;
}

fn natFindInbound(external_port: u16, protocol: u8) ?*NatEntry {
    for (&nat_table) |*n| {
        if (n.active and n.external_port == external_port and n.protocol == protocol) {
            n.ttl = NAT_TTL_SECS;
            return n;
        }
    }
    return null;
}

// ── Checksum helpers (RFC 1624 incremental update) ──

fn checksumAdjust16(old_check: u16, old_val: u16, new_val: u16) u16 {
    var sum: u32 = @as(u32, ~old_check & 0xFFFF);
    sum +%= @as(u32, ~old_val & 0xFFFF);
    sum +%= @as(u32, new_val);
    while (sum >> 16 != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return @intCast(~sum & 0xFFFF);
}

fn checksumAdjustIp(old_check: u16, old_ip: u32, new_ip: u32) u16 {
    var check = checksumAdjust16(old_check, @intCast(old_ip >> 16), @intCast(new_ip >> 16));
    check = checksumAdjust16(check, @intCast(old_ip & 0xFFFF), @intCast(new_ip & 0xFFFF));
    return check;
}

fn readU16BE(buf: []const u8) u16 {
    return (@as(u16, buf[0]) << 8) | @as(u16, buf[1]);
}

fn writeU16BE(buf: []u8, val: u16) void {
    buf[0] = @truncate(val >> 8);
    buf[1] = @truncate(val);
}

fn readU32BE(buf: []const u8) u32 {
    return (@as(u32, buf[0]) << 24) | (@as(u32, buf[1]) << 16) |
        (@as(u32, buf[2]) << 8) | @as(u32, buf[3]);
}

fn writeU32BE(buf: []u8, val: u32) void {
    buf[0] = @truncate(val >> 24);
    buf[1] = @truncate(val >> 16);
    buf[2] = @truncate(val >> 8);
    buf[3] = @truncate(val);
}

// ── NAT rewriting ──

/// Apply SNAT to an outbound frame: rewrite source IP + port.
/// Returns true if frame was modified.
fn natRewriteOutbound(frame: []u8) bool {
    if (frame.len < 34) return false; // eth(14) + ip(20) minimum
    const eth_payload = frame[14..];

    // Check IP version + header length
    const version_ihl = eth_payload[0];
    if (version_ihl >> 4 != 4) return false; // not IPv4
    const ihl: u8 = (version_ihl & 0x0F) * 4;
    if (ihl < 20 or eth_payload.len < ihl) return false;

    const protocol = eth_payload[9];
    if (protocol != 6 and protocol != 17) return false; // only TCP/UDP

    const src_ip = readU32BE(eth_payload[12..16]);
    const dst_ip = readU32BE(eth_payload[16..20]);
    const ip_checksum = readU16BE(eth_payload[10..12]);

    // Only NAT container IPs (10.0.1.0/24 = 0x0A000100 range)
    if ((src_ip & 0xFFFFFF00) != 0x0A000100) return false;

    // Get transport header
    if (eth_payload.len < ihl + 4) return false;
    const transport = eth_payload[ihl..];
    const src_port = readU16BE(transport[0..2]);

    // Find or create NAT entry
    const nat_ip_be = toBE32(src_ip);
    const dst_ip_be = toBE32(dst_ip);
    var entry = natFindOutbound(nat_ip_be, src_port, dst_ip_be, readU16BE(transport[2..4]), protocol);
    if (entry == null) {
        entry = natCreateOutbound(nat_ip_be, src_port, dst_ip_be, readU16BE(transport[2..4]), protocol);
    }
    if (entry == null) return false;
    const e = entry.?;

    // Rewrite source IP to host IP
    const new_src_ip = toBE32(fromBE32(host_ip));
    writeU32BE(eth_payload[12..16], new_src_ip);

    // Update IP header checksum
    const new_ip_check = checksumAdjustIp(ip_checksum, src_ip, new_src_ip);
    writeU16BE(eth_payload[10..12], new_ip_check);

    // Rewrite source port
    writeU16BE(transport[0..2], e.external_port);

    // Update transport checksum (TCP offset 16, UDP offset 6)
    const check_off: usize = if (protocol == 6) 16 else 6;
    if (transport.len > check_off + 1) {
        var old_check = readU16BE(transport[check_off .. check_off + 2]);
        // Adjust for IP change (pseudo-header)
        old_check = checksumAdjustIp(old_check, src_ip, new_src_ip);
        // Adjust for port change
        old_check = checksumAdjust16(old_check, src_port, e.external_port);
        writeU16BE(transport[check_off .. check_off + 2], old_check);
    }

    // Rewrite source MAC to host MAC
    @memcpy(frame[6..12], &host_mac);

    return true;
}

/// Apply DNAT to an inbound frame: rewrite dest IP + port.
/// Returns the target port index, or null if no NAT match.
fn natRewriteInbound(frame: []u8) ?u8 {
    if (frame.len < 34) return null;
    const eth_payload = frame[14..];

    const version_ihl = eth_payload[0];
    if (version_ihl >> 4 != 4) return null;
    const ihl: u8 = (version_ihl & 0x0F) * 4;
    if (ihl < 20 or eth_payload.len < ihl) return null;

    const protocol = eth_payload[9];
    if (protocol != 6 and protocol != 17) return null;

    const dst_ip = readU32BE(eth_payload[16..20]);
    const ip_checksum = readU16BE(eth_payload[10..12]);

    // Only check frames destined for host IP
    if (dst_ip != toBE32(fromBE32(host_ip))) return null;

    if (eth_payload.len < ihl + 4) return null;
    const transport = eth_payload[ihl..];
    const dst_port = readU16BE(transport[2..4]);

    // Look up NAT table by destination port
    const entry = natFindInbound(dst_port, protocol) orelse return null;

    // Find port by internal IP
    const target_ip = entry.internal_ip;
    var target_port_idx: ?u8 = null;
    for (&ports, 0..) |*p, i| {
        if (p.active and p.ip == target_ip) {
            target_port_idx = @intCast(i);
            break;
        }
    }
    if (target_port_idx == null) return null;

    // Rewrite destination IP
    const new_dst_ip = toBE32(fromBE32(target_ip));
    writeU32BE(eth_payload[16..20], new_dst_ip);

    // Update IP checksum
    const new_ip_check = checksumAdjustIp(ip_checksum, dst_ip, new_dst_ip);
    writeU16BE(eth_payload[10..12], new_ip_check);

    // Rewrite destination port
    writeU16BE(transport[2..4], entry.internal_port);

    // Update transport checksum
    const check_off: usize = if (protocol == 6) 16 else 6;
    if (transport.len > check_off + 1) {
        var old_check = readU16BE(transport[check_off .. check_off + 2]);
        old_check = checksumAdjustIp(old_check, dst_ip, new_dst_ip);
        old_check = checksumAdjust16(old_check, dst_port, entry.internal_port);
        writeU16BE(transport[check_off .. check_off + 2], old_check);
    }

    // Rewrite dest MAC to target port's MAC
    @memcpy(frame[0..6], &ports[target_port_idx.?].mac);

    return target_port_idx;
}

// ── Byte order helpers ──

fn toBE32(val: u32) u32 {
    return (val >> 24) | ((val >> 8) & 0xFF00) | ((val << 8) & 0xFF0000) | (val << 24);
}

fn fromBE32(val: u32) u32 {
    return toBE32(val); // same operation
}

// ── Frame routing ──

fn routeFrameFromEther(frame: []u8) void {
    if (frame.len < 14) return;
    const dst_mac: [6]u8 = frame[0..6].*;

    // Try DNAT first (reply to an outbound connection)
    if (natRewriteInbound(frame)) |port_idx| {
        _ = enqueueFrame(port_idx, frame);
        return;
    }

    // MAC-based routing
    if (isBroadcast(dst_mac)) {
        // Flood to all active ports
        for (&ports, 0..) |*p, i| {
            if (p.active) _ = enqueueFrame(@intCast(i), frame);
        }
    } else if (macLookup(dst_mac)) |port_idx| {
        _ = enqueueFrame(port_idx, frame);
    } else {
        // Unknown MAC — flood
        for (&ports, 0..) |*p, i| {
            if (p.active) _ = enqueueFrame(@intCast(i), frame);
        }
    }
}

fn routeFrameFromPort(port_idx: u8, frame: []u8) void {
    if (frame.len < 14) return;
    const src_mac: [6]u8 = frame[6..12].*;
    const dst_mac: [6]u8 = frame[0..6].*;

    // MAC learning
    macLearn(src_mac, port_idx);

    // Apply SNAT if this is an outbound IP packet
    _ = natRewriteOutbound(frame);

    // Route: if dst is another port, deliver locally; otherwise send to ether
    if (isBroadcast(dst_mac)) {
        // Broadcast: send to ether + all other ports
        _ = fx.write(ETHER_FD, frame);
        for (&ports, 0..) |*p, i| {
            if (p.active and @as(u8, @intCast(i)) != port_idx) {
                _ = enqueueFrame(@intCast(i), frame);
            }
        }
    } else if (macLookup(dst_mac)) |target| {
        if (target == port_idx) return; // same port, drop
        _ = enqueueFrame(target, frame);
    } else {
        // Unknown destination — send to ether (external)
        _ = fx.write(ETHER_FD, frame);
    }
}

// ── IPC handlers ──

fn handleOpen(msg: *fx.IpcMessage, reply: *fx.IpcMessage) void {
    if (msg.data_len == 0) {
        reply.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }
    var path: []const u8 = msg.data[0..msg.data_len];

    // Strip "bridge/" prefix
    if (path.len > 7 and eql(path[0..7], "bridge/")) {
        path = path[7..];
    }

    if (eql(path, "clone")) {
        bridge_lock.lock();
        const port_idx = allocPort();
        bridge_lock.unlock();
        if (port_idx) |idx| {
            if (allocHandle(.port_clone, idx)) |h| {
                reply.* = fx.IpcMessage.init(fx.R_OK);
                writeU32LE(reply.data[0..4], h);
                reply.data_len = 4;
                return;
            }
        }
    } else if (eql(path, "status")) {
        if (allocHandle(.bridge_status, 0)) |h| {
            reply.* = fx.IpcMessage.init(fx.R_OK);
            writeU32LE(reply.data[0..4], h);
            reply.data_len = 4;
            return;
        }
    } else if (eql(path, "ctl")) {
        if (allocHandle(.bridge_ctl, 0)) |h| {
            reply.* = fx.IpcMessage.init(fx.R_OK);
            writeU32LE(reply.data[0..4], h);
            reply.data_len = 4;
            return;
        }
    } else if (path.len >= 1 and path[0] >= '0' and path[0] <= '9') {
        // Parse port number: "N/ctl" or "N/data"
        var i: usize = 0;
        while (i < path.len and path[i] >= '0' and path[i] <= '9') : (i += 1) {}
        const port_num = parseDecimal(path[0..i]) orelse {
            reply.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        };
        if (port_num >= MAX_PORTS or !ports[port_num].active) {
            reply.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        }
        if (i < path.len and path[i] == '/') {
            const sub = path[i + 1 ..];
            if (eql(sub, "ctl")) {
                if (allocHandle(.port_ctl, @intCast(port_num))) |h| {
                    reply.* = fx.IpcMessage.init(fx.R_OK);
                    writeU32LE(reply.data[0..4], h);
                    reply.data_len = 4;
                    return;
                }
            } else if (eql(sub, "data")) {
                if (allocHandle(.port_data, @intCast(port_num))) |h| {
                    reply.* = fx.IpcMessage.init(fx.R_OK);
                    writeU32LE(reply.data[0..4], h);
                    reply.data_len = 4;
                    return;
                }
            }
        }
    } else if (path.len == 0 or eql(path, ".") or eql(path, "/")) {
        if (allocHandle(.bridge_dir, 0)) |h| {
            reply.* = fx.IpcMessage.init(fx.R_OK);
            writeU32LE(reply.data[0..4], h);
            reply.data_len = 4;
            return;
        }
    }

    reply.* = fx.IpcMessage.init(fx.R_ERROR);
}

fn handleRead(msg: *fx.IpcMessage, reply: *fx.IpcMessage) void {
    const handle_id = readU32LE(msg.data[0..4]);
    const h = getHandle(handle_id) orelse {
        reply.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    switch (h.kind) {
        .port_clone => {
            if (h.read_done) {
                reply.* = fx.IpcMessage.init(fx.R_OK);
                reply.data_len = 0;
                return;
            }
            var buf: [8]u8 = undefined;
            const len = formatDec(&buf, h.port_idx);
            buf[len] = '\n';
            reply.* = fx.IpcMessage.init(fx.R_OK);
            const total = len + 1;
            @memcpy(reply.data[0..total], buf[0..total]);
            reply.data_len = @intCast(total);
            h.read_done = true;
        },
        .port_data => {
            // Poll for frame
            var iters: u32 = 0;
            while (iters < MAX_POLL_ITERS) : (iters += 1) {
                bridge_lock.lock();
                if (ports[h.port_idx].ring_count > 0) {
                    var frame_buf: [MAX_FRAME]u8 = undefined;
                    const n = dequeueFrame(h.port_idx, &frame_buf);
                    bridge_lock.unlock();
                    reply.* = fx.IpcMessage.init(fx.R_OK);
                    const copy_len = @min(n, 4096);
                    @memcpy(reply.data[0..copy_len], frame_buf[0..copy_len]);
                    reply.data_len = @intCast(copy_len);
                    return;
                }
                bridge_lock.unlock();
                fx.sleep(POLL_SLEEP_MS);
            }
            // Timeout
            reply.* = fx.IpcMessage.init(fx.R_OK);
            reply.data_len = 0;
        },
        .bridge_status => {
            if (h.read_done) {
                reply.* = fx.IpcMessage.init(fx.R_OK);
                reply.data_len = 0;
                return;
            }
            var buf: [2048]u8 = undefined;
            var pos: usize = 0;

            bridge_lock.lock();
            // Port list
            for (&ports, 0..) |*p, i| {
                if (!p.active) continue;
                const hdr = "port ";
                @memcpy(buf[pos..][0..hdr.len], hdr);
                pos += hdr.len;
                pos += formatDec(buf[pos..], @intCast(i));
                const ip_str = " ip ";
                @memcpy(buf[pos..][0..ip_str.len], ip_str);
                pos += ip_str.len;
                pos += formatIp(buf[pos..], p.ip);
                const mac_str = " mac ";
                @memcpy(buf[pos..][0..mac_str.len], mac_str);
                pos += mac_str.len;
                pos += formatMac(buf[pos..], p.mac);
                buf[pos] = '\n';
                pos += 1;
            }
            // NAT stats
            var nat_count: u32 = 0;
            for (&nat_table) |*n| {
                if (n.active) nat_count += 1;
            }
            bridge_lock.unlock();

            const nat_hdr = "nat_entries ";
            @memcpy(buf[pos..][0..nat_hdr.len], nat_hdr);
            pos += nat_hdr.len;
            pos += formatDec(buf[pos..], @intCast(nat_count));
            buf[pos] = '\n';
            pos += 1;

            reply.* = fx.IpcMessage.init(fx.R_OK);
            const copy_len = @min(pos, 4092);
            @memcpy(reply.data[0..copy_len], buf[0..copy_len]);
            reply.data_len = @intCast(copy_len);
            h.read_done = true;
        },
        .bridge_dir => {
            if (h.read_done) {
                reply.* = fx.IpcMessage.init(fx.R_OK);
                reply.data_len = 0;
                return;
            }
            // Return directory listing as DirEntry structs
            var buf: [4096]u8 = undefined;
            var pos: usize = 0;
            const entry_size: usize = 72;

            // "clone" entry
            pos += writeDirEntry(buf[pos..], "clone", 0, 0);
            // "status" entry
            pos += writeDirEntry(buf[pos..], "status", 0, 0);
            // "ctl" entry
            pos += writeDirEntry(buf[pos..], "ctl", 0, 0);
            // Port directories
            bridge_lock.lock();
            for (&ports, 0..) |*p, i| {
                if (!p.active) continue;
                if (pos + entry_size > buf.len) break;
                var name: [8]u8 = undefined;
                const nlen = formatDec(&name, @intCast(i));
                pos += writeDirEntry(buf[pos..], name[0..nlen], 1, 0);
            }
            bridge_lock.unlock();

            reply.* = fx.IpcMessage.init(fx.R_OK);
            @memcpy(reply.data[0..pos], buf[0..pos]);
            reply.data_len = @intCast(pos);
            h.read_done = true;
        },
        .bridge_ctl, .port_ctl => {
            reply.* = fx.IpcMessage.init(fx.R_OK);
            reply.data_len = 0;
        },
    }
}

fn handleWrite(msg: *fx.IpcMessage, reply: *fx.IpcMessage) void {
    const handle_id = readU32LE(msg.data[0..4]);
    const h = getHandle(handle_id) orelse {
        reply.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    const data = msg.data[4..msg.data_len];

    switch (h.kind) {
        .port_ctl => {
            // Commands: "mac XX:XX:XX:XX:XX:XX", "ip A.B.C.D"
            bridge_lock.lock();
            if (startsWith(data, "mac ")) {
                if (parseMac(data[4..])) |mac| {
                    ports[h.port_idx].mac = mac;
                    macLearn(mac, h.port_idx);
                }
            } else if (startsWith(data, "ip ")) {
                if (parseIp(data[3..])) |ip| {
                    ports[h.port_idx].ip = ip;
                }
            }
            bridge_lock.unlock();
            reply.* = fx.IpcMessage.init(fx.R_OK);
            reply.data_len = 0;
        },
        .port_data => {
            // Frame from container → route
            if (data.len >= 14) {
                var frame_buf: [MAX_FRAME]u8 = undefined;
                const len = @min(data.len, MAX_FRAME);
                @memcpy(frame_buf[0..len], data[0..len]);
                bridge_lock.lock();
                routeFrameFromPort(h.port_idx, frame_buf[0..len]);
                bridge_lock.unlock();
            }
            reply.* = fx.IpcMessage.init(fx.R_OK);
            writeU32LE(reply.data[0..4], @intCast(data.len));
            reply.data_len = 4;
        },
        .bridge_ctl => {
            // Commands: "flush"
            if (startsWith(data, "flush")) {
                bridge_lock.lock();
                for (&nat_table) |*n| n.active = false;
                for (&mac_table) |*m| m.valid = false;
                bridge_lock.unlock();
            }
            reply.* = fx.IpcMessage.init(fx.R_OK);
            reply.data_len = 0;
        },
        else => {
            reply.* = fx.IpcMessage.init(fx.R_ERROR);
        },
    }
}

fn handleClose(msg: *fx.IpcMessage, reply: *fx.IpcMessage) void {
    const handle_id = readU32LE(msg.data[0..4]);
    const h = getHandle(handle_id) orelse {
        reply.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    // If closing a port_data or port_ctl handle, don't free the port itself
    // (port is freed via "destroy" ctl or container cleanup)
    freeHandle(handle_id);

    _ = h;
    reply.* = fx.IpcMessage.init(fx.R_OK);
    reply.data_len = 0;
}

fn handleStat(msg: *fx.IpcMessage, reply: *fx.IpcMessage) void {
    _ = msg;
    // Return a basic stat: file_type=0 (file), size=0
    reply.* = fx.IpcMessage.init(fx.R_OK);
    var st: fx.Stat = undefined;
    @memset(@as(*[64]u8, @ptrCast(&st)), 0);
    st.file_type = 0;
    st.size = 0;
    st.mode = 0o644;
    const bytes: [*]const u8 = @ptrCast(&st);
    @memcpy(reply.data[0..@sizeOf(fx.Stat)], bytes[0..@sizeOf(fx.Stat)]);
    reply.data_len = @sizeOf(fx.Stat);
}

// ── Thread entry points ──

fn workerLoop() noreturn {
    var wmsg: fx.IpcMessage = undefined;
    var wreply: fx.IpcMessage = undefined;
    while (true) {
        const rc = fx.ipc_recv(SERVER_FD, &wmsg);
        if (rc < 0) {
            fx.sleep(10);
            continue;
        }
        switch (wmsg.tag) {
            fx.T_OPEN => handleOpen(&wmsg, &wreply),
            fx.T_READ => handleRead(&wmsg, &wreply),
            fx.T_WRITE => handleWrite(&wmsg, &wreply),
            fx.T_CLOSE => handleClose(&wmsg, &wreply),
            fx.T_STAT => handleStat(&wmsg, &wreply),
            else => {
                wreply = fx.IpcMessage.init(fx.R_ERROR);
            },
        }
        _ = fx.ipc_reply(SERVER_FD, &wreply);
    }
}

fn workerEntry(_: *anyopaque) callconv(.c) void {
    workerLoop();
}

fn rxLoop() noreturn {
    var frame_buf: [1600]u8 = undefined;
    while (true) {
        const n = fx.read(ETHER_FD, &frame_buf);
        if (n <= 0) {
            fx.sleep(1);
            continue;
        }
        const len: usize = @intCast(n);
        bridge_lock.lock();
        routeFrameFromEther(frame_buf[0..len]);
        bridge_lock.unlock();
    }
}

fn rxEntry(_: *anyopaque) callconv(.c) void {
    rxLoop();
}

fn timerLoop() noreturn {
    while (true) {
        fx.sleep(1000); // 1 second tick

        bridge_lock.lock();
        // Age NAT entries
        for (&nat_table) |*n| {
            if (n.active) {
                if (n.ttl == 0) {
                    n.active = false;
                } else {
                    n.ttl -= 1;
                }
            }
        }
        // Age MAC entries
        for (&mac_table) |*m| {
            if (m.valid) {
                if (m.ttl == 0) {
                    m.valid = false;
                } else {
                    m.ttl -= 1;
                }
            }
        }
        bridge_lock.unlock();
    }
}

fn timerEntry(_: *anyopaque) callconv(.c) void {
    timerLoop();
}

// ── Helpers ──

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    return eql(s[0..prefix.len], prefix);
}

fn parseDecimal(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var val: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        val = val * 10 + (c - '0');
    }
    return val;
}

fn formatDec(buf: []u8, val: u32) usize {
    if (val == 0) {
        buf[0] = '0';
        return 1;
    }
    var tmp: [10]u8 = undefined;
    var n: usize = 0;
    var v = val;
    while (v > 0) : (v /= 10) {
        tmp[n] = @intCast('0' + v % 10);
        n += 1;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) {
        buf[i] = tmp[n - 1 - i];
    }
    return n;
}

fn formatIp(buf: []u8, ip_be: u32) usize {
    // IP is stored in network (big-endian) byte order
    const b0: u32 = ip_be & 0xFF;
    const b1: u32 = (ip_be >> 8) & 0xFF;
    const b2: u32 = (ip_be >> 16) & 0xFF;
    const b3: u32 = (ip_be >> 24) & 0xFF;
    var pos: usize = 0;
    pos += formatDec(buf[pos..], b0);
    buf[pos] = '.';
    pos += 1;
    pos += formatDec(buf[pos..], b1);
    buf[pos] = '.';
    pos += 1;
    pos += formatDec(buf[pos..], b2);
    buf[pos] = '.';
    pos += 1;
    pos += formatDec(buf[pos..], b3);
    return pos;
}

fn formatMac(buf: []u8, mac: [6]u8) usize {
    var pos: usize = 0;
    for (mac, 0..) |b, i| {
        buf[pos] = hexNibble(b >> 4);
        buf[pos + 1] = hexNibble(b & 0x0F);
        pos += 2;
        if (i < 5) {
            buf[pos] = ':';
            pos += 1;
        }
    }
    return pos;
}

fn hexNibble(v: u8) u8 {
    return if (v < 10) '0' + v else 'a' + v - 10;
}

fn parseIp(s: []const u8) ?u32 {
    var octets: [4]u8 = undefined;
    var idx: usize = 0;
    var val: u32 = 0;
    for (s) |c| {
        if (c >= '0' and c <= '9') {
            val = val * 10 + (c - '0');
        } else if (c == '.') {
            if (idx >= 3 or val > 255) return null;
            octets[idx] = @intCast(val);
            idx += 1;
            val = 0;
        } else {
            break;
        }
    }
    if (idx != 3 or val > 255) return null;
    octets[3] = @intCast(val);
    // Network byte order (big-endian stored as little-endian u32)
    return @as(u32, octets[0]) | (@as(u32, octets[1]) << 8) |
        (@as(u32, octets[2]) << 16) | (@as(u32, octets[3]) << 24);
}

fn parseMac(s: []const u8) ?[6]u8 {
    var mac: [6]u8 = undefined;
    var idx: usize = 0;
    var val: u8 = 0;
    var nibbles: u8 = 0;
    for (s) |c| {
        if (c >= '0' and c <= '9') {
            val = val * 16 + (c - '0');
            nibbles += 1;
        } else if (c >= 'a' and c <= 'f') {
            val = val * 16 + (c - 'a' + 10);
            nibbles += 1;
        } else if (c >= 'A' and c <= 'F') {
            val = val * 16 + (c - 'A' + 10);
            nibbles += 1;
        } else if (c == ':' or c == '-') {
            if (idx >= 6) return null;
            mac[idx] = val;
            idx += 1;
            val = 0;
            nibbles = 0;
        } else {
            break;
        }
    }
    if (idx != 5 or nibbles == 0) return null;
    mac[5] = val;
    return mac;
}

fn writeU32LE(bytes: *[4]u8, val: u32) void {
    bytes[0] = @truncate(val);
    bytes[1] = @truncate(val >> 8);
    bytes[2] = @truncate(val >> 16);
    bytes[3] = @truncate(val >> 24);
}

fn readU32LE(bytes: *const [4]u8) u32 {
    return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) | (@as(u32, bytes[3]) << 24);
}

fn writeDirEntry(buf: []u8, name: []const u8, file_type: u32, size: u32) usize {
    const entry_size: usize = 72;
    if (buf.len < entry_size) return 0;
    @memset(buf[0..entry_size], 0);
    const nlen = @min(name.len, 63);
    @memcpy(buf[0..nlen], name[0..nlen]);
    writeU32LE(buf[64..68], file_type);
    writeU32LE(buf[68..72], size);
    return entry_size;
}

// ── Entry point ──

export fn _start() noreturn {
    out.puts("[bridge] starting\n");
    initState();

    // Set ether to exclusive mode — bridge owns all frames
    _ = fx.write(ETHER_FD, "exclusive");

    // Spawn RX thread
    _ = fx.thread.spawnThread(rxEntry, null) catch {};

    // Spawn timer thread
    _ = fx.thread.spawnThread(timerEntry, null) catch {};

    // Spawn worker threads
    var i: usize = 0;
    while (i < NUM_WORKERS) : (i += 1) {
        _ = fx.thread.spawnThread(workerEntry, null) catch {};
    }

    // Main thread enters IPC worker loop
    workerLoop();
}
