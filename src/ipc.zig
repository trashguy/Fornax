/// IPC: Synchronous message passing over channels.
///
/// A channel is a bidirectional message pipe between two endpoints.
/// Based on L4 synchronous IPC + Plan 9's 9P file protocol.
///
/// send() blocks until a receiver calls recv().
/// recv() blocks until a sender calls send().
/// Transfer happens at rendezvous — no kernel buffering.
///
/// SMP: Per-channel spinlock guards endpoint state. Global alloc lock guards
/// channel allocation. Lock ordering: alloc_lock → channel.lock.
const heap = @import("heap.zig");
const klog = @import("klog.zig");
const SpinLock = @import("spinlock.zig").SpinLock;

/// Maximum number of channels system-wide.
const MAX_CHANNELS = 256;

/// Maximum inline message data size.
pub const MAX_MSG_DATA = 4096;

/// Maximum number of clients that can queue on a single channel.
pub const MAX_CLIENT_WAITERS = 16;

/// 9P-inspired message tags.
pub const Tag = enum(u32) {
    t_open = 1,
    t_read = 2,
    t_write = 3,
    t_close = 4,
    t_stat = 5,
    t_ctl = 6,
    t_create = 7,
    t_remove = 8,
    t_rename = 9,
    t_truncate = 10,
    t_wstat = 11,
    r_ok = 128,
    r_error = 129,
};

/// A message passed over a channel.
pub const Message = struct {
    tag: Tag,
    /// Length of valid data in data_buf.
    data_len: u32,
    /// Inline data buffer.
    data_buf: [MAX_MSG_DATA]u8,
    /// Optional: channel ID to pass to the other side (for delegation).
    passed_channel: ?ChannelId,

    pub fn init(tag: Tag) Message {
        return .{
            .tag = tag,
            .data_len = 0,
            .data_buf = undefined,
            .passed_channel = null,
        };
    }

    pub fn initWithData(tag: Tag, payload: []const u8) Message {
        var msg = Message.init(tag);
        const len: u32 = @intCast(@min(payload.len, MAX_MSG_DATA));
        @memcpy(msg.data_buf[0..len], payload[0..len]);
        msg.data_len = len;
        return msg;
    }

    pub fn getData(self: *const Message) []const u8 {
        return self.data_buf[0..self.data_len];
    }
};

pub const ChannelId = u32;

const ChannelState = enum {
    free,
    open,
    closed,
};

/// Maximum number of server threads that can block on recv simultaneously.
pub const MAX_SERVER_WAITERS = 8;

/// A pending client entry in the IPC queue.
pub const PendingClient = struct {
    pid: u32,
    msg_ptr: ?*Message,
};

pub const ChannelEnd = struct {
    /// Process ID of the process that owns this end (0 = unowned).
    owner_pid: u32,
    /// Ring buffer of pending client senders.
    pending: [MAX_CLIENT_WAITERS]PendingClient = [_]PendingClient{.{ .pid = 0, .msg_ptr = null }} ** MAX_CLIENT_WAITERS,
    pending_head: u8 = 0,
    pending_count: u8 = 0,
    /// PID of the client currently being served by the server (set by recv, used by reply).
    serving_pid: u32 = 0,
    /// Whether the server end is waiting to receive.
    recv_waiting: bool = false,
    /// PID of the server process blocked on recv (0 = none). Used for single-server fast path.
    blocked_pid: u32 = 0,
    /// Queue of server PIDs waiting for messages (multi-threaded server support).
    server_waiters: [MAX_SERVER_WAITERS]u16 = [_]u16{0} ** MAX_SERVER_WAITERS,
    server_waiter_count: u8 = 0,

    /// Enqueue a client sender. Returns false if queue is full.
    pub fn enqueue(self: *ChannelEnd, pid: u32, msg_ptr: *Message) bool {
        if (self.pending_count >= MAX_CLIENT_WAITERS) return false;
        const idx = (self.pending_head + self.pending_count) % MAX_CLIENT_WAITERS;
        self.pending[idx] = .{ .pid = pid, .msg_ptr = msg_ptr };
        self.pending_count += 1;
        return true;
    }

    /// Dequeue the next pending client. Returns null if empty.
    pub fn dequeue(self: *ChannelEnd) ?PendingClient {
        if (self.pending_count == 0) return null;
        const entry = self.pending[self.pending_head];
        self.pending_head = (self.pending_head + 1) % MAX_CLIENT_WAITERS;
        self.pending_count -= 1;
        return entry;
    }

    /// Check if there are pending client messages.
    pub fn hasPending(self: *const ChannelEnd) bool {
        return self.pending_count > 0;
    }

    /// Add a server PID to the wait queue. Returns false if full.
    pub fn addServerWaiter(self: *ChannelEnd, pid: u16) bool {
        if (self.server_waiter_count >= MAX_SERVER_WAITERS) return false;
        self.server_waiters[self.server_waiter_count] = pid;
        self.server_waiter_count += 1;
        return true;
    }

    /// Remove and return the first server waiter. Returns null if empty.
    pub fn popServerWaiter(self: *ChannelEnd) ?u16 {
        if (self.server_waiter_count == 0) return null;
        const pid = self.server_waiters[0];
        var i: u8 = 1;
        while (i < self.server_waiter_count) : (i += 1) {
            self.server_waiters[i - 1] = self.server_waiters[i];
        }
        self.server_waiter_count -= 1;
        return pid;
    }
};

const empty_end = ChannelEnd{
    .owner_pid = 0,
};

/// A channel: two endpoints connected together.
pub const Channel = struct {
    state: ChannelState,
    server: ChannelEnd,
    client: ChannelEnd,
    /// Kernel-backed data: if non-null, reads are served directly from this
    /// buffer (no IPC message passing). Used for initrd file server.
    kernel_data: ?[]const u8,
    /// Per-channel spinlock for SMP safety.
    lock: SpinLock = .{},
};

var channels: [MAX_CHANNELS]Channel = [_]Channel{.{
    .state = .free,
    .server = empty_end,
    .client = empty_end,
    .kernel_data = null,
}} ** MAX_CHANNELS;

/// Global lock for channel allocation.
var alloc_lock: SpinLock = .{};

var initialized: bool = false;

pub fn init() void {
    initialized = true;
    klog.info("IPC: initialized (");
    klog.infoDec(MAX_CHANNELS);
    klog.info(" channels)\n");
}

pub const IpcError = error{
    NotInitialized,
    NoFreeChannels,
    InvalidChannel,
    ChannelClosed,
    WouldBlock,
};

/// Create a new channel pair. Returns server and client channel IDs.
pub fn channelCreate() IpcError!struct { server: ChannelId, client: ChannelId } {
    if (!initialized) return error.NotInitialized;

    alloc_lock.lock();
    defer alloc_lock.unlock();

    for (0..MAX_CHANNELS) |i| {
        if (channels[i].state == .free) {
            channels[i] = .{
                .state = .open,
                .server = empty_end,
                .client = empty_end,
                .kernel_data = null,
            };
            const id: ChannelId = @intCast(i);
            return .{ .server = id, .client = id };
        }
    }
    return error.NoFreeChannels;
}

/// Create a kernel-backed channel: reads served directly from data, no server process.
pub fn channelCreateKernelBacked(data: []const u8) IpcError!ChannelId {
    if (!initialized) return error.NotInitialized;

    alloc_lock.lock();
    defer alloc_lock.unlock();

    for (0..MAX_CHANNELS) |i| {
        if (channels[i].state == .free) {
            channels[i] = .{
                .state = .open,
                .server = empty_end,
                .client = empty_end,
                .kernel_data = data,
            };
            return @intCast(i);
        }
    }
    return error.NoFreeChannels;
}

/// Send a message on a channel (from client side).
/// In a full implementation this would block until the server calls recv().
/// For MVP (kernel-only testing), this does a synchronous copy.
pub fn send(chan_id: ChannelId, msg: *Message) IpcError!void {
    if (!initialized) return error.NotInitialized;
    if (chan_id >= MAX_CHANNELS) return error.InvalidChannel;

    const chan = &channels[chan_id];
    chan.lock.lock();
    defer chan.lock.unlock();

    if (chan.state != .open) return error.ChannelClosed;

    // Enqueue message in client ring buffer
    _ = chan.client.enqueue(0, msg);
}

/// Receive a message on a channel (from server side).
/// For MVP, this consumes the pending message from the client.
pub fn recv(chan_id: ChannelId, out_msg: *Message) IpcError!void {
    if (!initialized) return error.NotInitialized;
    if (chan_id >= MAX_CHANNELS) return error.InvalidChannel;

    const chan = &channels[chan_id];
    chan.lock.lock();
    defer chan.lock.unlock();

    if (chan.state != .open) return error.ChannelClosed;

    if (chan.client.dequeue()) |entry| {
        if (entry.msg_ptr) |pending| {
            out_msg.* = pending.*;
        }
    } else {
        return error.WouldBlock;
    }
}

/// Reply to a received message (server → client).
pub fn reply(chan_id: ChannelId, msg: *Message) IpcError!void {
    if (!initialized) return error.NotInitialized;
    if (chan_id >= MAX_CHANNELS) return error.InvalidChannel;

    const chan = &channels[chan_id];
    chan.lock.lock();
    defer chan.lock.unlock();

    if (chan.state != .open) return error.ChannelClosed;

    // Server reply is handled directly in syscall.zig's sysIpcReply
    _ = msg;
}

/// Close a channel.
pub fn channelClose(chan_id: ChannelId) void {
    if (chan_id >= MAX_CHANNELS) return;
    const chan = &channels[chan_id];
    chan.lock.lock();
    defer chan.lock.unlock();
    chan.state = .closed;
}

/// Get a channel by ID (for kernel use).
/// NOTE: The returned pointer is NOT lock-protected. Callers in syscall.zig
/// must handle locking externally if they do complex multi-step operations.
pub fn getChannel(chan_id: ChannelId) ?*Channel {
    if (chan_id >= MAX_CHANNELS) return null;
    if (channels[chan_id].state == .free) return null;
    return &channels[chan_id];
}
