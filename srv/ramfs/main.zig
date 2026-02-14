/// Ramfs — Fornax userspace filesystem server.
///
/// Serves the root filesystem via IPC over fd 3 (server channel).
/// Protocol: handle-based (like 9P fids).
///   T_OPEN(path)           → R_OK(handle) or R_ERROR
///   T_CREATE(flags, path)  → R_OK(handle) or R_ERROR
///   T_READ(handle, off, n) → R_OK(data) or R_ERROR
///   T_WRITE(handle, data)  → R_OK(bytes_written) or R_ERROR
///   T_CLOSE(handle)        → R_OK or R_ERROR
const fx = @import("fornax");

const MAX_NODES = 128;
const MAX_HANDLES = 32;
const MAX_FILE_SIZE = 4096;
const MAX_NAME = 64;
const SERVER_FD = 3;

const NodeType = enum(u32) { file = 0, directory = 1 };

const NONE: u8 = 0xFF;

const Node = struct {
    name: [MAX_NAME]u8,
    name_len: u8,
    node_type: NodeType,
    parent: u8, // index into nodes[]
    first_child: u8, // NONE = no children
    next_sibling: u8, // NONE = no more siblings
    data: [MAX_FILE_SIZE]u8,
    data_len: u32,
    active: bool,
};

const Handle = struct {
    node_idx: u8,
    active: bool,
};

var nodes: [MAX_NODES]Node = undefined;
var node_count: u8 = 0; // next free index
var handles: [MAX_HANDLES]Handle = undefined;

// IPC message buffers — file-scope to avoid stack overflow (each is 4104 bytes).
var msg: fx.IpcMessage = undefined;
var reply: fx.IpcMessage = undefined;

fn initNodes() void {
    // .bss is zero-initialized by ELF loader; we just need to allocate the
    // root node and standard directories. No need to loop over all 128 nodes.
    node_count = 0;

    // Create root directory (node 0)
    _ = createNode("/", .directory, 0) catch return;
    // Create standard directories
    _ = createChildDir("tmp", 0) catch {};
    _ = createChildDir("dev", 0) catch {};
    _ = createChildDir("bin", 0) catch {};
}

fn createNode(name: []const u8, node_type: NodeType, parent: u8) !u8 {
    if (node_count >= MAX_NODES) return error.NoFreeNodes;
    const idx = node_count;
    node_count += 1;
    const n = &nodes[idx];
    n.active = true;
    n.node_type = node_type;
    n.parent = parent;
    n.first_child = NONE;
    n.next_sibling = NONE;
    n.data_len = 0;
    const len: u8 = @intCast(@min(name.len, MAX_NAME));
    @memcpy(n.name[0..len], name[0..len]);
    n.name_len = len;
    return idx;
}

fn createChildDir(name: []const u8, parent_idx: u8) !u8 {
    const idx = try createNode(name, .directory, parent_idx);
    // Link into parent's child list
    linkChild(parent_idx, idx);
    return idx;
}

fn linkChild(parent_idx: u8, child_idx: u8) void {
    const parent = &nodes[parent_idx];
    if (parent.first_child == NONE) {
        parent.first_child = child_idx;
    } else {
        // Append to sibling list
        var sib = parent.first_child;
        while (nodes[sib].next_sibling != NONE) {
            sib = nodes[sib].next_sibling;
        }
        nodes[sib].next_sibling = child_idx;
    }
}

fn allocHandle(node_idx: u8) ?u32 {
    // Handles start at 1 (0 = invalid)
    for (1..MAX_HANDLES) |i| {
        if (!handles[i].active) {
            handles[i] = .{ .node_idx = node_idx, .active = true };
            return @intCast(i);
        }
    }
    return null;
}

fn freeHandle(handle: u32) void {
    if (handle > 0 and handle < MAX_HANDLES) {
        handles[handle].active = false;
    }
}

fn getHandle(handle: u32) ?*Handle {
    if (handle == 0 or handle >= MAX_HANDLES) return null;
    if (!handles[handle].active) return null;
    return &handles[handle];
}

/// Resolve a path relative to root. Paths come without leading slash.
/// e.g. "tmp/hello.txt" → find "tmp" in root children, then "hello.txt" in tmp children.
fn resolvePath(path: []const u8) ?u8 {
    if (path.len == 0) return 0; // root

    var current: u8 = 0; // start at root
    var remaining = path;

    while (remaining.len > 0) {
        // Extract next component
        var comp_end: usize = 0;
        while (comp_end < remaining.len and remaining[comp_end] != '/') {
            comp_end += 1;
        }
        const component = remaining[0..comp_end];
        if (component.len == 0) {
            // Skip empty component (double slash or trailing slash)
            remaining = if (comp_end < remaining.len) remaining[comp_end + 1 ..] else remaining[remaining.len..];
            continue;
        }

        // Find component in current directory's children
        var found: ?u8 = null;
        var child = nodes[current].first_child;
        while (child != NONE) {
            const n = &nodes[child];
            if (n.active and n.name_len == component.len and nameEql(n.name[0..n.name_len], component)) {
                found = child;
                break;
            }
            child = n.next_sibling;
        }

        current = found orelse return null;
        remaining = if (comp_end < remaining.len) remaining[comp_end + 1 ..] else remaining[remaining.len..];
    }

    return current;
}

/// Resolve path, returning the parent directory index and the final name component.
fn resolveParent(path: []const u8) ?struct { parent: u8, name: []const u8 } {
    if (path.len == 0) return null;

    // Find last '/'
    var last_slash: ?usize = null;
    for (path, 0..) |c, i| {
        if (c == '/') last_slash = i;
    }

    if (last_slash) |slash| {
        const dir_path = path[0..slash];
        const name = path[slash + 1 ..];
        if (name.len == 0) return null;
        const parent = resolvePath(dir_path) orelse return null;
        return .{ .parent = parent, .name = name };
    }

    // No slash: parent is root, name is the whole path
    return .{ .parent = 0, .name = path };
}

fn nameEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

fn writeU32LE(buf: *[4]u8, val: u32) void {
    buf[0] = @truncate(val);
    buf[1] = @truncate(val >> 8);
    buf[2] = @truncate(val >> 16);
    buf[3] = @truncate(val >> 24);
}

fn readU32LE(buf: *const [4]u8) u32 {
    return @as(u32, buf[0]) |
        (@as(u32, buf[1]) << 8) |
        (@as(u32, buf[2]) << 16) |
        (@as(u32, buf[3]) << 24);
}

fn handleOpen(req: *fx.IpcMessage, resp: *fx.IpcMessage) void {
    const path = req.data[0..req.data_len];
    const node_idx = resolvePath(path) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    const handle = allocHandle(node_idx) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    resp.* = fx.IpcMessage.init(fx.R_OK);
    writeU32LE(resp.data[0..4], handle);
    resp.data_len = 4;
}

fn handleCreate(req: *fx.IpcMessage, resp: *fx.IpcMessage) void {
    if (req.data_len < 4) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    const flags = readU32LE(req.data[0..4]);
    const path = req.data[4..req.data_len];
    const is_dir = (flags & 1) != 0;

    // Check if file already exists
    if (resolvePath(path)) |existing| {
        // Already exists — just open it
        const handle = allocHandle(existing) orelse {
            resp.* = fx.IpcMessage.init(fx.R_ERROR);
            return;
        };
        resp.* = fx.IpcMessage.init(fx.R_OK);
        writeU32LE(resp.data[0..4], handle);
        resp.data_len = 4;
        return;
    }

    // Resolve parent directory
    const resolved = resolveParent(path) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    // Create the node
    const node_type: NodeType = if (is_dir) .directory else .file;
    const idx = createNode(resolved.name, node_type, resolved.parent) catch {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };
    linkChild(resolved.parent, idx);

    const handle = allocHandle(idx) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    resp.* = fx.IpcMessage.init(fx.R_OK);
    writeU32LE(resp.data[0..4], handle);
    resp.data_len = 4;
}

fn handleRead(req: *fx.IpcMessage, resp: *fx.IpcMessage) void {
    if (req.data_len < 12) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    const handle_id = readU32LE(req.data[0..4]);
    const offset = readU32LE(req.data[4..8]);
    const count = readU32LE(req.data[8..12]);

    const h = getHandle(handle_id) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    const node = &nodes[h.node_idx];
    if (!node.active) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    if (node.node_type == .directory) {
        readDirectory(node, offset, count, resp);
        return;
    }

    // Read file data
    resp.* = fx.IpcMessage.init(fx.R_OK);
    if (offset >= node.data_len) {
        resp.data_len = 0; // EOF
        return;
    }

    const available = node.data_len - offset;
    const to_copy = @min(@min(count, available), 4096);
    @memcpy(resp.data[0..to_copy], node.data[offset..][0..to_copy]);
    resp.data_len = to_copy;
}

fn readDirectory(node: *Node, offset: u32, count: u32, resp: *fx.IpcMessage) void {
    resp.* = fx.IpcMessage.init(fx.R_OK);

    const entry_size = @sizeOf(fx.DirEntry); // 72 bytes
    const max_entries = @min(count / entry_size, 4096 / entry_size);

    // Walk children, skip `offset / entry_size` entries
    const skip = offset / entry_size;
    var child = node.first_child;
    var skipped: u32 = 0;
    while (child != NONE and skipped < skip) {
        if (nodes[child].active) skipped += 1;
        child = nodes[child].next_sibling;
    }

    var written: u32 = 0;
    var entries_written: u32 = 0;
    while (child != NONE and entries_written < max_entries) {
        const n = &nodes[child];
        if (n.active) {
            const dest: *fx.DirEntry = @ptrCast(@alignCast(resp.data[written..][0..entry_size]));
            @memset(&dest.name, 0);
            @memcpy(dest.name[0..n.name_len], n.name[0..n.name_len]);
            dest.file_type = @intFromEnum(n.node_type);
            dest.size = n.data_len;
            written += entry_size;
            entries_written += 1;
        }
        child = n.next_sibling;
    }

    resp.data_len = written;
}

fn handleWrite(req: *fx.IpcMessage, resp: *fx.IpcMessage) void {
    if (req.data_len < 4) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    const handle_id = readU32LE(req.data[0..4]);
    const write_data = req.data[4..req.data_len];

    const h = getHandle(handle_id) orelse {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    };

    const node = &nodes[h.node_idx];
    if (!node.active or node.node_type != .file) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }

    // Append or overwrite from current data_len
    const space = MAX_FILE_SIZE - node.data_len;
    const to_write: u32 = @intCast(@min(write_data.len, space));
    @memcpy(node.data[node.data_len..][0..to_write], write_data[0..to_write]);
    node.data_len += to_write;

    resp.* = fx.IpcMessage.init(fx.R_OK);
    writeU32LE(resp.data[0..4], to_write);
    resp.data_len = 4;
}

fn handleClose(req: *fx.IpcMessage, resp: *fx.IpcMessage) void {
    if (req.data_len < 4) {
        resp.* = fx.IpcMessage.init(fx.R_ERROR);
        return;
    }
    const handle_id = readU32LE(req.data[0..4]);
    freeHandle(handle_id);
    resp.* = fx.IpcMessage.init(fx.R_OK);
    resp.data_len = 0;
}

export fn _start() noreturn {
    _ = fx.write(1, "ramfs: starting\n");

    initNodes();

    _ = fx.write(1, "ramfs: ready\n");

    // Server loop: receive messages on fd 3, dispatch, reply

    while (true) {
        const rc = fx.ipc_recv(SERVER_FD, &msg);
        if (rc < 0) {
            _ = fx.write(2, "ramfs: ipc_recv error\n");
            continue;
        }

        switch (msg.tag) {
            fx.T_OPEN => handleOpen(&msg, &reply),
            fx.T_CREATE => handleCreate(&msg, &reply),
            fx.T_READ => handleRead(&msg, &reply),
            fx.T_WRITE => handleWrite(&msg, &reply),
            fx.T_CLOSE => handleClose(&msg, &reply),
            else => {
                reply = fx.IpcMessage.init(fx.R_ERROR);
            },
        }

        _ = fx.ipc_reply(SERVER_FD, &reply);
    }
}
