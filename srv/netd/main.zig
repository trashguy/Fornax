/// netd: Userspace network server.
///
/// Serves /net/tcp/*, /net/dns/*, /net/icmp/*, /net/status via IPC.
/// Reads raw Ethernet frames from /dev/ether0 (fd 4), processes through
/// userspace ARP/IP/TCP/DNS/ICMP stack.
///
/// Architecture:
///   - IPC worker threads (4): handle open/read/write/close/stat
///   - Frame RX thread: reads /dev/ether0, dispatches to protocol handlers
///   - Timer thread: periodic tick (retransmission, DNS retry, ICMP timeout)
///
/// Blocking reads: when no data available, the IPC worker thread polls
/// with short sleeps until data arrives or connection resets.
const fx = @import("fornax");
const net = fx.net;

const Mutex = fx.thread.Mutex;

// ── Configuration ─────────────────────────────────────────────────
const SERVER_FD: i32 = 3;
const ETHER_FD: i32 = 4;
const MAX_HANDLES = 64;
const TICK_MS: u32 = 55;
const POLL_SLEEP_MS: u32 = 10;
const MAX_POLL_ITERS: u32 = 3000; // ~30 seconds max block
const NUM_WORKERS = 3; // + main thread = 4

// Network config (QEMU defaults)
var our_mac: [6]u8 = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
var our_ip: [4]u8 = .{ 10, 0, 2, 15 };
var gateway_ip: [4]u8 = .{ 10, 0, 2, 2 };
var subnet_mask: [4]u8 = .{ 255, 255, 255, 0 };
var nameserver_ip: [4]u8 = .{ 10, 0, 2, 3 };

// ── Handle tracking ───────────────────────────────────────────────

const HandleKind = enum(u8) {
    tcp_clone,
    tcp_ctl,
    tcp_data,
    tcp_listen,
    tcp_status,
    tcp_local,
    tcp_remote,
    dns_query,
    dns_ctl,
    dns_cache,
    icmp_clone,
    icmp_ctl,
    icmp_data,
    net_status,
    arp_table,
    net_stats,
    ipifc_ctl,
};

const Handle = struct {
    active: bool = false,
    kind: HandleKind = .tcp_clone,
    conn: u8 = 0,
    read_done: bool = false,
};

var handles: [MAX_HANDLES]Handle = [_]Handle{.{}} ** MAX_HANDLES;

fn allocHandle(kind: HandleKind, conn: u8) ?u32 {
    for (&handles, 0..) |*h, i| {
        if (!h.active) {
            h.* = .{ .active = true, .kind = kind, .conn = conn, .read_done = false };
            return @intCast(i);
        }
    }
    return null;
}

fn freeHandle(idx: u32) void {
    if (idx < MAX_HANDLES) {
        handles[idx].active = false;
    }
}

fn getHandle(idx: u32) ?*Handle {
    if (idx >= MAX_HANDLES) return null;
    if (!handles[idx].active) return null;
    return &handles[idx];
}

// ── Network stack state (all BSS) ─────────────────────────────────

var tcp_stack: net.tcp.TcpStack linksection(".bss") = undefined;
var arp_table: net.arp.ArpTable = net.arp.ArpTable.init();
var dns_resolver: net.dns.DnsResolver linksection(".bss") = undefined;
var icmp_handler: net.icmp.IcmpHandler linksection(".bss") = undefined;

var net_lock: Mutex = .{};

// Packet ID counter for IP headers
var packet_id_counter: u16 = 1;

// ── Callbacks for the network stack ───────────────────────────────

fn sendTcpIpPacket(dst_ip: [4]u8, tcp_segment: []const u8) void {
    // Build IP header around TCP segment
    var ip_buf: [1600]u8 = undefined;
    const ip_len = net.ipv4.build(&ip_buf, our_ip, dst_ip, net.ipv4.PROTO_TCP, 64, blk: {
        const id = packet_id_counter;
        packet_id_counter +%= 1;
        break :blk id;
    }, tcp_segment) orelse return;

    sendIpPacket(dst_ip, ip_buf[0..ip_len]);
}

fn sendIpPacket(dst_ip: [4]u8, ip_packet: []const u8) void {
    // Determine MAC: gateway or direct
    const target_ip = if (sameSubnet(dst_ip)) dst_ip else gateway_ip;
    const mac = arp_table.lookup(target_ip) orelse {
        // Send ARP request and drop this packet (caller will retry)
        var arp_buf: [64]u8 = undefined;
        if (net.arp.ArpTable.buildRequest(&arp_buf, our_mac, our_ip, target_ip)) |arp_len| {
            _ = fx.write(ETHER_FD, arp_buf[0..arp_len]);
        }
        return;
    };

    // Wrap in Ethernet frame
    var frame_buf: [1600]u8 = undefined;
    const frame_len = net.ethernet.build(&frame_buf, mac, our_mac, net.ethernet.ETHER_IPV4, ip_packet) orelse return;
    _ = fx.write(ETHER_FD, frame_buf[0..frame_len]);
}

fn sendIcmpIpPacket(ctx: *anyopaque, dst_ip: [4]u8, ip_packet: []const u8) void {
    _ = ctx;
    sendIpPacket(dst_ip, ip_packet);
}

fn sendDnsUdp(ctx: *anyopaque, dst_ip: [4]u8, src_port: u16, dst_port: u16, data: []const u8) void {
    _ = ctx;
    // Build UDP packet
    var udp_buf: [600]u8 = undefined;
    const udp_len = buildUdp(&udp_buf, src_port, dst_port, data) orelse return;

    // Wrap in IP
    var ip_buf: [1600]u8 = undefined;
    const id = packet_id_counter;
    packet_id_counter +%= 1;
    const ip_len = net.ipv4.build(&ip_buf, our_ip, dst_ip, net.ipv4.PROTO_UDP, 64, id, udp_buf[0..udp_len]) orelse return;

    sendIpPacket(dst_ip, ip_buf[0..ip_len]);
}

fn getOurIp() [4]u8 {
    return our_ip;
}

fn getTicks() u32 {
    const info = fx.sysinfo() orelse return 0;
    // Convert uptime_secs to ~18Hz ticks (approximate)
    return @truncate(info.uptime_secs * 18);
}

fn getTimeMs(ctx: *anyopaque) u64 {
    _ = ctx;
    const info = fx.sysinfo() orelse return 0;
    return info.uptime_secs * 1000;
}

fn tcpWaiterCallback(conn_idx: u8, event: net.tcp.WaiterEvent) void {
    // The blocked IPC worker thread polls for data changes,
    // so we don't need to do anything here for v1.
    _ = conn_idx;
    _ = event;
}

fn sameSubnet(ip: [4]u8) bool {
    return (ip[0] & subnet_mask[0]) == (our_ip[0] & subnet_mask[0]) and
        (ip[1] & subnet_mask[1]) == (our_ip[1] & subnet_mask[1]) and
        (ip[2] & subnet_mask[2]) == (our_ip[2] & subnet_mask[2]) and
        (ip[3] & subnet_mask[3]) == (our_ip[3] & subnet_mask[3]);
}

// ── UDP helpers (minimal, for DNS) ────────────────────────────────

fn buildUdp(buf: []u8, src_port: u16, dst_port: u16, data: []const u8) ?usize {
    const udp_len = 8 + data.len;
    if (udp_len > buf.len) return null;
    buf[0] = @truncate(src_port >> 8);
    buf[1] = @truncate(src_port);
    buf[2] = @truncate(dst_port >> 8);
    buf[3] = @truncate(dst_port);
    const total: u16 = @intCast(udp_len);
    buf[4] = @truncate(total >> 8);
    buf[5] = @truncate(total);
    buf[6] = 0; // checksum (optional for UDP over IPv4)
    buf[7] = 0;
    @memcpy(buf[8..][0..data.len], data);
    return udp_len;
}

// ── IPC handlers ──────────────────────────────────────────────────

fn handleOpen(msg: *fx.IpcMessage, reply: *fx.IpcMessage) void {
    // Extract path from message data (first 4 bytes = parent handle, rest = path)
    if (msg.data_len <= 4) {
        reply.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }
    const path_bytes = msg.data[4..msg.data_len];

    // Strip leading "net/" if present (namespace mount point variation)
    var path = path_bytes;
    if (path.len > 4 and path[0] == 'n' and path[1] == 'e' and path[2] == 't' and path[3] == '/') {
        path = path[4..];
    }

    // Parse the path
    if (eql(path, "status")) {
        if (allocHandle(.net_status, 0)) |h| {
            reply.* = fx.IpcMessage.init(fx.R_OK);
            writeU32LE(reply.data[0..4], h);
            reply.data_len = 4;
            return;
        }
    } else if (startsWith(path, "tcp/clone")) {
        const idx = tcp_stack.alloc() orelse {
            reply.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        };
        if (allocHandle(.tcp_clone, idx)) |h| {
            reply.* = fx.IpcMessage.init(fx.R_OK);
            writeU32LE(reply.data[0..4], h);
            reply.data_len = 4;
            return;
        }
    } else if (startsWith(path, "tcp/")) {
        if (parseTcpConnPath(path[4..])) |parsed| {
            if (tcp_stack.getState(parsed.conn) != null) {
                if (allocHandle(parsed.kind, parsed.conn)) |h| {
                    reply.* = fx.IpcMessage.init(fx.R_OK);
                    writeU32LE(reply.data[0..4], h);
            reply.data_len = 4;
                    return;
                }
            }
        }
    } else if (eql(path, "dns") or eql(path, "dns/")) {
        if (allocHandle(.dns_query, 0)) |h| {
            reply.* = fx.IpcMessage.init(fx.R_OK);
            writeU32LE(reply.data[0..4], h);
            reply.data_len = 4;
            return;
        }
    } else if (eql(path, "dns/ctl")) {
        if (allocHandle(.dns_ctl, 0)) |h| {
            reply.* = fx.IpcMessage.init(fx.R_OK);
            writeU32LE(reply.data[0..4], h);
            reply.data_len = 4;
            return;
        }
    } else if (eql(path, "dns/cache")) {
        if (allocHandle(.dns_cache, 0)) |h| {
            reply.* = fx.IpcMessage.init(fx.R_OK);
            writeU32LE(reply.data[0..4], h);
            reply.data_len = 4;
            return;
        }
    } else if (startsWith(path, "icmp/clone")) {
        const idx = icmp_handler.alloc() orelse {
            reply.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        };
        if (allocHandle(.icmp_clone, idx)) |h| {
            reply.* = fx.IpcMessage.init(fx.R_OK);
            writeU32LE(reply.data[0..4], h);
            reply.data_len = 4;
            return;
        }
    } else if (startsWith(path, "icmp/")) {
        if (parseIcmpConnPath(path[5..])) |parsed| {
            if (allocHandle(parsed.kind, parsed.conn)) |h| {
                reply.* = fx.IpcMessage.init(fx.R_OK);
                writeU32LE(reply.data[0..4], h);
            reply.data_len = 4;
                return;
            }
        }
    } else if (eql(path, "arp")) {
        if (allocHandle(.arp_table, 0)) |h| {
            reply.* = fx.IpcMessage.init(fx.R_OK);
            writeU32LE(reply.data[0..4], h);
            reply.data_len = 4;
            return;
        }
    } else if (eql(path, "stats")) {
        if (allocHandle(.net_stats, 0)) |h| {
            reply.* = fx.IpcMessage.init(fx.R_OK);
            writeU32LE(reply.data[0..4], h);
            reply.data_len = 4;
            return;
        }
    } else if (eql(path, "ipifc/0/ctl")) {
        if (allocHandle(.ipifc_ctl, 0)) |h| {
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
        .tcp_clone => {
            if (h.read_done) {
                reply.* = fx.IpcMessage.init(fx.R_OK);
                reply.data_len = 0;
                return;
            }
            // Return connection index as "N\n"
            var buf: [8]u8 = undefined;
            const len = formatDec(&buf, h.conn);
            buf[len] = '\n';
            reply.* = fx.IpcMessage.init(fx.R_OK);
            const total = len + 1;
            @memcpy(reply.data[0..total], buf[0..total]);
            reply.data_len = @intCast(total);
            h.read_done = true;
        },
        .tcp_data => {
            // Poll for data with sleep
            var iters: u32 = 0;
            while (iters < MAX_POLL_ITERS) : (iters += 1) {
                net_lock.lock();
                if (tcp_stack.hasData(h.conn)) {
                    var buf: [4092]u8 = undefined;
                    const n = tcp_stack.recvData(h.conn, &buf);
                    net_lock.unlock();
                    reply.* = fx.IpcMessage.init(fx.R_OK);
                    @memcpy(reply.data[0..n], buf[0..n]);
                    reply.data_len = n;
                    return;
                }
                if (tcp_stack.isEof(h.conn)) {
                    net_lock.unlock();
                    reply.* = fx.IpcMessage.init(fx.R_OK);
                    reply.data_len = 0;
                    return;
                }
                net_lock.unlock();
                fx.sleep(POLL_SLEEP_MS);
            }
            // Timeout — return 0 bytes (EOF)
            reply.* = fx.IpcMessage.init(fx.R_OK);
            reply.data_len = 0;
        },
        .tcp_status => {
            if (h.read_done) {
                reply.* = fx.IpcMessage.init(fx.R_OK);
                reply.data_len = 0;
                return;
            }
            net_lock.lock();
            const state = tcp_stack.getState(h.conn) orelse {
                net_lock.unlock();
                reply.* = fx.IpcMessage.init(fx.R_OK);
                reply.data_len = 0;
                return;
            };
            net_lock.unlock();
            const name = stateName(state);
            reply.* = fx.IpcMessage.init(fx.R_OK);
            @memcpy(reply.data[0..name.len], name);
            reply.data[name.len] = '\n';
            reply.data_len = @intCast(name.len + 1);
            h.read_done = true;
        },
        .tcp_local => {
            if (h.read_done) {
                reply.* = fx.IpcMessage.init(fx.R_OK);
                reply.data_len = 0;
                return;
            }
            net_lock.lock();
            const info = tcp_stack.getLocal(h.conn) orelse {
                net_lock.unlock();
                reply.* = fx.IpcMessage.init(fx.R_OK);
                reply.data_len = 0;
                return;
            };
            net_lock.unlock();
            var buf: [32]u8 = undefined;
            var pos: u16 = 0;
            pos += net.dns.formatIp(buf[pos..], info.ip);
            buf[pos] = '!';
            pos += 1;
            pos += net.dns.formatDec(buf[pos..], info.port);
            buf[pos] = '\n';
            pos += 1;
            reply.* = fx.IpcMessage.init(fx.R_OK);
            @memcpy(reply.data[0..pos], buf[0..pos]);
            reply.data_len = pos;
            h.read_done = true;
        },
        .tcp_remote => {
            if (h.read_done) {
                reply.* = fx.IpcMessage.init(fx.R_OK);
                reply.data_len = 0;
                return;
            }
            net_lock.lock();
            const info = tcp_stack.getRemote(h.conn) orelse {
                net_lock.unlock();
                reply.* = fx.IpcMessage.init(fx.R_OK);
                reply.data_len = 0;
                return;
            };
            net_lock.unlock();
            var buf: [32]u8 = undefined;
            var pos: u16 = 0;
            pos += net.dns.formatIp(buf[pos..], info.ip);
            buf[pos] = '!';
            pos += 1;
            pos += net.dns.formatDec(buf[pos..], info.port);
            buf[pos] = '\n';
            pos += 1;
            reply.* = fx.IpcMessage.init(fx.R_OK);
            @memcpy(reply.data[0..pos], buf[0..pos]);
            reply.data_len = pos;
            h.read_done = true;
        },
        .tcp_listen => {
            // Block until a new connection arrives on the listener
            var iters: u32 = 0;
            while (iters < MAX_POLL_ITERS) : (iters += 1) {
                net_lock.lock();
                // Check if a child connection appeared (syn_received → established)
                const state = tcp_stack.getState(h.conn);
                net_lock.unlock();
                if (state == null) {
                    // Listener was closed
                    reply.* = fx.IpcMessage.init(fx.R_ERROR);
                    return;
                }
                // The kernel listen model returns the new conn index.
                // For netd, the listener stays in .listen and new connections
                // get their own indices — handled by tcp_stack.handlePacket.
                // For now, just indicate listen is active.
                fx.sleep(POLL_SLEEP_MS);
            }
            reply.* = fx.IpcMessage.init(fx.R_OK);
            reply.data_len = 0;
        },
        .tcp_ctl => {
            reply.* = fx.IpcMessage.init(fx.R_OK);
            reply.data_len = 0;
        },
        .dns_query => {
            if (h.read_done) {
                reply.* = fx.IpcMessage.init(fx.R_OK);
                reply.data_len = 0;
                return;
            }
            net_lock.lock();
            const ip = dns_resolver.getResult() orelse {
                net_lock.unlock();
                reply.* = fx.IpcMessage.init(fx.R_OK);
                reply.data_len = 0;
                return;
            };
            net_lock.unlock();
            var buf: [20]u8 = undefined;
            var pos: u16 = 0;
            pos += net.dns.formatIp(&buf, ip);
            buf[pos] = '\n';
            pos += 1;
            reply.* = fx.IpcMessage.init(fx.R_OK);
            @memcpy(reply.data[0..pos], buf[0..pos]);
            reply.data_len = pos;
            h.read_done = true;
        },
        .dns_ctl => {
            reply.* = fx.IpcMessage.init(fx.R_OK);
            reply.data_len = 0;
        },
        .dns_cache => {
            if (h.read_done) {
                reply.* = fx.IpcMessage.init(fx.R_OK);
                reply.data_len = 0;
                return;
            }
            net_lock.lock();
            var buf: [4092]u8 = undefined;
            const len = dns_resolver.getCacheText(&buf);
            net_lock.unlock();
            reply.* = fx.IpcMessage.init(fx.R_OK);
            @memcpy(reply.data[0..len], buf[0..len]);
            reply.data_len = len;
            h.read_done = true;
        },
        .icmp_clone => {
            if (h.read_done) {
                reply.* = fx.IpcMessage.init(fx.R_OK);
                reply.data_len = 0;
                return;
            }
            var buf: [8]u8 = undefined;
            const len = formatDec(&buf, h.conn);
            buf[len] = '\n';
            reply.* = fx.IpcMessage.init(fx.R_OK);
            const total = len + 1;
            @memcpy(reply.data[0..total], buf[0..total]);
            reply.data_len = @intCast(total);
            h.read_done = true;
        },
        .icmp_data => {
            // Poll for reply
            var iters: u32 = 0;
            while (iters < MAX_POLL_ITERS) : (iters += 1) {
                net_lock.lock();
                if (icmp_handler.hasReply(h.conn)) {
                    var buf: [128]u8 = undefined;
                    const n = icmp_handler.getReplyText(h.conn, &buf);
                    net_lock.unlock();
                    if (n > 0) {
                        reply.* = fx.IpcMessage.init(fx.R_OK);
                        @memcpy(reply.data[0..n], buf[0..n]);
                        reply.data_len = n;
                        return;
                    }
                }
                if (icmp_handler.isTimedOut(h.conn)) {
                    icmp_handler.clearTimeout(h.conn);
                    net_lock.unlock();
                    const timeout_msg = "timeout\n";
                    reply.* = fx.IpcMessage.init(fx.R_OK);
                    @memcpy(reply.data[0..timeout_msg.len], timeout_msg);
                    reply.data_len = timeout_msg.len;
                    return;
                }
                net_lock.unlock();
                fx.sleep(POLL_SLEEP_MS);
            }
            reply.* = fx.IpcMessage.init(fx.R_OK);
            reply.data_len = 0;
        },
        .icmp_ctl => {
            reply.* = fx.IpcMessage.init(fx.R_OK);
            reply.data_len = 0;
        },
        .net_status => {
            if (h.read_done) {
                reply.* = fx.IpcMessage.init(fx.R_OK);
                reply.data_len = 0;
                return;
            }
            var buf: [256]u8 = undefined;
            var pos: u16 = 0;
            // mac line
            const mac_prefix = "mac ";
            @memcpy(buf[pos..][0..mac_prefix.len], mac_prefix);
            pos += mac_prefix.len;
            for (our_mac) |b| {
                buf[pos] = hexNibble(b >> 4);
                buf[pos + 1] = hexNibble(b & 0xF);
                pos += 2;
            }
            buf[pos] = '\n';
            pos += 1;
            // ip line
            const ip_prefix = "ip ";
            @memcpy(buf[pos..][0..ip_prefix.len], ip_prefix);
            pos += ip_prefix.len;
            pos += net.dns.formatIp(buf[pos..], our_ip);
            buf[pos] = '\n';
            pos += 1;
            // gateway line
            const gw_prefix = "gateway ";
            @memcpy(buf[pos..][0..gw_prefix.len], gw_prefix);
            pos += gw_prefix.len;
            pos += net.dns.formatIp(buf[pos..], gateway_ip);
            buf[pos] = '\n';
            pos += 1;
            // mask line
            const mask_prefix = "mask ";
            @memcpy(buf[pos..][0..mask_prefix.len], mask_prefix);
            pos += mask_prefix.len;
            pos += net.dns.formatIp(buf[pos..], subnet_mask);
            buf[pos] = '\n';
            pos += 1;

            reply.* = fx.IpcMessage.init(fx.R_OK);
            @memcpy(reply.data[0..pos], buf[0..pos]);
            reply.data_len = pos;
            h.read_done = true;
        },
        .arp_table => {
            if (h.read_done) {
                reply.* = fx.IpcMessage.init(fx.R_OK);
                reply.data_len = 0;
                return;
            }
            net_lock.lock();
            const cache = arp_table.getCache();
            net_lock.unlock();
            var buf: [2048]u8 = undefined;
            var pos: u16 = 0;
            for (cache) |entry| {
                if (!entry.valid) continue;
                pos += net.dns.formatIp(buf[pos..], entry.ip);
                buf[pos] = ' ';
                pos += 1;
                for (entry.mac) |b| {
                    buf[pos] = hexNibble(b >> 4);
                    buf[pos + 1] = hexNibble(b & 0xF);
                    pos += 2;
                }
                buf[pos] = '\n';
                pos += 1;
            }
            reply.* = fx.IpcMessage.init(fx.R_OK);
            const copy_len = @min(pos, 4092);
            @memcpy(reply.data[0..copy_len], buf[0..copy_len]);
            reply.data_len = copy_len;
            h.read_done = true;
        },
        .net_stats => {
            if (h.read_done) {
                reply.* = fx.IpcMessage.init(fx.R_OK);
                reply.data_len = 0;
                return;
            }
            net_lock.lock();
            const stx = tcp_stack.segments_tx;
            const srx = tcp_stack.segments_rx;
            const retx = tcp_stack.retransmits;
            const aopen = tcp_stack.active_opens;
            const popen = tcp_stack.passive_opens;
            const aconns = tcp_stack.activeConns();
            net_lock.unlock();

            var buf: [512]u8 = undefined;
            var pos: u16 = 0;
            pos = appendStatKV(&buf, pos, "segments_tx", stx);
            pos = appendStatKV(&buf, pos, "segments_rx", srx);
            pos = appendStatKV(&buf, pos, "retransmits", retx);
            pos = appendStatKV(&buf, pos, "active_opens", aopen);
            pos = appendStatKV(&buf, pos, "passive_opens", popen);
            pos = appendStatKV(&buf, pos, "active_conns", aconns);

            reply.* = fx.IpcMessage.init(fx.R_OK);
            @memcpy(reply.data[0..pos], buf[0..pos]);
            reply.data_len = pos;
            h.read_done = true;
        },
        .ipifc_ctl => {
            if (h.read_done) {
                reply.* = fx.IpcMessage.init(fx.R_OK);
                reply.data_len = 0;
                return;
            }
            var buf: [256]u8 = undefined;
            var pos: u16 = 0;
            // "ip IP mask MASK gateway GW mtu 1500\n"
            const ip_key = "ip ";
            @memcpy(buf[pos..][0..ip_key.len], ip_key);
            pos += ip_key.len;
            pos += net.dns.formatIp(buf[pos..], our_ip);
            const mask_key = " mask ";
            @memcpy(buf[pos..][0..mask_key.len], mask_key);
            pos += mask_key.len;
            pos += net.dns.formatIp(buf[pos..], subnet_mask);
            const gw_key = " gateway ";
            @memcpy(buf[pos..][0..gw_key.len], gw_key);
            pos += gw_key.len;
            pos += net.dns.formatIp(buf[pos..], gateway_ip);
            const mtu_key = " mtu 1500\n";
            @memcpy(buf[pos..][0..mtu_key.len], mtu_key);
            pos += mtu_key.len;

            reply.* = fx.IpcMessage.init(fx.R_OK);
            @memcpy(reply.data[0..pos], buf[0..pos]);
            reply.data_len = pos;
            h.read_done = true;
        },
    }
}

fn appendStatKV(buf: []u8, pos: u16, key: []const u8, val: u64) u16 {
    var p = pos;
    if (p + key.len >= buf.len) return p;
    @memcpy(buf[p..][0..key.len], key);
    p += @intCast(key.len);
    if (p >= buf.len) return p;
    buf[p] = ' ';
    p += 1;
    var dec_buf: [20]u8 = undefined;
    const dec_len = formatDec(&dec_buf, val);
    if (p + dec_len >= buf.len) return p;
    @memcpy(buf[p..][0..dec_len], dec_buf[0..dec_len]);
    p += @intCast(dec_len);
    if (p >= buf.len) return p;
    buf[p] = '\n';
    p += 1;
    return p;
}

fn handleWrite(msg: *fx.IpcMessage, reply: *fx.IpcMessage) void {
    const handle_id = readU32LE(msg.data[0..4]);
    const h = getHandle(handle_id) orelse {
        reply.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    // Data starts after 4-byte handle prefix
    if (msg.data_len <= 4) {
        reply.* = fx.IpcMessage.init(fx.R_OK);
        setReplyLen(reply, 0);
        return;
    }
    const data = msg.data[4..msg.data_len];

    switch (h.kind) {
        .tcp_ctl => {
            net_lock.lock();
            const result = handleCtlWrite(h.conn, data);
            net_lock.unlock();
            if (result) |n| {
                reply.* = fx.IpcMessage.init(fx.R_OK);
                setReplyLen(reply, n);
            } else {
                // Connect: poll for completion
                var iters: u32 = 0;
                while (iters < MAX_POLL_ITERS) : (iters += 1) {
                    net_lock.lock();
                    const state = tcp_stack.getState(h.conn);
                    net_lock.unlock();
                    if (state == null or state.? == .established) break;
                    if (state.? == .closed) break;
                    fx.sleep(POLL_SLEEP_MS);
                }
                reply.* = fx.IpcMessage.init(fx.R_OK);
                setReplyLen(reply, @intCast(data.len));
            }
        },
        .tcp_data => {
            net_lock.lock();
            const sent = tcp_stack.sendData(h.conn, data);
            net_lock.unlock();
            reply.* = fx.IpcMessage.init(fx.R_OK);
            setReplyLen(reply, sent);
        },
        .dns_query => {
            net_lock.lock();
            const result = handleDnsWrite(data);
            net_lock.unlock();
            if (result) |n| {
                reply.* = fx.IpcMessage.init(fx.R_OK);
                setReplyLen(reply, n);
            } else {
                // DNS query sent, poll for response
                var iters: u32 = 0;
                while (iters < MAX_POLL_ITERS) : (iters += 1) {
                    net_lock.lock();
                    if (dns_resolver.getResult() != null) {
                        net_lock.unlock();
                        break;
                    }
                    if (dns_resolver.hasPendingTimeout()) {
                        net_lock.unlock();
                        break;
                    }
                    net_lock.unlock();
                    fx.sleep(POLL_SLEEP_MS);
                }
                reply.* = fx.IpcMessage.init(fx.R_OK);
                setReplyLen(reply, @intCast(data.len));
            }
        },
        .dns_ctl => {
            net_lock.lock();
            const n = handleDnsCtlWrite(data);
            net_lock.unlock();
            reply.* = fx.IpcMessage.init(fx.R_OK);
            setReplyLen(reply, n);
        },
        .icmp_ctl => {
            net_lock.lock();
            const n = handleIcmpCtlWrite(h.conn, data);
            net_lock.unlock();
            reply.* = fx.IpcMessage.init(fx.R_OK);
            setReplyLen(reply, n);
        },
        .icmp_data => {
            net_lock.lock();
            if (icmp_handler.sendEchoRequest(h.conn, our_ip)) {
                net_lock.unlock();
                reply.* = fx.IpcMessage.init(fx.R_OK);
                setReplyLen(reply, @intCast(data.len));
            } else {
                net_lock.unlock();
                reply.* = fx.IpcMessage.init(fx.R_OK);
                setReplyLen(reply, 0);
            }
        },
        .arp_table => {
            // Write commands: "flush" or "del IP"
            var cmd_len: usize = data.len;
            while (cmd_len > 0 and (data[cmd_len - 1] == '\n' or data[cmd_len - 1] == ' ')) {
                cmd_len -= 1;
            }
            if (cmd_len == 5 and data[0] == 'f' and data[1] == 'l' and data[2] == 'u' and data[3] == 's' and data[4] == 'h') {
                net_lock.lock();
                arp_table.flush();
                net_lock.unlock();
                reply.* = fx.IpcMessage.init(fx.R_OK);
                setReplyLen(reply, @intCast(data.len));
            } else if (cmd_len > 4 and data[0] == 'd' and data[1] == 'e' and data[2] == 'l' and data[3] == ' ') {
                if (parseIp(data[4..cmd_len])) |ip| {
                    net_lock.lock();
                    arp_table.remove(ip);
                    net_lock.unlock();
                    reply.* = fx.IpcMessage.init(fx.R_OK);
                    setReplyLen(reply, @intCast(data.len));
                } else {
                    reply.* = fx.IpcMessage.init(fx.R_ERROR);
                }
            } else {
                reply.* = fx.IpcMessage.init(fx.R_ERROR);
            }
        },
        .ipifc_ctl => {
            // Write commands: "add IP mask GW"
            // For now, just update the global IP/mask/gateway
            var cmd_len: usize = data.len;
            while (cmd_len > 0 and (data[cmd_len - 1] == '\n' or data[cmd_len - 1] == ' ')) {
                cmd_len -= 1;
            }
            if (cmd_len > 4 and data[0] == 'a' and data[1] == 'd' and data[2] == 'd' and data[3] == ' ') {
                // Parse "add IP mask GW"
                const args = data[4..cmd_len];
                // Find spaces to split args
                var parts: [3][]const u8 = undefined;
                var part_count: usize = 0;
                var start: usize = 0;
                for (args, 0..) |c, ai| {
                    if (c == ' ') {
                        if (ai > start and part_count < 3) {
                            parts[part_count] = args[start..ai];
                            part_count += 1;
                        }
                        start = ai + 1;
                    }
                }
                if (start < args.len and part_count < 3) {
                    parts[part_count] = args[start..];
                    part_count += 1;
                }
                if (part_count == 3) {
                    if (parseIp(parts[0])) |ip| {
                        if (parseIp(parts[1])) |mask| {
                            if (parseIp(parts[2])) |gw| {
                                our_ip = ip;
                                subnet_mask = mask;
                                gateway_ip = gw;
                                reply.* = fx.IpcMessage.init(fx.R_OK);
                                setReplyLen(reply, @intCast(data.len));
                                return;
                            }
                        }
                    }
                }
                reply.* = fx.IpcMessage.init(fx.R_ERROR);
            } else {
                reply.* = fx.IpcMessage.init(fx.R_ERROR);
            }
        },
        else => {
            reply.* = fx.IpcMessage.init(fx.R_OK);
            setReplyLen(reply, 0);
        },
    }
}

fn handleClose(msg: *fx.IpcMessage, reply: *fx.IpcMessage) void {
    const handle_id = readU32LE(msg.data[0..4]);
    const h = getHandle(handle_id) orelse {
        reply.* = fx.IpcMessage.init(fx.R_OK);
        return;
    };

    net_lock.lock();
    switch (h.kind) {
        .tcp_data => tcp_stack.startClose(h.conn),
        .icmp_data => icmp_handler.close(h.conn),
        else => {},
    }
    net_lock.unlock();

    freeHandle(handle_id);
    reply.* = fx.IpcMessage.init(fx.R_OK);
}

fn handleStat(msg: *fx.IpcMessage, reply: *fx.IpcMessage) void {
    _ = msg;
    // Return a minimal stat struct
    reply.* = fx.IpcMessage.init(fx.R_OK);
    reply.data_len = @sizeOf(fx.Stat);
    @memset(reply.data[0..reply.data_len], 0);
}

// ── Protocol-specific write handlers ──────────────────────────────

fn handleCtlWrite(conn: u8, data: []const u8) ?u16 {
    const trimmed = trimNewline(data);

    if (startsWith(trimmed, "connect ")) {
        const args = trimmed[8..];
        const parsed = parseAddr(args) orelse return 0;
        if (!tcp_stack.connect(conn, parsed.ip, parsed.port)) return 0;
        // Return null to indicate blocking connect
        return null;
    }

    if (startsWith(trimmed, "announce ")) {
        const args = trimmed[9..];
        var port_str = args;
        if (startsWith(args, "*!")) {
            port_str = args[2..];
        }
        const port = parseDec(port_str) orelse return 0;
        if (!tcp_stack.announce(conn, @intCast(port))) return 0;
        return @intCast(data.len);
    }

    if (startsWith(trimmed, "hangup")) {
        tcp_stack.startClose(conn);
        return @intCast(data.len);
    }

    return 0;
}

fn handleDnsWrite(data: []const u8) ?u16 {
    const trimmed = trimNewline(data);

    if (startsWith(trimmed, "query ")) {
        const name = trimmed[6..];
        if (name.len == 0) return 0;

        if (dns_resolver.cacheLookup(name)) |_| {
            return @intCast(data.len);
        }

        if (!dns_resolver.query(name)) return 0;
        return null; // Block until response
    }

    return 0;
}

fn handleDnsCtlWrite(data: []const u8) u16 {
    const trimmed = trimNewline(data);

    if (startsWith(trimmed, "nameserver ")) {
        const ip_str = trimmed[11..];
        const ip = parseIp(ip_str) orelse return 0;
        dns_resolver.setNameserver(ip);
        return @intCast(data.len);
    }

    if (startsWith(trimmed, "flush")) {
        dns_resolver.flushCache();
        return @intCast(data.len);
    }

    return 0;
}

fn handleIcmpCtlWrite(conn: u8, data: []const u8) u16 {
    const trimmed = trimNewline(data);

    if (startsWith(trimmed, "connect ")) {
        const ip_str = trimmed[8..];
        const ip = parseIp(ip_str) orelse return 0;
        icmp_handler.setDst(conn, ip);
        return @intCast(data.len);
    }

    return 0;
}

// ── Frame RX thread ───────────────────────────────────────────────

fn rxThreadEntry(_: *anyopaque) callconv(.c) void {
    rxLoop();
}

fn rxLoop() noreturn {
    var frame_buf: [1600]u8 = undefined;

    while (true) {
        const n = fx.read(ETHER_FD, &frame_buf);
        if (n <= 0) {
            fx.sleep(1);
            continue;
        }

        const frame = frame_buf[0..@intCast(n)];
        const eth = net.ethernet.parse(frame) orelse continue;

        net_lock.lock();

        if (eth.header.ethertype == net.ethernet.ETHER_ARP) {
            var reply_buf: [64]u8 = undefined;
            if (arp_table.handlePacket(eth.payload, our_mac, our_ip, &reply_buf)) |reply_len| {
                net_lock.unlock();
                _ = fx.write(ETHER_FD, reply_buf[0..reply_len]);
                continue;
            }
        } else if (eth.header.ethertype == net.ethernet.ETHER_IPV4) {
            if (net.ipv4.parse(eth.payload)) |ip_result| {
                const ip_hdr = ip_result.header;
                const ip_payload = ip_result.payload;

                if (ip_hdr.protocol == net.ipv4.PROTO_TCP) {
                    tcp_stack.handlePacket(ip_payload, ip_hdr);
                } else if (ip_hdr.protocol == net.ipv4.PROTO_ICMP) {
                    var reply_buf: [1600]u8 = undefined;
                    if (icmp_handler.handlePacket(ip_payload, ip_hdr, our_ip, &reply_buf)) |reply_len| {
                        net_lock.unlock();
                        sendIpPacket(ip_hdr.src, reply_buf[0..reply_len]);
                        continue;
                    }
                } else if (ip_hdr.protocol == net.ipv4.PROTO_UDP) {
                    // Check if it's a DNS response (from port 53)
                    if (ip_payload.len >= 8) {
                        const src_port = @as(u16, ip_payload[0]) << 8 | ip_payload[1];
                        if (src_port == 53 and ip_payload.len > 8) {
                            _ = dns_resolver.handleResponse(ip_payload[8..]);
                        }
                    }
                }
            }
        }

        net_lock.unlock();
    }
}

// ── Timer thread ──────────────────────────────────────────────────

fn timerThreadEntry(_: *anyopaque) callconv(.c) void {
    timerLoop();
}

fn timerLoop() noreturn {
    while (true) {
        fx.sleep(TICK_MS);

        net_lock.lock();

        // TCP retransmission and TIME_WAIT expiry
        const now = getTicks();
        tcp_stack.tick(now);

        // DNS retry
        _ = dns_resolver.checkRetry();

        // ICMP timeouts
        var timeout_buf: [4]u8 = undefined;
        _ = icmp_handler.checkTimeouts(&timeout_buf);

        net_lock.unlock();
    }
}

// ── IPC worker loop ───────────────────────────────────────────────

fn workerEntry(_: *anyopaque) callconv(.c) void {
    workerLoop();
}

fn workerLoop() noreturn {
    var wmsg: fx.IpcMessage = undefined;
    var wreply: fx.IpcMessage = undefined;

    while (true) {
        const rc = fx.ipc_recv(SERVER_FD, &wmsg);
        if (rc < 0) continue;

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

// ── Entry point ───────────────────────────────────────────────────

export fn _start() noreturn {
    _ = fx.write(1, "netd: started\n");

    // Read MAC from ether device (first read before exclusive mode)
    // For now, use QEMU default MAC. TODO: read from ctl.

    // Initialize network stack
    tcp_stack = net.tcp.TcpStack.init(&sendTcpIpPacket, &getOurIp, &getTicks);
    tcp_stack.setWaiterCallback(&tcpWaiterCallback);
    tcp_stack.setMaxConnections(32);

    // DNS resolver needs an opaque context; use a dummy
    var dummy_ctx: u8 = 0;
    dns_resolver = net.dns.DnsResolver.init(
        &sendDnsUdp,
        &getTimeMs,
        @ptrCast(&dummy_ctx),
        nameserver_ip,
        10000,
    );

    icmp_handler = net.icmp.IcmpHandler.init(
        &sendIcmpIpPacket,
        &getTimeMs,
        @ptrCast(&dummy_ctx),
    );

    // Send gratuitous ARP to populate gateway's ARP cache
    var arp_buf: [64]u8 = undefined;
    if (net.arp.ArpTable.buildRequest(&arp_buf, our_mac, our_ip, gateway_ip)) |arp_len| {
        _ = fx.write(ETHER_FD, arp_buf[0..arp_len]);
    }

    // Spawn RX thread
    _ = fx.thread.spawnThread(rxThreadEntry, null) catch {};

    // Spawn timer thread
    _ = fx.thread.spawnThread(timerThreadEntry, null) catch {};

    // Spawn worker threads
    var i: usize = 0;
    while (i < NUM_WORKERS) : (i += 1) {
        _ = fx.thread.spawnThread(workerEntry, null) catch {};
    }

    // Main thread enters IPC worker loop
    workerLoop();
}

// ── Path parsing ──────────────────────────────────────────────────

const ConnPathResult = struct { kind: HandleKind, conn: u8 };

fn parseTcpConnPath(path: []const u8) ?ConnPathResult {
    var i: usize = 0;
    while (i < path.len and path[i] >= '0' and path[i] <= '9') : (i += 1) {}
    if (i == 0) return null;

    const conn_num = parseDec(path[0..i]) orelse return null;
    if (conn_num >= 256) return null;

    if (i >= path.len or path[i] != '/') return null;
    const subfile = path[i + 1 ..];

    const kind: HandleKind = if (eql(subfile, "ctl"))
        .tcp_ctl
    else if (eql(subfile, "data"))
        .tcp_data
    else if (eql(subfile, "listen"))
        .tcp_listen
    else if (eql(subfile, "status"))
        .tcp_status
    else if (eql(subfile, "local"))
        .tcp_local
    else if (eql(subfile, "remote"))
        .tcp_remote
    else
        return null;

    return .{ .conn = @intCast(conn_num), .kind = kind };
}

fn parseIcmpConnPath(path: []const u8) ?ConnPathResult {
    var i: usize = 0;
    while (i < path.len and path[i] >= '0' and path[i] <= '9') : (i += 1) {}
    if (i == 0) return null;

    const conn_num = parseDec(path[0..i]) orelse return null;
    if (conn_num >= 4) return null;

    if (i >= path.len or path[i] != '/') return null;
    const subfile = path[i + 1 ..];

    const kind: HandleKind = if (eql(subfile, "ctl"))
        .icmp_ctl
    else if (eql(subfile, "data"))
        .icmp_data
    else
        return null;

    return .{ .conn = @intCast(conn_num), .kind = kind };
}

fn parseAddr(s: []const u8) ?struct { ip: [4]u8, port: u16 } {
    var bang: ?usize = null;
    for (s, 0..) |ch, i| {
        if (ch == '!') {
            bang = i;
            break;
        }
    }
    const bang_pos = bang orelse return null;
    const ip = parseIp(s[0..bang_pos]) orelse return null;
    const port = parseDec(s[bang_pos + 1 ..]) orelse return null;
    if (port > 65535) return null;
    return .{ .ip = ip, .port = @intCast(port) };
}

fn parseIp(s: []const u8) ?[4]u8 {
    var ip: [4]u8 = undefined;
    var octet: u32 = 0;
    var idx: u8 = 0;
    var has_digit = false;

    for (s) |ch| {
        if (ch >= '0' and ch <= '9') {
            octet = octet * 10 + (ch - '0');
            if (octet > 255) return null;
            has_digit = true;
        } else if (ch == '.') {
            if (!has_digit or idx >= 3) return null;
            ip[idx] = @intCast(octet);
            idx += 1;
            octet = 0;
            has_digit = false;
        } else {
            return null;
        }
    }
    if (!has_digit or idx != 3) return null;
    ip[3] = @intCast(octet);
    return ip;
}

// ── Helpers ───────────────────────────────────────────────────────

fn readU32LE(bytes: *const [4]u8) u32 {
    return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) | (@as(u32, bytes[3]) << 24);
}

fn writeU32LE(bytes: *[4]u8, val: u32) void {
    bytes[0] = @truncate(val);
    bytes[1] = @truncate(val >> 8);
    bytes[2] = @truncate(val >> 16);
    bytes[3] = @truncate(val >> 24);
}

fn setReplyLen(reply: *fx.IpcMessage, len: u16) void {
    // Write len as LE u32 in first 4 bytes of reply data
    reply.data[0] = @truncate(len);
    reply.data[1] = @truncate(len >> 8);
    reply.data[2] = 0;
    reply.data[3] = 0;
    reply.data_len = 4;
}

fn formatDec(buf: []u8, val: anytype) u16 {
    var v: u64 = @intCast(val);
    var tmp: [20]u8 = undefined;
    var len: u16 = 0;
    if (v == 0) {
        buf[0] = '0';
        return 1;
    }
    while (v > 0) : (len += 1) {
        tmp[len] = @truncate('0' + @as(u8, @intCast(v % 10)));
        v /= 10;
    }
    var i: u16 = 0;
    while (i < len) : (i += 1) {
        buf[i] = tmp[len - 1 - i];
    }
    return len;
}

fn parseDec(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var val: u32 = 0;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return null;
        val = val * 10 + (ch - '0');
    }
    return val;
}

fn stateName(state: net.tcp.TcpState) []const u8 {
    return switch (state) {
        .closed => "Closed",
        .listen => "Listen",
        .syn_sent => "Syn_sent",
        .syn_received => "Syn_received",
        .established => "Established",
        .fin_wait_1 => "Fin_wait_1",
        .fin_wait_2 => "Fin_wait_2",
        .close_wait => "Close_wait",
        .last_ack => "Last_ack",
        .time_wait => "Time_wait",
        .closing => "Closing",
    };
}

fn hexNibble(v: u8) u8 {
    return if (v < 10) '0' + v else 'a' + v - 10;
}

fn trimNewline(data: []const u8) []const u8 {
    var end = data.len;
    while (end > 0 and (data[end - 1] == '\n' or data[end - 1] == '\r')) {
        end -= 1;
    }
    return data[0..end];
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    for (s[0..prefix.len], prefix) |a, b| {
        if (a != b) return false;
    }
    return true;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}
