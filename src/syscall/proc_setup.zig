/// proc_setup(op, target_pid, arg0, arg1, arg2) -> result
///
/// Multi-operation syscall for configuring a blocked (not-yet-runnable) process
/// from userspace.  Used by cntrd to set up namespace, fds, compat mode, quotas,
/// argv, and group membership before making the process runnable.
///
/// All ops require uid=0.  The target process must be in .blocked state
/// (spawned with the blocked flag, see sysSpawn).
///
/// Ops that don't target a specific process (ALLOCGROUP, GROUPKILL) ignore
/// target_pid or use it as the group id.
const process = @import("../process.zig");
const namespace = @import("../namespace.zig");
const ipc = @import("../ipc.zig");
const klog = @import("../klog.zig");
const process_group = @import("../process_group.zig");
const root = @import("root.zig");
const proc_handlers = @import("proc.zig");
const mem = @import("../mem.zig");

const ENOSYS = root.ENOSYS;
const EBADF = root.EBADF;
const EFAULT = root.EFAULT;
const EINVAL = root.EINVAL;
const ENOMEM = root.ENOMEM;
const ENOENT = root.ENOENT;
const EMFILE: u64 = root.EMFILE;

const paging = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("../arch/x86_64/paging.zig"),
    .riscv64 => @import("../arch/riscv64/paging.zig"),
    .aarch64 => @import("../arch/aarch64/paging.zig"),
    else => struct {},
};

/// Operation codes for proc_setup.
pub const OP_MOUNT = 0;
pub const OP_SETFD = 1;
pub const OP_SETCOMPAT = 2;
pub const OP_SETQUOTA = 3;
pub const OP_READY = 4;
pub const OP_SETARGV = 5;
pub const OP_SETGROUP = 6;
pub const OP_CLEARNM = 7;
pub const OP_MOUNTPFX = 8;
pub const OP_CLONENM = 9;
pub const OP_ALLOCGROUP = 10;
pub const OP_GROUPKILL = 11;
pub const OP_FREEGROUP = 12;
pub const OP_SETQUOTA_GROUP = 13;

/// proc_setup(op, target_pid, arg0, arg1, arg2) -> result
pub fn sysProcSetup(op: u64, target_pid: u64, a0: u64, a1: u64, a2: u64) u64 {
    const caller = process.getCurrent() orelse return ENOSYS;

    // Only root can configure processes
    if (caller.uid != 0) return EINVAL;

    // Ops that don't need a target process
    switch (op) {
        OP_ALLOCGROUP => return opAllocGroup(),
        OP_GROUPKILL => return opGroupKill(@intCast(target_pid)),
        OP_FREEGROUP => return opFreeGroup(@intCast(target_pid)),
        OP_SETQUOTA_GROUP => return opSetQuotaGroup(@intCast(target_pid), a0, a1),
        else => {},
    }

    // All other ops require a valid target process in .blocked state
    const target = process.getByPid(@intCast(target_pid)) orelse {
        klog.err("[proc_setup] target pid not found: ");
        klog.errDec(target_pid);
        klog.err("\n");
        return ENOENT;
    };

    // Target must be blocked (not yet running) for safe mutation.
    // Exception: OP_READY transitions blocked -> ready.
    if (@atomicLoad(process.ProcessState, &target.state, .acquire) != .blocked) {
        klog.err("[proc_setup] target not blocked, pid=");
        klog.errDec(target_pid);
        klog.err("\n");
        return EINVAL;
    }

    switch (op) {
        OP_MOUNT => return opMount(caller, target, a0, a1, a2),
        OP_SETFD => return opSetFd(caller, target, a0, a1, a2),
        OP_SETCOMPAT => return opSetCompat(target, a0),
        OP_SETQUOTA => return opSetQuota(target, a0, a1),
        OP_READY => return opReady(target),
        OP_SETARGV => return opSetArgv(target, a0, a1),
        OP_SETGROUP => return opSetGroup(target, a0),
        OP_CLEARNM => return opClearNm(target),
        OP_MOUNTPFX => return opMountPfx(caller, target, a0, a1, a2),
        OP_CLONENM => return opCloneNm(target, a0),
        else => return EINVAL,
    }
}

// ── Op implementations ──────────────────────────────────────────────

/// OP_MOUNT: mount(path_ptr, path_len, caller_fd)
/// Mount a channel in the target process's namespace.
/// `caller_fd` is an fd in the caller's fd table; its channel_id is used for the mount.
fn opMount(caller: *process.Process, target: *process.Process, path_ptr: u64, path_len: u64, caller_fd: u64) u64 {
    if (path_ptr == 0 or path_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (path_len == 0 or path_len > namespace.MAX_PATH) return EINVAL;
    if (caller_fd >= process.MAX_FDS) return EBADF;

    const entry = caller.getFdEntry(@intCast(caller_fd)) orelse return EBADF;
    const path: []const u8 = @as([*]const u8, @ptrFromInt(path_ptr))[0..@intCast(path_len)];
    target.getNs().mount(path, entry.channel_id, .{}) catch return ENOMEM;
    return 0;
}

/// OP_SETFD: setfd(child_fd, parent_fd, flags)
/// Copy an fd entry from the caller to the target.
/// flags: bit 0 = is_server
fn opSetFd(caller: *process.Process, target: *process.Process, child_fd: u64, parent_fd: u64, flags: u64) u64 {
    if (child_fd >= process.MAX_FDS or parent_fd >= process.MAX_FDS) return EBADF;

    const entry = caller.getFdEntry(@intCast(parent_fd)) orelse return EBADF;
    var new_entry = entry;
    new_entry.is_server = (flags & 1) != 0;

    const fds = if (target.thread_group) |tg|
        (if (tg.fd_table) |ft| &ft.fds else &target.fds)
    else
        &target.fds;
    fds[@intCast(child_fd)] = new_entry;
    return 0;
}

/// OP_SETCOMPAT: setcompat(mode)
/// mode: 0 = fornax, 1 = linux
fn opSetCompat(target: *process.Process, mode: u64) u64 {
    if (mode > 1) return EINVAL;
    target.compat = @intCast(mode);
    return 0;
}

/// OP_SETQUOTA: setquota(field, value)
/// field: 0 = max_memory_pages, 1 = max_channels, 2 = max_children, 3 = cpu_priority
fn opSetQuota(target: *process.Process, field: u64, value: u64) u64 {
    switch (field) {
        0 => target.quotas.max_memory_pages = @intCast(value),
        1 => target.quotas.max_channels = @intCast(value),
        2 => target.quotas.max_children = @intCast(value),
        3 => target.quotas.cpu_priority = @intCast(value),
        else => return EINVAL,
    }
    return 0;
}

/// OP_READY: mark the target process as runnable.
fn opReady(target: *process.Process) u64 {
    process.markReady(target);
    return 0;
}

/// OP_SETARGV: setargv(argv_ptr, argv_len)
/// Copy argv wire format from caller's address space into target's ARGV_BASE page.
/// argv_ptr points to the standard Fornax argv wire format in the CALLER's memory.
fn opSetArgv(target: *process.Process, argv_ptr: u64, argv_len: u64) u64 {
    if (argv_ptr == 0 or argv_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (argv_len == 0 or argv_len > 4096) return EINVAL;

    const target_pml4 = target.pml4 orelse return ENOMEM;

    // Read from caller's address space (we're in kernel mode, can access it)
    const src: [*]const u8 = @ptrFromInt(argv_ptr);

    // Use the standard setupArgv if this is a native Fornax process
    if (target.compat == 0) {
        proc_handlers.setupArgv(target_pml4, argv_ptr, target);
    } else {
        // Linux compat: build System V ABI stack layout.
        // Wire format: [argc: u32][total_str_len: u32][str0\0str1\0...]
        // Target layout at ARGV_BASE (pointed to by RSP):
        //   [argc: u64]
        //   [argv[0]: u64] ... [argv[N-1]: u64]
        //   [NULL: u64]           <- end of argv
        //   [NULL: u64]           <- end of envp (empty)
        //   [auxv entries: u64 pairs]
        //   [AT_NULL, 0]
        //   [string data]

        const wire_argc = @as(u32, src[0]) |
            (@as(u32, src[1]) << 8) |
            (@as(u32, src[2]) << 16) |
            (@as(u32, src[3]) << 24);
        const wire_total = @as(u32, src[4]) |
            (@as(u32, src[5]) << 8) |
            (@as(u32, src[6]) << 16) |
            (@as(u32, src[7]) << 24);

        if (wire_argc == 0 or wire_argc > 64 or wire_total == 0 or wire_total > 3000) return EINVAL;

        // Read auxv from target's AUXV_BASE page (written by sysSpawn)
        var auxv_data: [96]u8 = .{0} ** 96;
        const auxv_phys = paging.translateVaddr(target_pml4, mem.AUXV_BASE);
        if (auxv_phys) |phys| {
            const auxv_src: [*]const u8 = paging.physPtr(phys & ~@as(u64, 0xFFF));
            const page_off: usize = @intCast(mem.AUXV_BASE & 0xFFF);
            @memcpy(&auxv_data, auxv_src[page_off..][0..96]);
        } else {
            // No auxv page — write minimal: AT_PAGESZ + AT_NULL
            const buf = &auxv_data;
            root.writeU64LE(buf[0..8], 6); // AT_PAGESZ
            root.writeU64LE(buf[8..16], mem.PAGE_SIZE);
            root.writeU64LE(buf[16..24], 0); // AT_NULL
            root.writeU64LE(buf[24..32], 0);
        }

        // Layout:
        //   8 bytes: argc
        //   wire_argc * 8 bytes: argv pointers
        //   8 bytes: NULL (argv terminator)
        //   8 bytes: NULL (envp terminator)
        //   96 bytes: auxv
        //   wire_total bytes: string data
        const header_size: usize = 8 + @as(usize, wire_argc) * 8 + 8 + 8;
        const strings_start: usize = header_size + 96;
        const total_size = strings_start + wire_total;

        if (total_size > proc_handlers.argv_layout_buf.len) return EINVAL;

        @memset(proc_handlers.argv_layout_buf[0..total_size], 0);

        // Write argc
        root.writeU64LE(proc_handlers.argv_layout_buf[0..8], wire_argc);

        // Copy string data
        @memcpy(proc_handlers.argv_layout_buf[strings_start..][0..wire_total], src[8..][0..wire_total]);

        // Build argv pointer array
        var str_offset: usize = 0;
        var arg_i: usize = 0;
        while (arg_i < wire_argc and str_offset < wire_total) {
            const str_vaddr: u64 = mem.ARGV_BASE + strings_start + str_offset;
            const ptr_offset = 8 + arg_i * 8;
            root.writeU64LE(proc_handlers.argv_layout_buf[ptr_offset..][0..8], str_vaddr);

            // Skip to next null terminator
            while (str_offset < wire_total and proc_handlers.argv_layout_buf[strings_start + str_offset] != 0) {
                str_offset += 1;
            }
            str_offset += 1; // skip the null
            arg_i += 1;
        }

        // argv NULL terminator already zero from memset
        // envp NULL terminator already zero from memset

        // Copy auxv data after envp NULL
        const auxv_offset = header_size;
        @memcpy(proc_handlers.argv_layout_buf[auxv_offset..][0..96], &auxv_data);

        // Write to target's ARGV_BASE
        _ = proc_handlers.writeToChildMem(target_pml4, mem.ARGV_BASE, proc_handlers.argv_layout_buf[0..total_size]);

        // Linux ABI: RSP points to argc at entry
        target.user_rsp = mem.ARGV_BASE;
    }
    return 0;
}

/// OP_SETGROUP: setgroup(group_id)
/// Assign target process to a process group.
fn opSetGroup(target: *process.Process, group_id: u64) u64 {
    const gid: u8 = @intCast(group_id & 0xFF);
    if (gid != process_group.HOST_GROUP) {
        // Validate group exists
        _ = process_group.getById(gid) orelse return EINVAL;
    }
    target.group_id = gid;
    // If joining a group, increment its process count
    if (gid != process_group.HOST_GROUP) {
        if (process_group.getById(gid)) |g| {
            process_group.addProcess(g);
        }
    }
    return 0;
}

/// OP_CLEARNM: clear all mounts in target's namespace (fresh empty namespace).
fn opClearNm(target: *process.Process) u64 {
    target.ns = namespace.Namespace.init();
    return 0;
}

/// OP_MOUNTPFX: mountpfx(path_ptr, prefix_ptr, packed)
/// Mount with prefix. Uses caller's fd to resolve channel_id.
/// packed = (path_len:u16, prefix_len:u16, caller_fd:u32)
fn opMountPfx(caller: *process.Process, target: *process.Process, a0: u64, a1: u64, a2: u64) u64 {
    // Unpack: a0 = path_ptr, a1 = prefix_ptr, a2 = packed(path_len:u16, prefix_len:u16, caller_fd:u32)
    const path_ptr = a0;
    const prefix_ptr = a1;
    const path_len: u16 = @truncate(a2);
    const prefix_len: u16 = @truncate(a2 >> 16);
    const caller_fd: u32 = @truncate(a2 >> 32);

    if (path_ptr == 0 or path_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (prefix_ptr == 0 or prefix_ptr >= 0x0000_8000_0000_0000) return EFAULT;
    if (path_len == 0 or path_len > namespace.MAX_PATH) return EINVAL;
    if (prefix_len > namespace.MAX_PREFIX) return EINVAL;
    if (caller_fd >= process.MAX_FDS) return EBADF;

    const entry = caller.getFdEntry(@intCast(caller_fd)) orelse return EBADF;
    const path: []const u8 = @as([*]const u8, @ptrFromInt(path_ptr))[0..path_len];
    const prefix: []const u8 = @as([*]const u8, @ptrFromInt(prefix_ptr))[0..prefix_len];

    target.getNs().mountWithPrefix(path, entry.channel_id, .{ .replace = true }, prefix) catch return ENOMEM;
    return 0;
}

/// OP_CLONENM: clone namespace from source_pid into target.
fn opCloneNm(target: *process.Process, source_pid: u64) u64 {
    if (source_pid == 0) {
        // Clone from root namespace
        namespace.getRootNamespace().cloneInto(&target.ns);
        return 0;
    }
    const source = process.getByPid(@intCast(source_pid)) orelse return ENOENT;
    source.getNs().cloneInto(&target.ns);
    return 0;
}

/// OP_ALLOCGROUP: allocate a new process group. Returns group id (0..15) or error.
fn opAllocGroup() u64 {
    const g = process_group.alloc() orelse return ENOMEM;
    return g.id;
}

/// OP_GROUPKILL: kill all processes in group `group_id`.
fn opGroupKill(group_id: u8) u64 {
    const g = process_group.getById(group_id) orelse return EINVAL;
    process_group.killAll(g);
    return 0;
}

/// OP_FREEGROUP: free a process group slot.
fn opFreeGroup(group_id: u8) u64 {
    const g = process_group.getById(group_id) orelse return EINVAL;
    process_group.free(g);
    return 0;
}

/// OP_SETQUOTA_GROUP: set quota on a process group.
/// field: same as OP_SETQUOTA
fn opSetQuotaGroup(group_id: u8, field: u64, value: u64) u64 {
    const g = process_group.getById(group_id) orelse return EINVAL;
    switch (field) {
        0 => g.quotas.max_memory_pages = @intCast(value),
        1 => g.quotas.max_channels = @intCast(value),
        2 => g.quotas.max_children = @intCast(value),
        3 => g.quotas.cpu_priority = @intCast(value),
        else => return EINVAL,
    }
    return 0;
}
