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

/// A channel endpoint.
pub const ChannelEnd = struct {
    /// Process ID of the process that owns this end (0 = unowned).
    owner_pid: u32,
    /// Pending message (set by sender, consumed by receiver at rendezvous).
    pending_msg: ?*Message,
    /// Whether this end is waiting to send.
    send_waiting: bool,
    /// Whether this end is waiting to receive.
    recv_waiting: bool,
    /// PID of the process currently blocked on this end (0 = none).
    blocked_pid: u32,
};

const empty_end = ChannelEnd{
    .owner_pid = 0,
    .pending_msg = null,
    .send_waiting = false,
    .recv_waiting = false,
    .blocked_pid = 0,
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

    // Synchronous rendezvous: store message for receiver
    chan.client.pending_msg = msg;
    chan.client.send_waiting = true;
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

    if (chan.client.pending_msg) |pending| {
        out_msg.* = pending.*;
        chan.client.pending_msg = null;
        chan.client.send_waiting = false;
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

    chan.server.pending_msg = msg;
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
