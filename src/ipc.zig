/// IPC: Synchronous message passing over channels.
///
/// A channel is a bidirectional message pipe between two endpoints.
/// Based on L4 synchronous IPC + Plan 9's 9P file protocol.
///
/// send() blocks until a receiver calls recv().
/// recv() blocks until a sender calls send().
/// Transfer happens at rendezvous — no kernel buffering.
const console = @import("console.zig");
const heap = @import("heap.zig");

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
};

var channels: [MAX_CHANNELS]Channel = [_]Channel{.{
    .state = .free,
    .server = empty_end,
    .client = empty_end,
}} ** MAX_CHANNELS;

var initialized: bool = false;

pub fn init() void {
    initialized = true;
    console.puts("IPC: initialized (");
    console.putDec(MAX_CHANNELS);
    console.puts(" channels)\n");
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

    for (0..MAX_CHANNELS) |i| {
        if (channels[i].state == .free) {
            channels[i] = .{
                .state = .open,
                .server = empty_end,
                .client = empty_end,
            };
            const id: ChannelId = @intCast(i);
            return .{ .server = id, .client = id };
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
    if (chan.state != .open) return error.ChannelClosed;

    chan.server.pending_msg = msg;
}

/// Close a channel.
pub fn channelClose(chan_id: ChannelId) void {
    if (chan_id >= MAX_CHANNELS) return;
    channels[chan_id].state = .closed;
}

/// Get a channel by ID (for kernel use).
pub fn getChannel(chan_id: ChannelId) ?*Channel {
    if (chan_id >= MAX_CHANNELS) return null;
    if (channels[chan_id].state == .free) return null;
    return &channels[chan_id];
}
