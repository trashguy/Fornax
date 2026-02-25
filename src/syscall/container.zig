/// Container operation syscall handler.
const process = @import("../process.zig");
const ipc = @import("../ipc.zig");
const elf = @import("../elf.zig");
const pmm = @import("../pmm.zig");
const mem = @import("../mem.zig");
const klog = @import("../klog.zig");
const paging = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("../arch/x86_64/paging.zig"),
    .riscv64 => @import("../arch/riscv64/paging.zig"),
    .aarch64 => @import("../arch/aarch64/paging.zig"),
    else => struct {},
};
const root = @import("root.zig");
const proc_handlers = @import("proc.zig");

const ENOSYS = root.ENOSYS;
const EBADF = root.EBADF;
const EFAULT = root.EFAULT;
const EINVAL = root.EINVAL;
const ENOMEM = root.ENOMEM;
const ENOENT = root.ENOENT;
const writeU32LE = root.writeU32LE;
const writeU64LE = root.writeU64LE;

/// cntr_op(op, cntr_id, arg0, arg1, arg2) → result
/// op=0: start  (arg0=elf_ptr, arg1=elf_len, arg2=argv_ptr) → pid
/// op=1: stop   → 0 on success
/// op=2: destroy → 0 on success
/// op=3: exec   (arg0=elf_ptr, arg1=elf_len, arg2=argv_ptr) → pid
pub fn sysCntrOp(op: u64, cntr_id: u64, a0: u64, a1: u64, a2: u64) u64 {
    const container = @import("../container.zig");
    const caller = process.getCurrent() orelse {
        klog.err("[cntr_op] getCurrent failed\n");
        return ENOSYS;
    };

    // Only root (uid 0) or host processes can manage containers
    if (caller.uid != 0) {
        klog.err("[cntr_op] uid!=0\n");
        return @bitCast(@as(i64, -1));
    }
    // Container processes cannot manage other containers
    if (caller.container_id != container.HOST_CONTAINER) {
        klog.err("[cntr_op] not host container\n");
        return @bitCast(@as(i64, -1));
    }

    switch (op) {
        // --- op=0: start container ---
        0 => {
            const ct = container.getById(@intCast(cntr_id)) orelse {
                klog.err("[cntr_op] getById failed id=");
                klog.errDec(cntr_id);
                klog.err("\n");
                return EINVAL;
            };
            if (ct.state != .created) {
                klog.err("[cntr_op] state!=created (");
                klog.errDec(@intFromEnum(ct.state));
                klog.err(")\n");
                return EINVAL;
            }

            const elf_ptr = a0;
            const elf_len = a1;
            const argv_ptr = a2;
            if (elf_ptr == 0 or elf_ptr >= 0x0000_8000_0000_0000) {
                klog.err("[cntr_op] bad elf_ptr\n");
                return EFAULT;
            }
            if (elf_len == 0 or elf_len > 4 * 1024 * 1024) {
                klog.err("[cntr_op] bad elf_len=");
                klog.errDec(elf_len);
                klog.err("\n");
                return EINVAL;
            }

            const elf_data: []const u8 = @as([*]const u8, @ptrFromInt(elf_ptr))[0..@intCast(elf_len)];

            klog.info("[cntr_op] starting container id=");
            klog.infoDec(cntr_id);
            klog.info(" elf_len=");
            klog.infoDec(elf_len);
            klog.info("\n");

            // Delegate to container.start which creates process, loads ELF, sets up namespace.
            // NOTE: container.start does NOT markReady — we must set up argv/auxv first
            // to avoid an SMP race where the process runs before argv is configured.
            const pid = container.start(ct, elf_data, null) orelse {
                klog.err("[cntr_op] container.start returned null\n");
                return ENOMEM;
            };

            // Get the container's init process for argv/auxv setup
            const init_proc = blk: {
                if (ct.init_pid) |init_pid| {
                    break :blk process.getByPid(init_pid) orelse return ENOMEM;
                }
                return ENOMEM;
            };
            const child_pml4 = init_proc.pml4 orelse return ENOMEM;

            // Set up argv
            if (argv_ptr != 0 and argv_ptr < 0x0000_8000_0000_0000) {
                proc_handlers.setupArgv(child_pml4, argv_ptr, init_proc);
            } else {
                @memset(proc_handlers.argv_layout_buf[0..8], 0);
                _ = proc_handlers.writeToChildMem(child_pml4, mem.ARGV_BASE, proc_handlers.argv_layout_buf[0..8]);
                init_proc.user_rsp = mem.ARGV_BASE - 8;
            }

            // NOW safe to make runnable — argv is configured
            process.markReady(init_proc);

            return pid;
        },
        // --- op=1: stop container ---
        1 => {
            const ct = container.getById(@intCast(cntr_id)) orelse return EINVAL;
            container.stop(ct);
            return 0;
        },
        // --- op=2: destroy container ---
        2 => {
            const ct = container.getById(@intCast(cntr_id)) orelse return EINVAL;
            container.destroy(ct);
            return 0;
        },
        // --- op=3: exec (spawn into running container) ---
        3 => {
            const ct = container.getById(@intCast(cntr_id)) orelse return EINVAL;
            if (ct.state != .running) return EINVAL;

            const elf_ptr = a0;
            const elf_len = a1;
            const argv_ptr = a2;
            if (elf_ptr == 0 or elf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
            if (elf_len == 0 or elf_len > 4 * 1024 * 1024) return EINVAL;

            const elf_data: []const u8 = @as([*]const u8, @ptrFromInt(elf_ptr))[0..@intCast(elf_len)];

            // Create a new process inside the container
            const child = process.create() orelse return ENOMEM;

            // Copy namespace from container's init process
            if (ct.init_pid) |init_pid| {
                if (process.getByPid(init_pid)) |init_proc| {
                    init_proc.getNs().cloneInto(&child.ns);
                }
            }

            // Load ELF
            const load_result = elf.load(child.pml4.?, elf_data) catch {
                child.state = .dead;
                return ENOMEM;
            };
            child.user_rip = load_result.entry_point;
            child.brk = load_result.brk;

            // Allocate user stack
            for (0..process.USER_STACK_PAGES) |i| {
                const page = pmm.allocPage() orelse {
                    child.state = .dead;
                    return ENOMEM;
                };
                const ptr: [*]u8 = paging.physPtr(page);
                @memset(ptr[0..mem.PAGE_SIZE], 0);
                const vaddr = mem.USER_STACK_TOP - (process.USER_STACK_PAGES - i) * mem.PAGE_SIZE;
                paging.mapPage(child.pml4.?, vaddr, page, paging.Flags.WRITABLE | paging.Flags.USER) orelse {
                    child.state = .dead;
                    return ENOMEM;
                };
            }

            // Set up argv
            const child_pml4 = child.pml4.?;
            if (argv_ptr != 0 and argv_ptr < 0x0000_8000_0000_0000) {
                proc_handlers.setupArgv(child_pml4, argv_ptr, child);
            } else {
                @memset(proc_handlers.argv_layout_buf[0..8], 0);
                _ = proc_handlers.writeToChildMem(child_pml4, mem.ARGV_BASE, proc_handlers.argv_layout_buf[0..8]);
                child.user_rsp = mem.ARGV_BASE - 8;
            }

            // Write auxv
            {
                const AUXV_BASE: u64 = mem.ARGV_BASE - mem.PAGE_SIZE;
                const auxv_page = pmm.allocPage() orelse {
                    child.state = .dead;
                    return ENOMEM;
                };
                const auxv_ptr2: [*]u8 = paging.physPtr(auxv_page);
                @memset(auxv_ptr2[0..mem.PAGE_SIZE], 0);
                paging.mapPage(child_pml4, AUXV_BASE, auxv_page, paging.Flags.WRITABLE | paging.Flags.USER) orelse {
                    child.state = .dead;
                    return ENOMEM;
                };

                var auxv_buf: [96]u8 = @splat(0);
                var off: usize = 0;
                writeU64LE(auxv_buf[off..][0..8], 3); off += 8;
                writeU64LE(auxv_buf[off..][0..8], load_result.phdr_vaddr); off += 8;
                writeU64LE(auxv_buf[off..][0..8], 5); off += 8;
                writeU64LE(auxv_buf[off..][0..8], load_result.phnum); off += 8;
                writeU64LE(auxv_buf[off..][0..8], 4); off += 8;
                writeU64LE(auxv_buf[off..][0..8], load_result.phentsize); off += 8;
                writeU64LE(auxv_buf[off..][0..8], 9); off += 8;
                writeU64LE(auxv_buf[off..][0..8], load_result.entry_point); off += 8;
                writeU64LE(auxv_buf[off..][0..8], 6); off += 8;
                writeU64LE(auxv_buf[off..][0..8], mem.PAGE_SIZE); off += 8;
                writeU64LE(auxv_buf[off..][0..8], 0); off += 8;
                writeU64LE(auxv_buf[off..][0..8], 0); off += 8;
                _ = proc_handlers.writeToChildMem(child_pml4, AUXV_BASE, auxv_buf[0..off]);
            }

            // Set container association
            child.container_id = ct.id;
            child.compat = @intFromEnum(ct.compat);
            child.uid = 0; // Container exec runs as root inside container
            child.gid = 0;
            // Re-parent: exec'd process belongs to the container init, not the
            // management tool (fnx exec), so it survives detached mode.
            child.parent_pid = ct.init_pid;
            container.addProcess(ct);

            klog.info("[cntr_exec] container=");
            klog.infoDec(ct.id);
            klog.info(" pid=");
            klog.infoDec(child.pid);
            klog.info("\n");

            // Process is fully initialized — make it runnable
            process.markReady(child);

            return child.pid;
        },
        // --- op=4: start_netd (spawn netd inside container) ---
        4 => {
            const ether_mod = @import("../ether.zig");

            const ct = container.getById(@intCast(cntr_id)) orelse return EINVAL;
            if (ct.state != .running) return EINVAL;

            const elf_ptr = a0;
            const elf_len = a1;
            if (elf_ptr == 0 or elf_ptr >= 0x0000_8000_0000_0000) return EFAULT;
            if (elf_len == 0 or elf_len > 4 * 1024 * 1024) return EINVAL;

            const elf_data: []const u8 = @as([*]const u8, @ptrFromInt(elf_ptr))[0..@intCast(elf_len)];

            // Allocate ether client for the container netd
            const ether_client = ether_mod.allocClient() orelse return ENOMEM;

            // Create IPC channel pair for /net/ mount
            const chan = ipc.channelCreate() catch {
                ether_mod.freeClient(ether_client);
                return ENOMEM;
            };

            // Create netd process (native Fornax, not compat)
            const child = process.create() orelse {
                ether_mod.freeClient(ether_client);
                return ENOMEM;
            };

            // Copy namespace from container init
            if (ct.init_pid) |init_pid| {
                if (process.getByPid(init_pid)) |init_proc| {
                    init_proc.getNs().cloneInto(&child.ns);
                }
            }

            // Load netd ELF
            const load_result = elf.load(child.pml4.?, elf_data) catch {
                child.state = .dead;
                ether_mod.freeClient(ether_client);
                return ENOMEM;
            };
            child.user_rip = load_result.entry_point;
            child.brk = load_result.brk;

            // Allocate user stack
            for (0..process.USER_STACK_PAGES) |i| {
                const page = pmm.allocPage() orelse {
                    child.state = .dead;
                    ether_mod.freeClient(ether_client);
                    return ENOMEM;
                };
                const ptr: [*]u8 = paging.physPtr(page);
                @memset(ptr[0..mem.PAGE_SIZE], 0);
                const vaddr = mem.USER_STACK_TOP - (process.USER_STACK_PAGES - i) * mem.PAGE_SIZE;
                paging.mapPage(child.pml4.?, vaddr, page, paging.Flags.WRITABLE | paging.Flags.USER) orelse {
                    child.state = .dead;
                    ether_mod.freeClient(ether_client);
                    return ENOMEM;
                };
            }
            child.user_rsp = mem.USER_STACK_INIT;

            // No argv needed for netd
            @memset(proc_handlers.argv_layout_buf[0..8], 0);
            _ = proc_handlers.writeToChildMem(child.pml4.?, mem.ARGV_BASE, proc_handlers.argv_layout_buf[0..8]);

            // Set up fd map: server_fd→3, ether_fd→4
            child.setFd(3, chan.server, true);
            child.fds[4] = .{
                .fd_type = .dev_ether,
                .channel_id = 0,
                .is_server = false,
                .read_offset = 0,
                .server_handle = 0,
                .ether_client = ether_client,
            };

            // Container association (netd is native Fornax, not compat)
            child.container_id = ct.id;
            child.compat = 0; // Native Fornax
            child.uid = 0;
            child.gid = 0;
            // Re-parent: netd belongs to the container init, not the
            // management tool (fnx run), so it survives detached mode.
            child.parent_pid = ct.init_pid;
            container.addProcess(ct);

            ct.netd_pid = child.pid;

            // Assign container IP: 10.0.1.(id+2) in network byte order
            ct.net_ip = (@as(u32, 10)) | (@as(u32, 0) << 8) | (@as(u32, 1) << 16) | (@as(u32, ct.id + 2) << 24);

            // Mount /net/ in container namespace (init process's namespace)
            if (ct.init_pid) |init_pid| {
                if (process.getByPid(init_pid)) |init_proc| {
                    init_proc.getNs().mount("/net/", chan.client, .{}) catch {};
                    // Also mount in the netd's namespace
                    child.getNs().mount("/net/", chan.client, .{}) catch {};
                }
            }

            klog.info("[cntr_netd] container=");
            klog.infoDec(ct.id);
            klog.info(" netd_pid=");
            klog.infoDec(child.pid);
            klog.info(" ip=10.0.1.");
            klog.infoDec(ct.id + 2);
            klog.info("\n");

            // Process is fully initialized — make it runnable
            process.markReady(child);

            return child.pid;
        },
        else => return EINVAL,
    }
}
