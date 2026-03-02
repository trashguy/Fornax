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
const TICK_MS: u32 = 10;
const POLL_SLEEP_MS: u32 = 2;
const MAX_POLL_ITERS: u32 = 3000; // ~6 seconds max block (for listeners/icmp)
const TCP_DATA_POLL_ITERS: u32 = 50; // ~100ms for TCP data reads (enables select/poll)
const NUM_WORKERS = 3; // + main thread = 4

// Network config (QEMU defaults)
var our_mac: [6]u8 = .{ 0, 0, 0, 0, 0, 0 };
var our_ip: [4]u8 = .{ 10, 0, 2, 15 };
var gateway_ip: [4]u8 = .{ 10, 0, 2, 2 };
var subnet_mask: [4]u8 = .{ 255, 255, 255, 0 };
var nameserver_ip: [4]u8 = .{ 10, 0, 2, 3 };

// ── DHCP state ────────────────────────────────────────────────────
const DhcpState = enum(u8) { idle, selecting, requesting, bound };
var dhcp_state: DhcpState = .idle;
var dhcp_xid: u32 = 0x464E5831; // "FNX1"
var dhcp_offered_ip: [4]u8 = .{ 0, 0, 0, 0 };
var dhcp_server_ip: [4]u8 = .{ 0, 0, 0, 0 };
var dhcp_retry_count: u8 = 0;
var dhcp_retry_timer: u32 = 0; // ticks until next retry
const DHCP_MAX_RETRIES: u8 = 4;
// BSS buffers for DHCP packet building
var dhcp_tx_buf: [600]u8 = undefined;
var dhcp_ip_buf: [1600]u8 = undefined;
var dhcp_frame_buf: [1600]u8 = undefined;

// ── Handle tracking ───────────────────────────────────────────────

const HandleKind = enum(u8) {
    tcp_clone,
    tcp_ctl,
    tcp_data,
    tcp_listen,
    tcp_status,
    tcp_local,
    tcp_remote,
    tcp_global_ctl,
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
    tcp_stream,
};

const Handle = struct {
    active: bool = false,
    kind: HandleKind = .tcp_clone,
    conn: u16 = 0,
    read_done: bool = false,
    shmem_id: u32 = 0,
    ring_ptr: ?[*]u8 = null,
};

var handles: [MAX_HANDLES]Handle = [_]Handle{.{}} ** MAX_HANDLES;

fn allocHandle(kind: HandleKind, conn: u16) ?u32 {
    // Start from 1: handle 0 is reserved (kernel treats server_handle=0 as "no handle")
    for (handles[1..], 1..) |*h, i| {
        if (!h.active) {
            h.* = .{ .active = true, .kind = kind, .conn = conn, .read_done = false };
            return @intCast(i);
        }
    }
    return null;
}

fn freeHandle(idx: u32) void {
    if (idx < MAX_HANDLES) {
        handles[idx].ring_ptr = null;
        handles[idx].shmem_id = 0;
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

// ── Deferred TX queue ────────────────────────────────────────────
// TCP sendFn builds full Ethernet frames into this ring while holding
// net_lock.  The caller flushes the queue via flushDeferredTx() after
// releasing net_lock, avoiding blocking I/O under the lock.
const DEFERRED_TX_SLOTS = 128; // must exceed ceil(tx_buf_size / MSS) ≈ 90
const DEFERRED_TX_MTU = 4096; // max frame (1518 normal, up to 4K for TSO)
// Double-buffered: side 0 and side 1.  enqueueDeferredTx writes to the
// active side; flushDeferredTx atomically swaps sides and writes from
// the now-inactive side without holding the lock, avoiding both the
// race (overwriting data being read) and contention (blocking enqueuers
// during I/O).
var deferred_tx_bufs: [2][DEFERRED_TX_SLOTS][DEFERRED_TX_MTU]u8 = undefined;
var deferred_tx_lens: [2][DEFERRED_TX_SLOTS]u16 = .{ .{0} ** DEFERRED_TX_SLOTS, .{0} ** DEFERRED_TX_SLOTS };
var deferred_tx_count: u8 = 0;
var deferred_tx_active: u1 = 0;
var deferred_tx_flushing: bool = false;
var deferred_tx_lock: Mutex = .{};

fn enqueueDeferredTx(frame: []const u8) bool {
    deferred_tx_lock.lock();
    defer deferred_tx_lock.unlock();
    if (deferred_tx_count >= DEFERRED_TX_SLOTS or frame.len > DEFERRED_TX_MTU) return false;
    const side = deferred_tx_active;
    const slot = deferred_tx_count;
    @memcpy(deferred_tx_bufs[side][slot][0..frame.len], frame);
    deferred_tx_lens[side][slot] = @intCast(frame.len);
    deferred_tx_count += 1;
    return true;
}

fn flushDeferredTx() void {
    deferred_tx_lock.lock();
    if (deferred_tx_flushing or deferred_tx_count == 0) {
        deferred_tx_lock.unlock();
        return;
    }
    deferred_tx_flushing = true;
    const count: u32 = deferred_tx_count;
    const flush_side = deferred_tx_active;
    deferred_tx_active ^= 1;
    deferred_tx_count = 0;
    deferred_tx_lock.unlock();

    // Batch send: build iovec array and flush with single writev syscall
    var iovecs: [DEFERRED_TX_SLOTS]fx.Iovec = undefined;
    for (0..count) |i| {
        iovecs[i] = .{
            .ptr = @intFromPtr(&deferred_tx_bufs[flush_side][i]),
            .len = deferred_tx_lens[flush_side][i],
        };
    }
    const sent: u32 = @intCast(@min(fx.writev(ETHER_FD, iovecs[0..count]), count));

    // If writev couldn't send all frames (virtio TX ring full), retry
    // the remaining frames after a brief yield to let QEMU consume some.
    if (sent < count) {
        var remaining = count - sent;
        var base = sent;
        var retries: u32 = 0;
        while (remaining > 0 and retries < 8) : (retries += 1) {
            fx.sleep(1); // yield — let QEMU reclaim TX descriptors
            const r = fx.writev(ETHER_FD, iovecs[base..][0..remaining]);
            if (r == 0 or r > remaining) break; // error or nothing sent
            const n: u32 = @intCast(r);
            base += n;
            remaining -= n;
        }
    }

    deferred_tx_lock.lock();
    deferred_tx_flushing = false;
    deferred_tx_lock.unlock();
}

// ── ARP-pending packet queue ─────────────────────────────────────
// When a packet can't be sent because the ARP entry is missing, we
// buffer it here. When an ARP reply arrives, we drain the queue.
const ARP_PENDING_SLOTS = 8;
const ARP_PENDING_MTU = 1500;
var arp_pending_bufs: [ARP_PENDING_SLOTS][ARP_PENDING_MTU]u8 = undefined;
var arp_pending_lens: [ARP_PENDING_SLOTS]u16 = .{0} ** ARP_PENDING_SLOTS;
var arp_pending_ips: [ARP_PENDING_SLOTS][4]u8 = .{.{0} ** 4} ** ARP_PENDING_SLOTS;
var arp_pending_count: u8 = 0;

fn enqueueArpPending(dst_ip: [4]u8, ip_packet: []const u8) void {
    if (ip_packet.len > ARP_PENDING_MTU) return;
    // Overwrite oldest if full (circular)
    const slot = if (arp_pending_count < ARP_PENDING_SLOTS) blk: {
        const s = arp_pending_count;
        arp_pending_count += 1;
        break :blk s;
    } else 0;
    @memcpy(arp_pending_bufs[slot][0..ip_packet.len], ip_packet);
    arp_pending_lens[slot] = @intCast(ip_packet.len);
    arp_pending_ips[slot] = dst_ip;
}

fn drainArpPending() void {
    var i: u8 = 0;
    while (i < arp_pending_count) {
        const dst_ip = arp_pending_ips[i];
        const target_ip = if (sameSubnet(dst_ip)) dst_ip else gateway_ip;
        if (arp_table.lookup(target_ip)) |mac| {
            const pkt = arp_pending_bufs[i][0..arp_pending_lens[i]];
            const frame_len = net.ethernet.build(&net_frame_buf, mac, our_mac, net.ethernet.ETHER_IPV4, pkt) orelse {
                i += 1;
                continue;
            };
            _ = enqueueDeferredTx(net_frame_buf[0..frame_len]);
            // Remove by shifting
            var j: u8 = i;
            while (j + 1 < arp_pending_count) : (j += 1) {
                arp_pending_bufs[j] = arp_pending_bufs[j + 1];
                arp_pending_lens[j] = arp_pending_lens[j + 1];
                arp_pending_ips[j] = arp_pending_ips[j + 1];
            }
            arp_pending_count -= 1;
        } else {
            i += 1;
        }
    }
}

// ── Callbacks for the network stack ───────────────────────────────

fn sendTcpIpPacket(dst_ip: [4]u8, tcp_segment: []const u8) bool {
    // Build IP header around TCP segment (BSS — see docs/aarch64-gotchas.md §5)
    const ip_len = net.ipv4.build(&net_tcp_ip_buf, our_ip, dst_ip, net.ipv4.PROTO_TCP, 64, blk: {
        const id = packet_id_counter;
        packet_id_counter +%= 1;
        break :blk id;
    }, tcp_segment) orelse return false;

    return sendIpPacketDeferred(dst_ip, net_tcp_ip_buf[0..ip_len]);
}

/// In-place frame send: TCP header at frame_buf[34..54], payload at frame_buf[54..].
/// We fill ETH (0..14) and IP (14..34) headers, then enqueue the complete frame.
fn sendTcpFrame(dst_ip: [4]u8, frame_buf: []u8, tcp_len: u16) bool {
    // IP header at [14..34], payload = tcp_len bytes at [34..]
    _ = net.ipv4.buildHeaderOnly(frame_buf[14..], our_ip, dst_ip, net.ipv4.PROTO_TCP, 64, blk: {
        const id = packet_id_counter;
        packet_id_counter +%= 1;
        break :blk id;
    }, tcp_len) orelse return false;

    // ARP lookup for destination MAC
    const target_ip = if (sameSubnet(dst_ip)) dst_ip else gateway_ip;
    const mac = arp_table.lookup(target_ip) orelse {
        // Rare ARP miss: fall back to deferred IP path
        const ip_len: usize = 20 + @as(usize, tcp_len);
        return sendIpPacketDeferred(dst_ip, frame_buf[14..][0..ip_len]);
    };

    // ETH header at [0..14]
    const ip_total: usize = 20 + @as(usize, tcp_len);
    _ = net.ethernet.buildHeaderOnly(frame_buf, mac, our_mac, net.ethernet.ETHER_IPV4, ip_total) orelse return false;
    const frame_len = 14 + ip_total;
    return enqueueDeferredTx(frame_buf[0..frame_len]);
}

// BSS buffers for packet building — avoids LLVM aarch64 stack-slot reuse
// bug with multiple large `= undefined` arrays (see docs/aarch64-gotchas.md §5).
var net_arp_buf: [64]u8 = undefined;
var net_frame_buf: [1600]u8 = undefined;
var net_udp_buf: [600]u8 = undefined;
var net_dns_ip_buf: [1600]u8 = undefined;
var net_tcp_ip_buf: [1600]u8 = undefined;

fn sendIpPacket(dst_ip: [4]u8, ip_packet: []const u8) void {
    // Determine MAC: gateway or direct
    const target_ip = if (sameSubnet(dst_ip)) dst_ip else gateway_ip;
    const mac = arp_table.lookup(target_ip) orelse {
        // Queue packet for resend when ARP resolves
        enqueueArpPending(dst_ip, ip_packet);
        if (net.arp.ArpTable.buildRequest(&net_arp_buf, our_mac, our_ip, target_ip)) |arp_len| {
            _ = fx.write(ETHER_FD, net_arp_buf[0..arp_len]);
        }
        return;
    };

    // Wrap in Ethernet frame
    const frame_len = net.ethernet.build(&net_frame_buf, mac, our_mac, net.ethernet.ETHER_IPV4, ip_packet) orelse return;
    _ = fx.write(ETHER_FD, net_frame_buf[0..frame_len]);
}

/// Like sendIpPacket but enqueues the frame into the deferred TX queue
/// instead of calling fx.write() directly. Used by TCP sendFn callback
/// which runs under net_lock — actual I/O happens after lock release.
fn sendIpPacketDeferred(dst_ip: [4]u8, ip_packet: []const u8) bool {
    const target_ip = if (sameSubnet(dst_ip)) dst_ip else gateway_ip;
    const mac = arp_table.lookup(target_ip) orelse {
        // Queue packet for resend when ARP resolves
        enqueueArpPending(dst_ip, ip_packet);
        if (net.arp.ArpTable.buildRequest(&net_arp_buf, our_mac, our_ip, target_ip)) |arp_len| {
            _ = enqueueDeferredTx(net_arp_buf[0..arp_len]);
        }
        return true; // ARP pending is not a queue-full failure
    };
    const frame_len = net.ethernet.build(&net_frame_buf, mac, our_mac, net.ethernet.ETHER_IPV4, ip_packet) orelse return true;
    return enqueueDeferredTx(net_frame_buf[0..frame_len]);
}

fn sendIcmpIpPacket(ctx: *anyopaque, dst_ip: [4]u8, ip_packet: []const u8) void {
    _ = ctx;
    sendIpPacket(dst_ip, ip_packet);
}

fn sendDnsUdp(ctx: *anyopaque, dst_ip: [4]u8, src_port: u16, dst_port: u16, data: []const u8) void {
    _ = ctx;
    // Build UDP packet
    const udp_len = buildUdp(&net_udp_buf, src_port, dst_port, data) orelse return;

    // Wrap in IP
    const id = packet_id_counter;
    packet_id_counter +%= 1;
    const ip_len = net.ipv4.build(&net_dns_ip_buf, our_ip, dst_ip, net.ipv4.PROTO_UDP, 64, id, net_udp_buf[0..udp_len]) orelse return;

    sendIpPacket(dst_ip, net_dns_ip_buf[0..ip_len]);
}

fn getOurIp() [4]u8 {
    return our_ip;
}

/// Send a gratuitous ARP to keep the gateway's ARP cache fresh.
fn sendGratuitousArp() void {
    var buf: [64]u8 = undefined;
    if (net.arp.ArpTable.buildRequest(&buf, our_mac, our_ip, gateway_ip)) |len| {
        _ = fx.write(ETHER_FD, buf[0..len]);
    }
}

// ── DHCP client ───────────────────────────────────────────────────

/// Send a raw DHCP packet as a broadcast Ethernet frame.
/// DHCP uses 0.0.0.0 → 255.255.255.255 UDP 68→67 with broadcast MAC.
fn sendDhcpBroadcast(dhcp_payload: []const u8) void {
    // Build UDP: src_port=68 dst_port=67
    const udp_len = buildUdp(&dhcp_tx_buf, net.dhcp.CLIENT_PORT, net.dhcp.SERVER_PORT, dhcp_payload) orelse return;

    // Build IP: src=0.0.0.0, dst=255.255.255.255
    const src_ip = [4]u8{ 0, 0, 0, 0 };
    const dst_ip = [4]u8{ 255, 255, 255, 255 };
    const id = packet_id_counter;
    packet_id_counter +%= 1;
    const ip_len = net.ipv4.build(&dhcp_ip_buf, src_ip, dst_ip, net.ipv4.PROTO_UDP, 64, id, dhcp_tx_buf[0..udp_len]) orelse return;

    // Build Ethernet frame: broadcast destination
    const bcast_mac = [6]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    const frame_len = net.ethernet.build(&dhcp_frame_buf, bcast_mac, our_mac, net.ethernet.ETHER_IPV4, dhcp_ip_buf[0..ip_len]) orelse return;

    _ = fx.write(ETHER_FD, dhcp_frame_buf[0..frame_len]);
}

/// Start DHCP discovery process. Must be called with net_lock held.
fn dhcpStart() void {
    dhcp_state = .selecting;
    dhcp_retry_count = 0;
    dhcp_retry_timer = 0;
    dhcp_xid +%= 1;

    // Build and send DISCOVER
    var buf: [512]u8 = undefined;
    const len = net.dhcp.buildDiscover(our_mac, dhcp_xid, &buf) orelse return;
    sendDhcpBroadcast(buf[0..len]);
    dhcp_retry_timer = 200; // 2s (200 × 10ms ticks)
    _ = fx.write(1, "netd: DHCP DISCOVER sent\n");
}

/// Handle a DHCP reply (called from rxLoop). Must be called with net_lock held.
fn dhcpHandleReply(udp_payload: []const u8) void {
    const reply = net.dhcp.parseReply(udp_payload) orelse return;

    switch (dhcp_state) {
        .selecting => {
            if (reply.msg_type == net.dhcp.MSG_OFFER) {
                dhcp_offered_ip = reply.your_ip;
                dhcp_server_ip = reply.server_ip;

                // Send REQUEST
                dhcp_state = .requesting;
                dhcp_retry_count = 0;
                dhcp_retry_timer = 200; // 2s
                var buf: [512]u8 = undefined;
                const len = net.dhcp.buildRequest(our_mac, dhcp_xid, dhcp_offered_ip, dhcp_server_ip, &buf) orelse return;
                sendDhcpBroadcast(buf[0..len]);
                _ = fx.write(1, "netd: DHCP OFFER received, REQUEST sent\n");
            }
        },
        .requesting => {
            if (reply.msg_type == net.dhcp.MSG_ACK) {
                // Apply configuration
                our_ip = reply.your_ip;
                subnet_mask = reply.subnet_mask;
                if (reply.router[0] != 0 or reply.router[1] != 0 or reply.router[2] != 0 or reply.router[3] != 0) {
                    gateway_ip = reply.router;
                }
                if (reply.dns[0] != 0 or reply.dns[1] != 0 or reply.dns[2] != 0 or reply.dns[3] != 0) {
                    nameserver_ip = reply.dns;
                    dns_resolver.setNameserver(nameserver_ip);
                }

                dhcp_state = .bound;
                sendGratuitousArp();
                _ = fx.write(1, "netd: DHCP BOUND\n");
            } else if (reply.msg_type == net.dhcp.MSG_NAK) {
                // Restart discovery
                dhcpStart();
            }
        },
        .bound => {
            // Ignore replies when bound (could be renewal later)
        },
        .idle => {},
    }
}

/// DHCP retry timer — called from timerLoop with net_lock held.
fn dhcpTimerTick() void {
    if (dhcp_state == .idle or dhcp_state == .bound) return;

    if (dhcp_retry_timer > 0) {
        dhcp_retry_timer -= 1;
        return;
    }

    // Timer expired — retry
    dhcp_retry_count += 1;
    if (dhcp_retry_count >= DHCP_MAX_RETRIES) {
        _ = fx.write(1, "netd: DHCP failed, falling back to defaults\n");
        dhcp_state = .idle;
        return;
    }

    // Exponential backoff: 2s, 4s, 8s, 16s
    const backoff: u32 = @as(u32, 200) << @intCast(dhcp_retry_count);
    dhcp_retry_timer = backoff;

    if (dhcp_state == .selecting) {
        var buf: [512]u8 = undefined;
        const len = net.dhcp.buildDiscover(our_mac, dhcp_xid, &buf) orelse return;
        sendDhcpBroadcast(buf[0..len]);
    } else if (dhcp_state == .requesting) {
        var buf: [512]u8 = undefined;
        const len = net.dhcp.buildRequest(our_mac, dhcp_xid, dhcp_offered_ip, dhcp_server_ip, &buf) orelse return;
        sendDhcpBroadcast(buf[0..len]);
    }
}

fn getTicks() u32 {
    const info = fx.sysinfo() orelse return 0;
    // Convert uptime_ms to 100Hz ticks (TICK_MS=10)
    return @truncate(info.uptime_ms / TICK_MS);
}

fn getTimeMs(ctx: *anyopaque) u64 {
    _ = ctx;
    const info = fx.sysinfo() orelse return 0;
    return info.uptime_ms;
}

fn tcpWaiterCallback(conn_idx: u16, event: net.tcp.WaiterEvent) void {
    // The blocked IPC worker thread polls for data changes,
    // so we don't need to do anything here for v1.
    _ = conn_idx;
    _ = event;
}

fn tcpAllocBuf(len: u32) ?[*]u8 {
    const MAP_ANONYMOUS: u64 = 0x20;
    const MAP_PRIVATE: u64 = 0x02;
    const PROT_READ: u64 = 0x1;
    const PROT_WRITE: u64 = 0x2;
    const addr = fx.mmap(0, len, PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_PRIVATE);
    if (addr == 0 or addr > 0xFFFF_FFFF_FFFF_0000) return null;
    return @ptrFromInt(addr);
}

fn tcpFreeBuf(ptr: [*]u8, len: u32) void {
    _ = fx.munmap(@intFromPtr(ptr), len);
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
    // T_OPEN data = [path] (no header — unlike T_WRITE/T_READ which have a handle prefix)
    if (msg.data_len == 0) {
        reply.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }
    const path_bytes = msg.data[0..msg.data_len];

    // Strip leading "net/" if present (namespace mount point variation)
    var path = path_bytes;
    if (path.len > 4 and path[0] == 'n' and path[1] == 'e' and path[2] == 't' and path[3] == '/') {
        path = path[4..];
    }

    // Lock protects handle table + tcp_stack/icmp_handler alloc
    net_lock.lock();
    defer net_lock.unlock();

    // Parse the path
    if (eql(path, "status")) {
        if (allocHandle(.net_status, 0)) |h| {
            reply.* = fx.IpcMessage.init(fx.R_OK);
            writeU32LE(reply.data[0..4], h);
            reply.data_len = 4;
            return;
        }
    } else if (eql(path, "tcp/ctl")) {
        if (allocHandle(.tcp_global_ctl, 0)) |h| {
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
            // Respect the caller's requested read count (offset 8 in T_READ msg)
            const max_read: u32 = 65536 - 4; // IPC data minus handle prefix
            const requested: u32 = if (msg.data_len >= 12) @intCast(@min(readU32LE(msg.data[8..12]), max_read)) else max_read;
            // Poll for data with short timeout (~100ms) to support select/poll
            var iters: u32 = 0;
            while (iters < TCP_DATA_POLL_ITERS) : (iters += 1) {
                if (tcp_stack.hasData(h.conn)) {
                    // Read directly into reply.data to avoid stack-allocated temp buffer
                    reply.* = fx.IpcMessage.init(fx.R_OK);
                    const n = @min(tcp_stack.recvData(h.conn, reply.data[0..requested]), requested);
                    reply.data_len = n;
                    return;
                }
                if (tcp_stack.isEof(h.conn)) {
                    reply.* = fx.IpcMessage.init(fx.R_OK);
                    reply.data_len = 0;
                    return;
                }
                fx.sleep(POLL_SLEEP_MS);
            }
            // No data available yet (not EOF) — return R_AGAIN so clients
            // can distinguish "try later" from "connection closed"
            reply.* = fx.IpcMessage.init(fx.R_AGAIN);
            reply.data_len = 0;
        },
        .tcp_status => {
            if (h.read_done) {
                reply.* = fx.IpcMessage.init(fx.R_OK);
                reply.data_len = 0;
                return;
            }
            const state = tcp_stack.getState(h.conn) orelse {
                reply.* = fx.IpcMessage.init(fx.R_OK);
                reply.data_len = 0;
                return;
            };
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
            const info = tcp_stack.getLocal(h.conn) orelse {
                reply.* = fx.IpcMessage.init(fx.R_OK);
                reply.data_len = 0;
                return;
            };
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
            const info = tcp_stack.getRemote(h.conn) orelse {
                reply.* = fx.IpcMessage.init(fx.R_OK);
                reply.data_len = 0;
                return;
            };
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
                // Check if a child connection appeared (syn_received → established)
                const state = tcp_stack.getState(h.conn);
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
        .tcp_global_ctl => {
            if (h.read_done) {
                reply.* = fx.IpcMessage.init(fx.R_OK);
                reply.data_len = 0;
                return;
            }
            var buf: [512]u8 = undefined;
            var pos: u16 = 0;
            pos = appendStatKV(&buf, pos, "maxconn", tcp_stack.max_connections);
            pos = appendStatKV(&buf, pos, "active", tcp_stack.activeConns());
            pos = appendStatKV(&buf, pos, "rmem", tcp_stack.rx_buf_size);
            pos = appendStatKV(&buf, pos, "wmem", tcp_stack.tx_buf_size);
            pos = appendStatKV(&buf, pos, "maxretries", tcp_stack.max_retries);
            pos = appendStatKV(&buf, pos, "fin_timeout", tcp_stack.time_wait_ticks);
            // portrange as two values
            {
                const pr_key = "portrange ";
                if (pos + pr_key.len < buf.len) {
                    @memcpy(buf[pos..][0..pr_key.len], pr_key);
                    pos += pr_key.len;
                    var dec_buf: [20]u8 = undefined;
                    var dl = formatDec(&dec_buf, tcp_stack.port_lo);
                    if (pos + dl < buf.len) {
                        @memcpy(buf[pos..][0..dl], dec_buf[0..dl]);
                        pos += dl;
                    }
                    if (pos < buf.len) {
                        buf[pos] = ' ';
                        pos += 1;
                    }
                    dl = formatDec(&dec_buf, tcp_stack.port_hi);
                    if (pos + dl < buf.len) {
                        @memcpy(buf[pos..][0..dl], dec_buf[0..dl]);
                        pos += dl;
                    }
                    if (pos < buf.len) {
                        buf[pos] = '\n';
                        pos += 1;
                    }
                }
            }
            pos = appendStatKV(&buf, pos, "keepalive", tcp_stack.keepalive_ticks);
            pos = appendStatKV(&buf, pos, "tw_reuse", @as(u64, if (tcp_stack.tw_reuse) 1 else 0));
            pos = appendStatKV(&buf, pos, "rto", tcp_stack.initial_rto);
            pos = appendStatKV(&buf, pos, "mss", tcp_stack.default_mss);
            pos = appendStatKV(&buf, pos, "cwndmax", tcp_stack.cwnd_max);
            pos = appendStatKV(&buf, pos, "nodelay", @as(u64, if (tcp_stack.nodelay) 1 else 0));
            pos = appendStatKV(&buf, pos, "window", tcp_stack.default_window);
            pos = appendStatKV(&buf, pos, "segments_tx", @atomicLoad(u64, &tcp_stack.segments_tx, .monotonic));
            pos = appendStatKV(&buf, pos, "segments_rx", @atomicLoad(u64, &tcp_stack.segments_rx, .monotonic));
            pos = appendStatKV(&buf, pos, "retransmits", @atomicLoad(u64, &tcp_stack.retransmits, .monotonic));
            reply.* = fx.IpcMessage.init(fx.R_OK);
            const copy_len = @min(pos, 65532);
            @memcpy(reply.data[0..copy_len], buf[0..copy_len]);
            reply.data_len = copy_len;
            h.read_done = true;
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
            const icmp_idx: u8 = @intCast(h.conn);
            // Poll for reply
            var iters: u32 = 0;
            while (iters < MAX_POLL_ITERS) : (iters += 1) {
                net_lock.lock();
                if (icmp_handler.hasReply(icmp_idx)) {
                    var buf: [128]u8 = undefined;
                    const n = icmp_handler.getReplyText(icmp_idx, &buf);
                    net_lock.unlock();
                    if (n > 0) {
                        reply.* = fx.IpcMessage.init(fx.R_OK);
                        @memcpy(reply.data[0..n], buf[0..n]);
                        reply.data_len = n;
                        return;
                    }
                }
                if (icmp_handler.isTimedOut(icmp_idx)) {
                    icmp_handler.clearTimeout(icmp_idx);
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
            const copy_len = @min(pos, 65532);
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
            const stx = @atomicLoad(u64, &tcp_stack.segments_tx, .monotonic);
            const srx = @atomicLoad(u64, &tcp_stack.segments_rx, .monotonic);
            const retx = @atomicLoad(u64, &tcp_stack.retransmits, .monotonic);
            const aopen = @atomicLoad(u64, &tcp_stack.active_opens, .monotonic);
            const popen = @atomicLoad(u64, &tcp_stack.passive_opens, .monotonic);
            const aconns = tcp_stack.activeConns();

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
        .tcp_stream => {
            // Stream handles use shared memory for writes; reads still via IPC
            reply.* = fx.IpcMessage.init(fx.R_OK);
            reply.data_len = 0;
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
            const result = handleCtlWrite(h.conn, data);
            flushDeferredTx();
            if (result) |n| {
                reply.* = fx.IpcMessage.init(fx.R_OK);
                setReplyLen(reply, n);
            } else {
                // Connect: poll for completion
                var iters: u32 = 0;
                while (iters < MAX_POLL_ITERS) : (iters += 1) {
                    const state = tcp_stack.getState(h.conn);
                    if (state == null or state.? == .established) break;
                    if (state.? == .closed) break;
                    fx.sleep(POLL_SLEEP_MS);
                }
                // Check if connection actually established
                const final_state = tcp_stack.getState(h.conn);
                reply.* = fx.IpcMessage.init(fx.R_OK);
                if (final_state != null and final_state.? == .established) {
                    setReplyLen(reply, @intCast(data.len));
                } else {
                    // Connect failed or timed out
                    setReplyLen(reply, 0);
                }
            }
        },
        .tcp_data => {
            const sent = tcp_stack.sendData(h.conn, data);
            flushDeferredTx();
            reply.* = fx.IpcMessage.init(fx.R_OK);
            setReplyLen(reply, sent);
        },
        .tcp_global_ctl => {
            net_lock.lock();
            const n = handleTcpGlobalCtlWrite(data);
            net_lock.unlock();
            reply.* = fx.IpcMessage.init(fx.R_OK);
            setReplyLen(reply, n);
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
            const n = handleIcmpCtlWrite(@intCast(h.conn), data);
            net_lock.unlock();
            reply.* = fx.IpcMessage.init(fx.R_OK);
            setReplyLen(reply, n);
        },
        .icmp_data => {
            const icmp_wr_idx: u8 = @intCast(h.conn);
            net_lock.lock();
            if (icmp_handler.sendEchoRequest(icmp_wr_idx, our_ip)) {
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
            // Write commands: "add IP mask GW", "dhcp", "dns IP"
            var cmd_len: usize = data.len;
            while (cmd_len > 0 and (data[cmd_len - 1] == '\n' or data[cmd_len - 1] == ' ')) {
                cmd_len -= 1;
            }
            if (cmd_len == 4 and data[0] == 'd' and data[1] == 'h' and data[2] == 'c' and data[3] == 'p') {
                net_lock.lock();
                dhcpStart();
                net_lock.unlock();
                // Poll for DHCP to complete (up to 10s)
                var iters: u32 = 0;
                while (iters < 1000) : (iters += 1) {
                    net_lock.lock();
                    const st = dhcp_state;
                    net_lock.unlock();
                    if (st == .bound or st == .idle) break;
                    fx.sleep(POLL_SLEEP_MS);
                }
                reply.* = fx.IpcMessage.init(fx.R_OK);
                setReplyLen(reply, @intCast(data.len));
                return;
            } else if (cmd_len > 4 and data[0] == 'd' and data[1] == 'n' and data[2] == 's' and data[3] == ' ') {
                if (parseIp(data[4..cmd_len])) |dns_ip| {
                    net_lock.lock();
                    nameserver_ip = dns_ip;
                    dns_resolver.setNameserver(nameserver_ip);
                    net_lock.unlock();
                    reply.* = fx.IpcMessage.init(fx.R_OK);
                    setReplyLen(reply, @intCast(data.len));
                    return;
                }
                reply.* = fx.IpcMessage.init(fx.R_ERROR);
                return;
            } else if (cmd_len > 4 and data[0] == 'a' and data[1] == 'd' and data[2] == 'd' and data[3] == ' ') {
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
                                net_lock.lock();
                                our_ip = ip;
                                subnet_mask = mask;
                                gateway_ip = gw;
                                net_lock.unlock();
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

    net_lock.lock();

    const h = getHandle(handle_id) orelse {
        net_lock.unlock();
        reply.* = fx.IpcMessage.init(fx.R_OK);
        return;
    };

    switch (h.kind) {
        .tcp_data, .tcp_stream => tcp_stack.startClose(h.conn),
        .icmp_data => icmp_handler.close(@intCast(h.conn)),
        else => {},
    }

    freeHandle(handle_id);
    net_lock.unlock();
    flushDeferredTx();

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

fn handleCtlWrite(conn: u16, data: []const u8) ?u16 {
    const trimmed = trimNewline(data);

    if (startsWith(trimmed, "connect ")) {
        const args = trimmed[8..];
        const parsed = parseAddr(args) orelse return 0;
        // Send gratuitous ARP before TCP connect to ensure the gateway
        // (QEMU SLIRP) has a fresh ARP entry for our IP. Without this,
        // SLIRP may drop SYN-ACKs while waiting for ARP resolution.
        sendGratuitousArp();
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

    if (startsWith(trimmed, "stream ")) {
        const id_str = trimmed[7..];
        const shmem_id = parseDec(id_str) orelse return 0;
        const ptr = fx.shmemMap(@intCast(shmem_id)) orelse return 0;
        // Find the data handle for this connection and upgrade it
        for (&handles) |*h| {
            if (h.active and h.kind == .tcp_data and h.conn == conn) {
                h.kind = .tcp_stream;
                h.shmem_id = @intCast(shmem_id);
                h.ring_ptr = ptr;
                return @intCast(data.len);
            }
        }
        return 0;
    }

    return 0;
}

fn handleDnsWrite(data: []const u8) ?u16 {
    const trimmed = trimNewline(data);

    if (startsWith(trimmed, "query ")) {
        const name = trimmed[6..];
        if (name.len == 0) return 0;

        if (dns_resolver.cacheLookup(name)) |ip| {
            // Cache hit — store result so subsequent read returns correct IP
            dns_resolver.pending_result = ip;
            return @intCast(data.len);
        }

        _ = dns_resolver.query(name);
        return null; // Block until response arrives
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

fn handleTcpGlobalCtlWrite(data: []const u8) u16 {
    const trimmed = trimNewline(data);

    if (startsWith(trimmed, "maxconn ")) {
        const val = parseDec(trimmed[8..]) orelse return 0;
        if (val == 0 or val > net.tcp.MAX_CONNECTIONS) return 0;
        tcp_stack.setMaxConnections(@intCast(val));
        return @intCast(data.len);
    }

    if (startsWith(trimmed, "rmem ")) {
        const val = parseDec(trimmed[5..]) orelse return 0;
        if (val < 1024 or val > 16 * 1024 * 1024) return 0;
        tcp_stack.rx_buf_size = val;
        return @intCast(data.len);
    }

    if (startsWith(trimmed, "wmem ")) {
        const val = parseDec(trimmed[5..]) orelse return 0;
        if (val < 1024 or val > 16 * 1024 * 1024) return 0;
        tcp_stack.tx_buf_size = val;
        return @intCast(data.len);
    }

    if (startsWith(trimmed, "maxretries ")) {
        const val = parseDec(trimmed[11..]) orelse return 0;
        if (val > 255) return 0;
        tcp_stack.max_retries = @intCast(val);
        return @intCast(data.len);
    }

    if (startsWith(trimmed, "fin_timeout ")) {
        const val = parseDec(trimmed[12..]) orelse return 0;
        tcp_stack.time_wait_ticks = val;
        return @intCast(data.len);
    }

    if (startsWith(trimmed, "portrange ")) {
        // Parse "portrange LOW HIGH"
        const args = trimmed[10..];
        var space_pos: ?usize = null;
        for (args, 0..) |ch, ai| {
            if (ch == ' ') {
                space_pos = ai;
                break;
            }
        }
        const sp = space_pos orelse return 0;
        const lo = parseDec(args[0..sp]) orelse return 0;
        const hi = parseDec(args[sp + 1 ..]) orelse return 0;
        if (lo >= hi or lo > 65535 or hi > 65535) return 0;
        tcp_stack.port_lo = @intCast(lo);
        tcp_stack.port_hi = @intCast(hi);
        if (tcp_stack.next_ephemeral_port < tcp_stack.port_lo or
            tcp_stack.next_ephemeral_port > tcp_stack.port_hi)
        {
            tcp_stack.next_ephemeral_port = tcp_stack.port_lo;
        }
        return @intCast(data.len);
    }

    if (startsWith(trimmed, "keepalive ")) {
        const val = parseDec(trimmed[10..]) orelse return 0;
        tcp_stack.keepalive_ticks = val;
        return @intCast(data.len);
    }

    if (startsWith(trimmed, "tw_reuse ")) {
        const val = parseDec(trimmed[9..]) orelse return 0;
        tcp_stack.tw_reuse = val != 0;
        return @intCast(data.len);
    }

    if (startsWith(trimmed, "rto ")) {
        const val = parseDec(trimmed[4..]) orelse return 0;
        if (val == 0 or val > 600000) return 0;
        tcp_stack.initial_rto = val;
        return @intCast(data.len);
    }

    if (startsWith(trimmed, "mss ")) {
        const val = parseDec(trimmed[4..]) orelse return 0;
        if (val < 536 or val > 9000) return 0;
        tcp_stack.default_mss = @intCast(val);
        return @intCast(data.len);
    }

    if (startsWith(trimmed, "cwndmax ")) {
        const val = parseDec(trimmed[8..]) orelse return 0;
        tcp_stack.cwnd_max = val;
        return @intCast(data.len);
    }

    if (startsWith(trimmed, "nodelay ")) {
        const val = parseDec(trimmed[8..]) orelse return 0;
        tcp_stack.nodelay = val != 0;
        return @intCast(data.len);
    }

    if (startsWith(trimmed, "window ")) {
        const val = parseDec(trimmed[7..]) orelse return 0;
        if (val < 1024 or val > 65535) return 0;
        tcp_stack.default_window = @intCast(val);
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

// BSS buffers for rxLoop — avoids LLVM aarch64 stack-slot reuse bug
// (frame_buf + icmp reply_buf are both 1600 bytes; see docs/aarch64-gotchas.md §5).
var rx_frame_buf: [1600]u8 = undefined;
var rx_arp_reply_buf: [64]u8 = undefined;
var rx_icmp_reply_buf: [1600]u8 = undefined;

fn rxLoop() noreturn {
    while (true) {
        const n = fx.read(ETHER_FD, &rx_frame_buf);
        if (n <= 0) {
            fx.sleep(1);
            continue;
        }

        const frame = rx_frame_buf[0..@intCast(n)];
        const eth = net.ethernet.parse(frame) orelse continue;

        if (eth.header.ethertype == net.ethernet.ETHER_ARP) {
            net_lock.lock();
            const reply_len = arp_table.handlePacket(eth.payload, our_mac, our_ip, &rx_arp_reply_buf);
            // ARP table may have been updated — drain pending packets
            drainArpPending();
            net_lock.unlock();
            if (reply_len) |rl| {
                _ = fx.write(ETHER_FD, rx_arp_reply_buf[0..rl]);
            }
            flushDeferredTx();
            continue;
        } else if (eth.header.ethertype == net.ethernet.ETHER_IPV4) {
            if (net.ipv4.parse(eth.payload)) |ip_result| {
                const ip_hdr = ip_result.header;
                const ip_payload = ip_result.payload;

                // Ignore packets not addressed to us (avoids container netd
                // sending RSTs for the host's TCP traffic).
                if (!net.ipv4.ipEqual(ip_hdr.dst, our_ip) and
                    ip_hdr.dst[0] != 255) // allow broadcast
                {
                    continue;
                }

                if (ip_hdr.protocol == net.ipv4.PROTO_TCP) {
                    // Ignore TCP for kernel ephemeral ports (32768-39999) and
                    // bridge NAT ports (40000-49151) to avoid sending RSTs
                    // for traffic handled by the kernel TCP stack or bridge.
                    if (ip_payload.len >= 4) {
                        const dst_port = @as(u16, ip_payload[2]) << 8 | ip_payload[3];
                        if (dst_port >= 32768 and dst_port < 49152) {
                            continue;
                        }
                    }
                    // TCP stack has per-connection locking — no net_lock needed
                    tcp_stack.handlePacket(ip_payload, ip_hdr);
                } else if (ip_hdr.protocol == net.ipv4.PROTO_ICMP) {
                    net_lock.lock();
                    if (icmp_handler.handlePacket(ip_payload, ip_hdr, our_ip, &rx_icmp_reply_buf)) |reply_len| {
                        net_lock.unlock();
                        flushDeferredTx();
                        sendIpPacket(ip_hdr.src, rx_icmp_reply_buf[0..reply_len]);
                        continue;
                    }
                    net_lock.unlock();
                } else if (ip_hdr.protocol == net.ipv4.PROTO_UDP) {
                    net_lock.lock();
                    if (ip_payload.len >= 8) {
                        const src_port = @as(u16, ip_payload[0]) << 8 | ip_payload[1];
                        const dst_port = @as(u16, ip_payload[2]) << 8 | ip_payload[3];

                        if (dst_port == net.dhcp.CLIENT_PORT and src_port == net.dhcp.SERVER_PORT and ip_payload.len > 8) {
                            // DHCP reply (server port 67 → client port 68)
                            dhcpHandleReply(ip_payload[8..]);
                        } else if (src_port == 53 and ip_payload.len > 8) {
                            // DNS response
                            _ = dns_resolver.handleResponse(ip_payload[8..]);
                        }
                    }
                    net_lock.unlock();
                }
            }
        }

        flushDeferredTx();
    }
}

// ── Timer thread ──────────────────────────────────────────────────

fn timerThreadEntry(_: *anyopaque) callconv(.c) void {
    timerLoop();
}

var arp_refresh_counter: u16 = 0;

fn timerLoop() noreturn {
    var stream_drain_buf: [8192]u8 = undefined;

    while (true) {
        fx.sleep(TICK_MS);

        // TCP tick — internally locked per-connection, no net_lock needed
        const now = getTicks();
        tcp_stack.tick(now);

        net_lock.lock();

        // DNS retry
        _ = dns_resolver.checkRetry();

        // ICMP timeouts
        var timeout_buf: [4]u8 = undefined;
        _ = icmp_handler.checkTimeouts(&timeout_buf);

        // DHCP retry
        dhcpTimerTick();

        // Periodic gratuitous ARP (~30s) to keep gateway ARP cache warm.
        arp_refresh_counter += 1;
        if (arp_refresh_counter >= 30000 / TICK_MS) {
            arp_refresh_counter = 0;
            sendGratuitousArp();
        }

        net_lock.unlock();

        // Drain shared memory ring buffers for tcp_stream handles
        for (&handles) |*h| {
            if (h.active and h.kind == .tcp_stream) {
                if (h.ring_ptr) |ptr| {
                    // Only drain if the TCP connection is still established
                    const state = tcp_stack.getState(h.conn);
                    if (state == null or state.? != .established) continue;

                    var ring = fx.ring.Ring.initConsumer(ptr);
                    // Drain multiple chunks per tick
                    var drain_iters: u32 = 0;
                    while (drain_iters < 16) : (drain_iters += 1) {
                        const n = ring.read(&stream_drain_buf);
                        if (n == 0) break;
                        _ = tcp_stack.sendData(h.conn, stream_drain_buf[0..n]);
                    }
                }
            }
        }

        flushDeferredTx();
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

    // Auto-detect MAC and container IP from kernel via sysinfo
    if (fx.sysinfo()) |info| {
        const m = info.ether_mac;
        our_mac[0] = @truncate(m);
        our_mac[1] = @truncate(m >> 8);
        our_mac[2] = @truncate(m >> 16);
        our_mac[3] = @truncate(m >> 24);
        our_mac[4] = @truncate(m >> 32);
        our_mac[5] = @truncate(m >> 40);

        // Container netd: use assigned IP instead of host default
        if (info.net_ip != 0) {
            const ip: u32 = @truncate(info.net_ip);
            our_ip[0] = @truncate(ip);
            our_ip[1] = @truncate(ip >> 8);
            our_ip[2] = @truncate(ip >> 16);
            our_ip[3] = @truncate(ip >> 24);
        }
    }

    // Initialize network stack
    tcp_stack.initInPlace(&sendTcpIpPacket, &getOurIp, &getTicks);
    tcp_stack.setWaiterCallback(&tcpWaiterCallback);
    tcp_stack.allocBufFn = &tcpAllocBuf;
    tcp_stack.freeBufFn = &tcpFreeBuf;
    tcp_stack.setMaxConnections(4096);
    tcp_stack.frameSendFn = &sendTcpFrame;

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

    // Claim exclusive access so the kernel stack doesn't process (and RST)
    // TCP segments that belong to our userspace TCP stack.
    _ = fx.write(ETHER_FD, "exclusive\n");

    // Probe hardware offload capabilities
    if (fx.write(ETHER_FD, "csum_offload") > 0) {
        tcp_stack.csum_offload = true;
        _ = fx.write(1, "netd: checksum offload enabled\n");
    }
    // TSO disabled: QEMU's virtio-net TSO segmentation over TAP+bridge
    // drops frames silently — fall back to MSS-sized segments via sendBatch
    // which shares the proven CSUM-offload path with SYN/ACK packets.
    // TODO: investigate virtio-net TSO descriptor format vs QEMU expectations
    // if (fx.write(ETHER_FD, "tso_offload") > 0) {
    //     tcp_stack.tso_enabled = true;
    //     tcp_stack.tso_max_size = 4032;
    //     _ = fx.write(1, "netd: TSO offload enabled\n");
    // }

    // Read /etc/net.conf for network configuration
    var use_dhcp = false;
    var conf_found = false;
    {
        const conf_fd = fx.open("/etc/net.conf");
        if (conf_fd >= 0) {
            var conf_buf: [256]u8 = undefined;
            const conf_n = fx.read(conf_fd, &conf_buf);
            _ = fx.close(conf_fd);
            if (conf_n > 0) {
                conf_found = true;
                applyNetConf(conf_buf[0..@intCast(conf_n)], &use_dhcp);
            }
        }
    }

    if (!conf_found) {
        _ = fx.write(1, "netd: no /etc/net.conf, using defaults\n");
    }

    // Spawn RX thread (needed for DHCP to receive replies)
    _ = fx.thread.spawnThread(rxThreadEntry, null) catch {};

    // Spawn timer thread (needed for DHCP retry)
    _ = fx.thread.spawnThread(timerThreadEntry, null) catch {};

    // Start DHCP non-blocking — the state machine runs via RX/timer
    // threads. IPC workers must be live so the rest of the system can
    // query /net/status while DHCP is still negotiating.
    if (use_dhcp) {
        net_lock.lock();
        dhcpStart();
        net_lock.unlock();
    } else {
        // Static config — send gratuitous ARP immediately
        var arp_buf: [64]u8 = undefined;
        if (net.arp.ArpTable.buildRequest(&arp_buf, our_mac, our_ip, gateway_ip)) |arp_len| {
            _ = fx.write(ETHER_FD, arp_buf[0..arp_len]);
        }
    }

    // Spawn worker threads
    var i: usize = 0;
    while (i < NUM_WORKERS) : (i += 1) {
        _ = fx.thread.spawnThread(workerEntry, null) catch {};
    }

    // Main thread enters IPC worker loop
    workerLoop();
}

// ── Path parsing ──────────────────────────────────────────────────

const ConnPathResult = struct { kind: HandleKind, conn: u16 };

fn parseTcpConnPath(path: []const u8) ?ConnPathResult {
    var i: usize = 0;
    while (i < path.len and path[i] >= '0' and path[i] <= '9') : (i += 1) {}
    if (i == 0) return null;

    const conn_num = parseDec(path[0..i]) orelse return null;
    if (conn_num >= net.tcp.MAX_CONNECTIONS) return null;

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

fn setReplyLen(reply: *fx.IpcMessage, len: u32) void {
    // Write len as LE u32 in first 4 bytes of reply data
    reply.data[0] = @truncate(len);
    reply.data[1] = @truncate(len >> 8);
    reply.data[2] = @truncate(len >> 16);
    reply.data[3] = @truncate(len >> 24);
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

/// Parse /etc/net.conf content line by line.
/// Supports: "dhcp", "add IP MASK GW", "dns IP", and "#" comments.
fn applyNetConf(data: []const u8, use_dhcp: *bool) void {
    var pos: usize = 0;
    while (pos < data.len) {
        // Find end of line
        var eol = pos;
        while (eol < data.len and data[eol] != '\n') : (eol += 1) {}
        const raw_line = data[pos..eol];
        pos = if (eol < data.len) eol + 1 else eol;

        // Trim whitespace and CR
        var line = raw_line;
        while (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) {
            line = line[1..];
        }
        while (line.len > 0 and (line[line.len - 1] == '\r' or line[line.len - 1] == ' ' or line[line.len - 1] == '\t')) {
            line = line[0 .. line.len - 1];
        }

        // Skip empty lines and comments
        if (line.len == 0 or line[0] == '#') continue;

        if (eql(line, "dhcp")) {
            use_dhcp.* = true;
        } else if (startsWith(line, "add ")) {
            applyAddCmd(line[4..]);
        } else if (startsWith(line, "dns ")) {
            if (parseIp(line[4..])) |dns_ip| {
                nameserver_ip = dns_ip;
            }
        } else if (startsWith(line, "rmem ") or
            startsWith(line, "wmem ") or
            startsWith(line, "mss ") or
            startsWith(line, "rto ") or
            startsWith(line, "nodelay ") or
            startsWith(line, "window "))
        {
            // Forward TCP tuning commands to the same handler as tcp/ctl writes
            _ = handleTcpGlobalCtlWrite(line);
        }
    }
}

/// Apply "add IP MASK GW" command from config.
fn applyAddCmd(args: []const u8) void {
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
                }
            }
        }
    }
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
