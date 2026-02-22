/// Raw Ethernet frame interface for userspace network servers.
///
/// Provides `/dev/ether0` — processes can open, read, and write raw
/// Ethernet frames. Each client gets a ring buffer of received frames.
///
/// Modes:
///   shared (default) — frames delivered to both kernel stack and ether clients
///   exclusive — frames delivered only to ether clients (kernel stack skipped)
const SpinLock = @import("spinlock.zig").SpinLock;
const process = @import("process.zig");

pub const MAX_ETHER_CLIENTS = 8;
const FRAME_RING_SIZE = 64;
pub const MAX_FRAME = 1518;

const MAX_WAITERS = 4;

pub const EtherClient = struct {
    active: bool,
    exclusive: bool, // true = kernel stack skips frame processing
    ring: [FRAME_RING_SIZE][MAX_FRAME]u8,
    frame_lens: [FRAME_RING_SIZE]u16,
    head: u8, // next write position
    count: u8, // frames in ring
    read_waiters: [MAX_WAITERS]?u16,
    lock: SpinLock,
};

var clients: [MAX_ETHER_CLIENTS]EtherClient linksection(".bss") = undefined;

pub fn init() void {
    for (&clients) |*c| {
        resetClient(c);
    }
}

fn resetClient(c: *EtherClient) void {
    c.active = false;
    c.exclusive = false;
    // ring/frame_lens left undefined (BSS)
    c.head = 0;
    c.count = 0;
    c.read_waiters = [_]?u16{null} ** MAX_WAITERS;
    c.lock = .{};
}

/// Allocate a new ether client slot. Returns client index or null.
pub fn allocClient() ?u8 {
    for (&clients, 0..) |*c, i| {
        c.lock.lock();
        if (!c.active) {
            resetClient(c);
            c.active = true;
            c.lock.unlock();
            return @intCast(i);
        }
        c.lock.unlock();
    }
    return null;
}

/// Free a client slot.
pub fn freeClient(idx: u8) void {
    if (idx >= MAX_ETHER_CLIENTS) return;
    const c = &clients[idx];
    c.lock.lock();
    c.active = false;
    // Wake any blocked readers with EOF
    for (&c.read_waiters) |*w| {
        if (w.*) |pid| {
            w.* = null;
            if (process.getByPid(pid)) |proc| {
                if (proc.state == .blocked) {
                    proc.syscall_ret = 0; // EOF
                    process.markReady(proc);
                }
            }
        }
    }
    c.lock.unlock();
}

/// Deliver a frame to all active ether clients. Called from net.handleFrame.
/// Returns true if any exclusive client consumed the frame (kernel should skip).
pub fn deliverFrame(frame: []const u8) bool {
    if (frame.len > MAX_FRAME or frame.len == 0) return false;
    var any_exclusive = false;

    for (&clients) |*c| {
        if (!@atomicLoad(bool, &c.active, .acquire)) continue;

        c.lock.lock();
        if (!c.active) {
            c.lock.unlock();
            continue;
        }

        if (c.exclusive) any_exclusive = true;

        // Enqueue frame into ring buffer
        if (c.count < FRAME_RING_SIZE) {
            const slot = c.head;
            @memcpy(c.ring[slot][0..frame.len], frame);
            c.frame_lens[slot] = @intCast(frame.len);
            c.head = (c.head + 1) % FRAME_RING_SIZE;
            c.count += 1;

            // Wake blocked readers
            for (&c.read_waiters) |*w| {
                if (w.*) |pid| {
                    w.* = null;
                    if (process.getByPid(pid)) |proc| {
                        if (proc.state == .blocked) {
                            process.markReady(proc);
                        }
                    }
                }
            }
        }
        // else: ring full, drop frame (no backpressure)

        c.lock.unlock();
    }

    return any_exclusive;
}

/// Read a frame from the client's ring buffer. Returns frame length or 0 if empty.
pub fn readFrame(idx: u8, dest: []u8) u16 {
    if (idx >= MAX_ETHER_CLIENTS) return 0;
    const c = &clients[idx];
    c.lock.lock();
    defer c.lock.unlock();

    if (c.count == 0) return 0;

    // Dequeue from read position (head - count)
    const read_pos = (c.head -% c.count) % FRAME_RING_SIZE;
    const frame_len = c.frame_lens[read_pos];
    const copy_len: u16 = @intCast(@min(frame_len, dest.len));
    @memcpy(dest[0..copy_len], c.ring[read_pos][0..copy_len]);
    c.count -= 1;

    return copy_len;
}

/// Check if client has frames available.
pub fn hasData(idx: u8) bool {
    if (idx >= MAX_ETHER_CLIENTS) return false;
    const c = &clients[idx];
    c.lock.lock();
    defer c.lock.unlock();
    return c.count > 0;
}

/// Set a read waiter on this client.
pub fn setReadWaiter(idx: u8, pid: u16) void {
    if (idx >= MAX_ETHER_CLIENTS) return;
    const c = &clients[idx];
    c.lock.lock();
    defer c.lock.unlock();
    for (&c.read_waiters) |*w| {
        if (w.* == null) {
            w.* = pid;
            return;
        }
    }
    // Full — overwrite first slot
    c.read_waiters[0] = pid;
}

/// Process ctl commands: "exclusive" or "shared".
pub fn handleCtl(idx: u8, cmd: []const u8) bool {
    if (idx >= MAX_ETHER_CLIENTS) return false;
    const c = &clients[idx];
    c.lock.lock();
    defer c.lock.unlock();

    if (strEql(cmd, "exclusive")) {
        c.exclusive = true;
        return true;
    }
    if (strEql(cmd, "shared")) {
        c.exclusive = false;
        return true;
    }
    return false;
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
