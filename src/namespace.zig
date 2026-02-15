/// Per-process namespace — Plan 9's killer feature.
///
/// Each process has its own view of the filesystem tree.
/// The namespace is a list of mount entries, sorted by path length (longest first)
/// for longest-prefix matching.
///
/// Mount flags support union directories (Plan 9 style):
///   REPLACE — new mount replaces the old entry
///   BEFORE  — new mount searched first in union
///   AFTER   — new mount searched after existing
const console = @import("console.zig");
const ipc = @import("ipc.zig");
const heap = @import("heap.zig");

const MAX_MOUNTS = 32;
const MAX_PATH = 256;

pub const MountFlags = packed struct {
    replace: bool = false,
    before: bool = false,
    after: bool = false,
    _padding: u5 = 0,
};

pub const MountEntry = struct {
    /// Mount point path (e.g., "/dev/console").
    path: [MAX_PATH]u8,
    path_len: u16,
    /// IPC channel to the file server.
    channel_id: ipc.ChannelId,
    /// Mount flags.
    flags: MountFlags,
    /// Whether this entry is active.
    active: bool,
};

pub const Namespace = struct {
    mounts: [MAX_MOUNTS]MountEntry,
    count: u16,

    pub fn init() Namespace {
        var ns = Namespace{
            .mounts = undefined,
            .count = 0,
        };
        for (&ns.mounts) |*m| {
            m.active = false;
            m.path_len = 0;
            m.channel_id = 0;
            m.flags = .{};
        }
        return ns;
    }

    /// Mount a file server channel at the given path.
    pub fn mount(self: *Namespace, path: []const u8, channel_id: ipc.ChannelId, flags: MountFlags) !void {
        if (path.len > MAX_PATH) return error.PathTooLong;

        // If REPLACE, remove existing mount at this exact path
        if (flags.replace) {
            for (&self.mounts) |*m| {
                if (m.active and pathEqual(m.path[0..m.path_len], path)) {
                    m.active = false;
                    self.count -= 1;
                    break;
                }
            }
        }

        // Find a free slot
        for (&self.mounts) |*m| {
            if (!m.active) {
                @memcpy(m.path[0..path.len], path);
                m.path_len = @intCast(path.len);
                m.channel_id = channel_id;
                m.flags = flags;
                m.active = true;
                self.count += 1;
                return;
            }
        }
        return error.TooManyMounts;
    }

    /// Unmount the file server at the given path.
    pub fn unmount(self: *Namespace, path: []const u8) void {
        for (&self.mounts) |*m| {
            if (m.active and pathEqual(m.path[0..m.path_len], path)) {
                m.active = false;
                self.count -= 1;
                return;
            }
        }
    }

    /// Look up the longest-prefix matching mount for a path.
    /// Returns the channel ID of the file server and the remaining path suffix.
    pub fn resolve(self: *const Namespace, path: []const u8) ?struct { channel_id: ipc.ChannelId, suffix: []const u8 } {
        var best_len: u16 = 0;
        var best_channel: ?ipc.ChannelId = null;

        for (&self.mounts) |*m| {
            if (!m.active) continue;
            const mount_path = m.path[0..m.path_len];
            if (isPrefix(mount_path, path) and m.path_len >= best_len) {
                best_len = m.path_len;
                best_channel = m.channel_id;
            }
        }

        if (best_channel) |ch| {
            return .{
                .channel_id = ch,
                .suffix = if (best_len < path.len) path[best_len..] else "",
            };
        }
        return null;
    }

    /// Clone this namespace (for rfork with RFNAMEG).
    pub fn clone(self: *const Namespace) Namespace {
        var new_ns = Namespace.init();
        for (0..MAX_MOUNTS) |i| {
            new_ns.mounts[i] = self.mounts[i];
        }
        new_ns.count = self.count;
        return new_ns;
    }

    /// Copy this namespace into a destination pointer (no stack temporaries).
    /// Use this instead of clone() when stack space is limited (e.g., kernel stacks).
    pub fn cloneInto(self: *const Namespace, dest: *Namespace) void {
        for (0..MAX_MOUNTS) |i| {
            dest.mounts[i] = self.mounts[i];
        }
        dest.count = self.count;
    }
};

fn pathEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn isPrefix(prefix: []const u8, path: []const u8) bool {
    if (prefix.len > path.len) return false;
    for (prefix, path[0..prefix.len]) |a, b| {
        if (a != b) return false;
    }
    // The prefix must end at a path boundary
    if (prefix.len == path.len) return true;
    if (prefix.len == 0) return true;
    // "/" is a prefix of everything starting with "/"
    if (prefix[prefix.len - 1] == '/') return true;
    return path[prefix.len] == '/';
}

/// The root namespace — template for all processes.
var root_namespace: Namespace = Namespace.init();

pub fn getRootNamespace() *Namespace {
    return &root_namespace;
}
