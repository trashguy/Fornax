/// IPC types for Fornax userspace.
///
/// Message structure, tag constants, and directory/stat types
/// shared between clients and servers.

/// IPC message structure for user-space (matches kernel layout).
/// Layout: tag(u32) + data_len(u32) + data([4096]u8) = 4104 bytes.
pub const IpcMessage = extern struct {
    tag: u32,
    data_len: u32,
    data: [4096]u8,

    pub fn init(tag: u32) IpcMessage {
        return .{ .tag = tag, .data_len = 0, .data = undefined };
    }

    pub fn initWithData(tag: u32, payload: []const u8) IpcMessage {
        var msg = IpcMessage.init(tag);
        const len: u32 = @intCast(@min(payload.len, 4096));
        @memcpy(msg.data[0..len], payload[0..len]);
        msg.data_len = len;
        return msg;
    }

    pub fn getData(self: *const IpcMessage) []const u8 {
        return self.data[0..self.data_len];
    }
};

/// IPC message tags (matching kernel ipc.Tag values).
pub const T_OPEN: u32 = 1;
pub const T_READ: u32 = 2;
pub const T_WRITE: u32 = 3;
pub const T_CLOSE: u32 = 4;
pub const T_STAT: u32 = 5;
pub const T_CTL: u32 = 6;
pub const T_CREATE: u32 = 7;
pub const T_REMOVE: u32 = 8;
pub const T_RENAME: u32 = 9;
pub const T_TRUNCATE: u32 = 10;
pub const T_WSTAT: u32 = 11;
pub const R_OK: u32 = 128;
pub const R_ERROR: u32 = 129;

/// Directory entry returned by reading a directory handle.
pub const DirEntry = extern struct {
    name: [64]u8, // null-terminated
    file_type: u32, // 0=file, 1=directory
    size: u32, // file size
};

/// File stat information.
pub const Stat = extern struct {
    size: u32,
    file_type: u32, // 0=file, 1=directory
    mtime: u64, // uptime seconds at last modification
    ctime: u64, // uptime seconds at creation
    mode: u32, // full mode (type + permission bits)
    uid: u16,
    gid: u16,
    _reserved: [32]u8,
};

/// FD mapping for spawn: maps a parent fd to a child fd slot.
pub const FdMapping = extern struct {
    child_fd: u32,
    parent_fd: u32,
};
