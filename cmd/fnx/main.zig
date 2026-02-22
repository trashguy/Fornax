/// fnx — Fornax container manager (podman-familiar CLI).
///
/// Manages containers via Plan 9 /cntr/ ctl files + SYS 40 cntr_op.
///
/// Commands:
///   run <image> [cmd]     Create, configure, and start a container
///   create <image>        Create a container (without starting)
///   start <name|id>       Start a created container
///   exec <name|id> <cmd>  Run a command in a running container
///   stop <name|id>        Stop a running container
///   rm <name|id>          Remove a container
///   ps [-a]               List containers (running only, or all with -a)
///   images                List available images
///   inspect <name|id>     Show container details
///   import <tar> <name>   Import a tarball as an image
///   cp <src> <cntr:dest>  Copy file into container rootfs
const fx = @import("fornax");

const out = fx.io.Writer.stdout;
const stderr = fx.io.Writer.stderr;

const MAX_ELF_SIZE = 4 * 1024 * 1024; // 4 MB max

/// Static buffer for reading ELF binary (BSS — no .data bloat).
var elf_buf: [MAX_ELF_SIZE]u8 linksection(".bss") = undefined;
/// Static buffer for argv wire format.
var argv_buf: [4096]u8 = undefined;
/// Static buffer for general file I/O.
var io_buf: [4096]u8 linksection(".bss") = undefined;
var cf_source_buf: [4096]u8 linksection(".bss") = undefined;

export fn _start() noreturn {
    const argc = fx.getArgc();
    const argv = fx.getArgs();

    if (argc < 2) {
        usage();
        fx.exit(1);
    }

    const cmd_cstr = argv[1];

    if (strEql(cmd_cstr, "run")) {
        if (argc < 3) {
            stderr.puts("Usage: fnx run [-d] [--name <name>] [--compat linux] <image> [cmd...]\n");
            fx.exit(1);
        }
        cmdRun(argc, argv);
    } else if (strEql(cmd_cstr, "create")) {
        if (argc < 3) {
            stderr.puts("Usage: fnx create [--name <name>] <image>\n");
            fx.exit(1);
        }
        cmdCreate(argc, argv);
    } else if (strEql(cmd_cstr, "start")) {
        if (argc < 3) {
            stderr.puts("Usage: fnx start <name|id>\n");
            fx.exit(1);
        }
        cmdStart(argv[2]);
    } else if (strEql(cmd_cstr, "exec")) {
        if (argc < 4) {
            stderr.puts("Usage: fnx exec <name|id> <cmd> [args...]\n");
            fx.exit(1);
        }
        cmdExec(argc, argv);
    } else if (strEql(cmd_cstr, "ps")) {
        const show_all = argc >= 3 and strEql(argv[2], "-a");
        cmdPs(show_all);
    } else if (strEql(cmd_cstr, "images")) {
        cmdImages();
    } else if (strEql(cmd_cstr, "inspect")) {
        if (argc < 3) {
            stderr.puts("Usage: fnx inspect <name|id>\n");
            fx.exit(1);
        }
        cmdInspect(argv[2]);
    } else if (strEql(cmd_cstr, "stop")) {
        if (argc < 3) {
            stderr.puts("Usage: fnx stop <name|id>\n");
            fx.exit(1);
        }
        cmdCtl(argv[2], "stop");
    } else if (strEql(cmd_cstr, "rm")) {
        if (argc < 3) {
            stderr.puts("Usage: fnx rm <name|id>\n");
            fx.exit(1);
        }
        cmdCtl(argv[2], "destroy");
    } else if (strEql(cmd_cstr, "import")) {
        if (argc < 4) {
            stderr.puts("Usage: fnx import <tarball> <name>\n");
            fx.exit(1);
        }
        cmdImport(argv[2], argv[3]);
    } else if (strEql(cmd_cstr, "cp")) {
        if (argc < 4) {
            stderr.puts("Usage: fnx cp <src> <container:dest>\n");
            fx.exit(1);
        }
        cmdCp(argv[2], argv[3]);
    } else if (strEql(cmd_cstr, "build")) {
        if (argc < 3) {
            stderr.puts("Usage: fnx build -f <Containerfile> -t <tag> [context]\n");
            fx.exit(1);
        }
        cmdBuild(argc, argv);
    } else if (strEql(cmd_cstr, "--help") or strEql(cmd_cstr, "help")) {
        usage();
        fx.exit(0);
    } else {
        stderr.puts("fnx: unknown command '");
        stderr.puts(cstr(cmd_cstr));
        stderr.puts("'\nRun 'fnx help' for usage.\n");
        fx.exit(1);
    }

    fx.exit(0);
}

fn usage() void {
    out.puts("Usage: fnx <command> [args...]\n");
    out.puts("\nContainer lifecycle:\n");
    out.puts("  run <image> [cmd]       Create and start a container\n");
    out.puts("  create <image>          Create a container (don't start)\n");
    out.puts("  start <name|id>         Start a created container\n");
    out.puts("  exec <name|id> <cmd>    Run command in a container\n");
    out.puts("  stop <name|id>          Stop a container\n");
    out.puts("  rm <name|id>            Remove a container\n");
    out.puts("\nInformation:\n");
    out.puts("  ps [-a]                 List containers\n");
    out.puts("  images                  List images\n");
    out.puts("  inspect <name|id>       Show container status\n");
    out.puts("\nImage management:\n");
    out.puts("  import <tar> <name>     Import tarball as image\n");
    out.puts("  cp <src> <cntr:dest>    Copy file into container\n");
}

// ── run ──

fn cmdRun(argc: u64, argv: []const [*:0]const u8) void {
    // Parse flags: [-d] [--name <n>] [--compat linux] <image> [cmd...]
    var detach = false;
    var name_override: ?[]const u8 = null;
    var compat_linux = false;
    var enable_net = true;
    var arg_idx: u64 = 2; // skip "fnx" "run"

    while (arg_idx < argc) {
        const a = cstr(argv[arg_idx]);
        if (a.len > 0 and a[0] == '-') {
            if (sliceEql(a, "-d")) {
                detach = true;
                arg_idx += 1;
            } else if (sliceEql(a, "--name")) {
                arg_idx += 1;
                if (arg_idx >= argc) {
                    stderr.puts("fnx run: --name requires an argument\n");
                    fx.exit(1);
                }
                name_override = cstr(argv[arg_idx]);
                arg_idx += 1;
            } else if (sliceEql(a, "--compat")) {
                arg_idx += 1;
                if (arg_idx >= argc) {
                    stderr.puts("fnx run: --compat requires an argument\n");
                    fx.exit(1);
                }
                if (sliceEql(cstr(argv[arg_idx]), "linux")) {
                    compat_linux = true;
                }
                arg_idx += 1;
            } else if (sliceEql(a, "--net=none")) {
                enable_net = false;
                arg_idx += 1;
            } else {
                stderr.puts("fnx run: unknown flag '");
                stderr.puts(a);
                stderr.puts("'\n");
                fx.exit(1);
            }
        } else {
            break; // First non-flag is the image name
        }
    }

    if (arg_idx >= argc) {
        stderr.puts("fnx run: missing image argument\n");
        fx.exit(1);
    }

    const image = cstr(argv[arg_idx]);
    arg_idx += 1;

    // Collect remaining args as the command
    var cmd_args: [64][]const u8 = undefined;
    var cmd_argc: usize = 0;
    while (arg_idx < argc and cmd_argc < 64) {
        cmd_args[cmd_argc] = cstr(argv[arg_idx]);
        cmd_argc += 1;
        arg_idx += 1;
    }

    // 1. Clone container
    const id = cloneContainer() orelse {
        stderr.puts("fnx: failed to create container\n");
        fx.exit(1);
    };

    // 2. Configure via ctl writes
    const cntr_name = name_override orelse image;
    writeCtl(id, "name ", cntr_name);

    // Set rootfs path: /var/lib/fnx/images/<image>/rootfs
    var rootfs_path: [256]u8 = undefined;
    const rootfs_len = fmtPath(&rootfs_path, "/var/lib/fnx/images/", image, "/rootfs");
    writeCtl(id, "rootfs ", rootfs_path[0..rootfs_len]);

    if (compat_linux) {
        writeCtl(id, "compat ", "linux");
    }

    // 3. Determine the init binary path
    var init_path: [256]u8 = undefined;
    var init_path_len: usize = 0;
    if (cmd_argc > 0) {
        // User specified a command — use it as the init binary
        // If cmd starts with '/', don't add extra separator (avoids "rootfs//bin/echo")
        const sep: []const u8 = if (cmd_args[0].len > 0 and cmd_args[0][0] == '/') "" else "/";
        init_path_len = fmtPath(&init_path, rootfs_path[0..rootfs_len], sep, cmd_args[0]);
    } else {
        // Try to read default command from image config
        var config_path: [256]u8 = undefined;
        const config_len = fmtPath(&config_path, "/var/lib/fnx/images/", image, "/config");
        const default_cmd = readFileStr(config_path[0..config_len]);
        if (default_cmd) |full_cmd| {
            // config contains the full CMD (may include arguments).
            // Split at first space: binary path + remaining args.
            const trimmed = trim(full_cmd);
            var bin_end: usize = 0;
            while (bin_end < trimmed.len and trimmed[bin_end] != ' ') : (bin_end += 1) {}
            const bin_path = trimmed[0..bin_end];
            const sep2: []const u8 = if (bin_path.len > 0 and bin_path[0] == '/') "" else "/";
            init_path_len = fmtPath(&init_path, rootfs_path[0..rootfs_len], sep2, bin_path);
            cmd_args[0] = bin_path;
            cmd_argc = 1;
            // Parse remaining args after the binary path
            var rest = trimmed[bin_end..];
            while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
            while (rest.len > 0 and cmd_argc < 64) {
                var end: usize = 0;
                while (end < rest.len and rest[end] != ' ') : (end += 1) {}
                cmd_args[cmd_argc] = rest[0..end];
                cmd_argc += 1;
                rest = rest[end..];
                while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
            }
        } else {
            // Fallback: try /bin/init or /bin/sh
            init_path_len = fmtPath(&init_path, rootfs_path[0..rootfs_len], "/bin/", "init");
            cmd_args[0] = "/bin/init";
            cmd_argc = 1;
        }
    }

    // 4. Read the init ELF binary
    const elf_data = readFileBuf(init_path[0..init_path_len], &elf_buf) orelse {
        stderr.puts("fnx: failed to read init binary: ");
        stderr.puts(init_path[0..init_path_len]);
        stderr.puts("\n");
        // Clean up: destroy the container
        ctlById(id, "destroy");
        fx.exit(1);
    };

    // 5. Build argv block
    const argv_block = fx.buildArgvBlock(&argv_buf, cmd_args[0..cmd_argc]);

    // 6. Start container via SYS 40
    const pid = fx.cntr_start(id, elf_data, argv_block);
    if (pid < 0) {
        stderr.puts("fnx: failed to start container\n");
        ctlById(id, "destroy");
        fx.exit(1);
    }

    // 7. Spawn container netd if networking enabled
    if (enable_net) {
        // Use a second buffer for netd ELF (reuse io_buf for path)
        const netd_data = readFileBuf("/bin/netd", &elf_buf) orelse null;
        if (netd_data) |nd| {
            const netd_pid = fx.cntr_netd(id, nd);
            if (netd_pid >= 0) {
                out.puts("  netd pid=");
                out.putDec(@intCast(netd_pid));
                out.puts("\n");
            }
        }
    }

    out.puts("Container ");
    out.puts(cntr_name);
    out.puts(" started (id=");
    out.putDec(id);
    out.puts(", pid=");
    out.putDec(@intCast(pid));
    out.puts(")\n");

    // 8. Wait or detach
    if (!detach) {
        _ = fx.wait(@intCast(pid));
    }
}

// ── create ──

fn cmdCreate(argc: u64, argv: []const [*:0]const u8) void {
    var name_override: ?[]const u8 = null;
    var arg_idx: u64 = 2;

    while (arg_idx < argc) {
        const a = cstr(argv[arg_idx]);
        if (sliceEql(a, "--name")) {
            arg_idx += 1;
            if (arg_idx >= argc) {
                stderr.puts("fnx create: --name requires an argument\n");
                fx.exit(1);
            }
            name_override = cstr(argv[arg_idx]);
            arg_idx += 1;
        } else if (a.len > 0 and a[0] == '-') {
            stderr.puts("fnx create: unknown flag\n");
            fx.exit(1);
        } else {
            break;
        }
    }

    if (arg_idx >= argc) {
        stderr.puts("fnx create: missing image argument\n");
        fx.exit(1);
    }
    const image = cstr(argv[arg_idx]);

    const id = cloneContainer() orelse {
        stderr.puts("fnx: failed to create container\n");
        fx.exit(1);
    };

    const cntr_name = name_override orelse image;
    writeCtl(id, "name ", cntr_name);

    var rootfs_path: [256]u8 = undefined;
    const rootfs_len = fmtPath(&rootfs_path, "/var/lib/fnx/images/", image, "/rootfs");
    writeCtl(id, "rootfs ", rootfs_path[0..rootfs_len]);

    out.putDec(id);
    out.puts("\n");
}

// ── start ──

fn cmdStart(name_cstr: [*:0]const u8) void {
    const id = resolveContainer(name_cstr) orelse {
        stderr.puts("fnx: container not found\n");
        fx.exit(1);
    };

    // Read rootfs and determine init binary
    var path_buf: [32]u8 = undefined;
    const slen = fmtCntrPath(&path_buf, id, "/status");
    const status_data = readFileBuf(path_buf[0..slen], &io_buf) orelse {
        stderr.puts("fnx: cannot read container status\n");
        fx.exit(1);
    };

    const rootfs = getKV(status_data, "rootfs") orelse {
        stderr.puts("fnx: container has no rootfs\n");
        fx.exit(1);
    };

    const cmd = getKV(status_data, "cmd");

    // Build init path
    var init_path: [256]u8 = undefined;
    var init_path_len: usize = 0;
    var cmd_str: []const u8 = "/bin/init";
    if (cmd) |c| {
        if (c.len > 0) {
            cmd_str = c;
        }
    }
    init_path_len = fmtPath(&init_path, rootfs, "/", cmd_str);

    // Read ELF
    const elf_data = readFileBuf(init_path[0..init_path_len], &elf_buf) orelse {
        stderr.puts("fnx: cannot read init binary\n");
        fx.exit(1);
    };

    var args: [1][]const u8 = .{cmd_str};
    const argv_block = fx.buildArgvBlock(&argv_buf, &args);

    const pid = fx.cntr_start(id, elf_data, argv_block);
    if (pid < 0) {
        stderr.puts("fnx: failed to start container\n");
        fx.exit(1);
    }

    out.puts("Started (pid=");
    out.putDec(@intCast(pid));
    out.puts(")\n");
}

// ── exec ──

fn cmdExec(argc: u64, argv: []const [*:0]const u8) void {
    const cntr_name = argv[2];
    const id = resolveContainer(cntr_name) orelse {
        stderr.puts("fnx: container not found\n");
        fx.exit(1);
    };

    // Read rootfs from container status
    var path_buf: [32]u8 = undefined;
    const slen = fmtCntrPath(&path_buf, id, "/status");
    const status_data = readFileBuf(path_buf[0..slen], &io_buf) orelse {
        stderr.puts("fnx: cannot read container status\n");
        fx.exit(1);
    };

    const rootfs = getKV(status_data, "rootfs") orelse {
        stderr.puts("fnx: container has no rootfs\n");
        fx.exit(1);
    };

    // Build binary path: rootfs + cmd
    const cmd = cstr(argv[3]);
    var exec_path: [256]u8 = undefined;
    const sep: []const u8 = if (cmd.len > 0 and cmd[0] == '/') "" else "/";
    const exec_len = fmtPath(&exec_path, rootfs, sep, cmd);

    // Read ELF
    const elf_data = readFileBuf(exec_path[0..exec_len], &elf_buf) orelse {
        stderr.puts("fnx: cannot read binary: ");
        stderr.puts(exec_path[0..exec_len]);
        stderr.puts("\n");
        fx.exit(1);
    };

    // Collect command + args
    var cmd_args: [64][]const u8 = undefined;
    var cmd_argc: usize = 0;
    var i: u64 = 3;
    while (i < argc and cmd_argc < 64) {
        cmd_args[cmd_argc] = cstr(argv[i]);
        cmd_argc += 1;
        i += 1;
    }

    const argv_block = fx.buildArgvBlock(&argv_buf, cmd_args[0..cmd_argc]);

    const pid = fx.cntr_exec(id, elf_data, argv_block);
    if (pid < 0) {
        stderr.puts("fnx: exec failed\n");
        fx.exit(1);
    }

    // Wait for exec'd process
    _ = fx.wait(@intCast(pid));
}

// ── ps ──

fn cmdPs(show_all: bool) void {
    out.puts("ID  NAME            STATE     PROCS\n");

    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        var path_buf: [32]u8 = undefined;
        const len = fmtCntrPath(&path_buf, i, "/status");
        const fd = fx.open(path_buf[0..len]);
        if (fd < 0) continue;

        var buf: [512]u8 = undefined;
        const n = fx.read(fd, &buf);
        _ = fx.close(fd);
        if (n <= 0) continue;

        const data = buf[0..@intCast(n)];
        const state = getKV(data, "state") orelse "?";

        // Skip non-running containers unless -a
        if (!show_all and !sliceEql(state, "running")) continue;

        const name = getKV(data, "name") orelse "(none)";
        const procs = getKV(data, "procs") orelse "0";

        out.putDec(i);
        out.puts("   ");
        out.puts(name);
        var pad: usize = name.len;
        while (pad < 16) : (pad += 1) out.puts(" ");
        out.puts(state);
        pad = state.len;
        while (pad < 10) : (pad += 1) out.puts(" ");
        out.puts(procs);
        out.puts("\n");
    }
}

// ── images ──

fn cmdImages() void {
    out.puts("REPOSITORY\n");
    const fd = fx.open("/var/lib/fnx/images");
    if (fd < 0) {
        out.puts("(no images directory)\n");
        return;
    }
    var buf: [4096]u8 = undefined;
    const n = fx.read(fd, &buf);
    _ = fx.close(fd);
    if (n <= 0) {
        out.puts("(no images)\n");
        return;
    }
    // Parse directory entries (DirEntry: 64-byte name + 4-byte inode + 2-byte type + 2-byte name_len = 72 bytes)
    const entry_size = 72;
    var off: usize = 0;
    const total: usize = @intCast(n);
    while (off + entry_size <= total) : (off += entry_size) {
        const name_bytes = buf[off..][0..64];
        var name_len: usize = 0;
        while (name_len < 64 and name_bytes[name_len] != 0) : (name_len += 1) {}
        if (name_len > 0) {
            out.puts(name_bytes[0..name_len]);
            out.puts("\n");
        }
    }
}

// ── inspect ──

fn cmdInspect(name_cstr: [*:0]const u8) void {
    const id = resolveContainer(name_cstr) orelse {
        stderr.puts("fnx: container not found\n");
        fx.exit(1);
    };

    var path_buf: [32]u8 = undefined;
    const len = fmtCntrPath(&path_buf, id, "/status");
    const fd = fx.open(path_buf[0..len]);
    if (fd < 0) {
        stderr.puts("fnx: cannot read container status\n");
        fx.exit(1);
    }

    var buf: [1024]u8 = undefined;
    const n = fx.read(fd, &buf);
    _ = fx.close(fd);
    if (n > 0) {
        _ = fx.write(1, buf[0..@intCast(n)]);
    }
}

// ── ctl commands (stop, rm) ──

fn cmdCtl(name_cstr: [*:0]const u8, command: []const u8) void {
    const id = resolveContainer(name_cstr) orelse {
        stderr.puts("fnx: container not found\n");
        fx.exit(1);
    };
    ctlById(id, command);
}

fn ctlById(id: u8, command: []const u8) void {
    var path_buf: [32]u8 = undefined;
    const len = fmtCntrPath(&path_buf, id, "/ctl");
    const fd = fx.open(path_buf[0..len]);
    if (fd >= 0) {
        _ = fx.write(fd, command);
        _ = fx.close(fd);
    }
}

// ── import ──

fn cmdImport(tar_cstr: [*:0]const u8, name_cstr: [*:0]const u8) void {
    const tar_path = cstr(tar_cstr);
    const name = cstr(name_cstr);

    // Create image directory: /var/lib/fnx/images/<name>
    var dir_path: [256]u8 = undefined;
    const dir_len = fmtPath(&dir_path, "/var/lib/fnx/images/", name, "");

    // Ensure parent directories exist
    _ = fx.mkdir("/var/lib");
    _ = fx.mkdir("/var/lib/fnx");
    _ = fx.mkdir("/var/lib/fnx/images");
    _ = fx.mkdir(dir_path[0..dir_len]);

    var rootfs_dir: [256]u8 = undefined;
    const rootfs_len = fmtPath(&rootfs_dir, dir_path[0..dir_len], "/rootfs", "");
    _ = fx.mkdir(rootfs_dir[0..rootfs_len]);

    // Use tar command to extract
    // Build argv: ["tar", "-x", "-f", tar_path, "-C", rootfs_dir]
    var tar_args: [6][]const u8 = .{
        "tar",
        "-x",
        "-f",
        tar_path,
        "-C",
        rootfs_dir[0..rootfs_len],
    };
    const tar_argv = fx.buildArgvBlock(&argv_buf, &tar_args);

    // Read the tar binary
    const tar_elf = readFileBuf("/bin/tar", &elf_buf) orelse {
        stderr.puts("fnx: /bin/tar not found\n");
        fx.exit(1);
    };

    // Spawn tar to extract
    var fd_map: [0]fx.FdMapping = .{};
    const pid = fx.spawn(tar_elf, &fd_map, tar_argv);
    if (pid < 0) {
        stderr.puts("fnx: failed to spawn tar\n");
        fx.exit(1);
    }

    _ = fx.wait(@intCast(pid));

    out.puts("Imported image '");
    out.puts(name);
    out.puts("'\n");
}

// ── cp ──

fn cmdCp(src_cstr: [*:0]const u8, dest_cstr: [*:0]const u8) void {
    const src = cstr(src_cstr);
    const dest = cstr(dest_cstr);

    // Parse "container:path" format
    var colon_idx: ?usize = null;
    for (dest, 0..) |c, i| {
        if (c == ':') {
            colon_idx = i;
            break;
        }
    }

    if (colon_idx == null) {
        stderr.puts("fnx cp: dest must be container:path\n");
        fx.exit(1);
    }

    const ci = colon_idx.?;
    const cntr_name = dest[0..ci];
    const dest_path = dest[ci + 1 ..];

    // Resolve container and find its rootfs
    const id = resolveContainerSlice(cntr_name) orelse {
        stderr.puts("fnx: container '");
        stderr.puts(cntr_name);
        stderr.puts("' not found\n");
        fx.exit(1);
    };

    // Read rootfs from status
    var path_buf: [32]u8 = undefined;
    const slen = fmtCntrPath(&path_buf, id, "/status");
    const status_data = readFileBuf(path_buf[0..slen], &io_buf) orelse {
        stderr.puts("fnx: cannot read container status\n");
        fx.exit(1);
    };

    const rootfs = getKV(status_data, "rootfs") orelse {
        stderr.puts("fnx: container has no rootfs\n");
        fx.exit(1);
    };

    // Build full destination: rootfs + dest_path
    var full_dest: [512]u8 = undefined;
    const full_len = fmtPath(&full_dest, rootfs, "/", dest_path);

    // Copy file: read src, write to dest
    const data = readFileBuf(src, &elf_buf) orelse {
        stderr.puts("fnx: cannot read source file\n");
        fx.exit(1);
    };

    // Create destination file
    const fd = fx.create(full_dest[0..full_len], 0);
    if (fd < 0) {
        stderr.puts("fnx: cannot create destination\n");
        fx.exit(1);
    }

    var written: usize = 0;
    while (written < data.len) {
        const n = fx.write(fd, data[written..]);
        if (n <= 0) break;
        written += @intCast(n);
    }
    _ = fx.close(fd);
}

// ── Container resolution (name or numeric ID) ──

fn resolveContainer(name_cstr: [*:0]const u8) ?u8 {
    const name = cstr(name_cstr);
    return resolveContainerSlice(name);
}

fn resolveContainerSlice(name: []const u8) ?u8 {
    // Try numeric ID first
    if (parseU8(name)) |id| {
        // Verify it exists
        var path_buf: [32]u8 = undefined;
        const len = fmtCntrPath(&path_buf, id, "/status");
        const fd = fx.open(path_buf[0..len]);
        if (fd >= 0) {
            _ = fx.close(fd);
            return id;
        }
    }

    // Search by name
    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        var path_buf: [32]u8 = undefined;
        const len = fmtCntrPath(&path_buf, i, "/status");
        const fd = fx.open(path_buf[0..len]);
        if (fd < 0) continue;

        var buf: [512]u8 = undefined;
        const n = fx.read(fd, &buf);
        _ = fx.close(fd);
        if (n <= 0) continue;

        const data = buf[0..@intCast(n)];
        const cntr_name = getKV(data, "name") orelse continue;
        if (sliceEql(cntr_name, name)) return i;
    }

    return null;
}

// ── Clone a container via /cntr/clone ──

fn cloneContainer() ?u8 {
    const fd = fx.open("/cntr/clone");
    if (fd < 0) return null;

    var id_buf: [16]u8 = undefined;
    const n = fx.read(fd, &id_buf);
    _ = fx.close(fd);
    if (n <= 0) return null;

    // Parse numeric ID from response
    return parseU8(id_buf[0..@intCast(n)]);
}

// ── Write a ctl command: "key value" ──

fn writeCtl(id: u8, key: []const u8, value: []const u8) void {
    var ctl_buf: [512]u8 = undefined;
    var pos: usize = 0;
    @memcpy(ctl_buf[pos..][0..key.len], key);
    pos += key.len;
    @memcpy(ctl_buf[pos..][0..value.len], value);
    pos += value.len;

    var path_buf: [32]u8 = undefined;
    const plen = fmtCntrPath(&path_buf, id, "/ctl");
    const fd = fx.open(path_buf[0..plen]);
    if (fd >= 0) {
        _ = fx.write(fd, ctl_buf[0..pos]);
        _ = fx.close(fd);
    }
}

// ── Helpers ──

fn cstr(s: [*:0]const u8) []const u8 {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {}
    return s[0..i];
}

fn strEql(a: [*:0]const u8, b: []const u8) bool {
    var i: usize = 0;
    while (i < b.len) : (i += 1) {
        if (a[i] == 0 or a[i] != b[i]) return false;
    }
    return a[i] == 0;
}

fn sliceEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn parseU8(s: []const u8) ?u8 {
    if (s.len == 0) return null;
    var val: u16 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        val = val * 10 + (c - '0');
        if (val > 255) return null;
    }
    return @intCast(val);
}

fn fmtCntrPath(buf: []u8, id: u8, suffix: []const u8) usize {
    const prefix = "/cntr/";
    var pos: usize = 0;
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    if (id >= 100) {
        buf[pos] = '0' + id / 100;
        pos += 1;
    }
    if (id >= 10) {
        buf[pos] = '0' + (id / 10) % 10;
        pos += 1;
    }
    buf[pos] = '0' + id % 10;
    pos += 1;
    @memcpy(buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;
    return pos;
}

/// Format: prefix + middle + suffix into buf, return total length.
fn fmtPath(buf: []u8, prefix: []const u8, middle: []const u8, suffix: []const u8) usize {
    var pos: usize = 0;
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    @memcpy(buf[pos..][0..middle.len], middle);
    pos += middle.len;
    @memcpy(buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;
    return pos;
}

fn getKV(data: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < data.len) {
        var eol = i;
        while (eol < data.len and data[eol] != '\n') : (eol += 1) {}
        const line = data[i..eol];

        if (line.len > key.len + 1 and starts(line, key) and line[key.len] == ' ') {
            return line[key.len + 1 ..];
        }
        i = eol + 1;
    }
    return null;
}

fn starts(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    for (prefix, 0..) |c, i| {
        if (s[i] != c) return false;
    }
    return true;
}

fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\n' or s[start] == '\r')) : (start += 1) {}
    var end: usize = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\n' or s[end - 1] == '\r')) : (end -= 1) {}
    return s[start..end];
}

/// Read a file into the provided buffer. Returns the data slice or null.
fn readFileBuf(path: []const u8, buf: []u8) ?[]const u8 {
    const fd = fx.open(path);
    if (fd < 0) return null;
    defer _ = fx.close(fd);

    var total: usize = 0;
    while (total < buf.len) {
        const n = fx.read(fd, buf[total..]);
        if (n <= 0) break;
        total += @intCast(n);
    }
    if (total == 0) return null;
    return buf[0..total];
}

/// Read a small file as a string (using io_buf). Returns null if failed.
fn readFileStr(path: []const u8) ?[]const u8 {
    return readFileBuf(path, &io_buf);
}

fn cmdBuild(argc: u64, argv: []const [*:0]const u8) void {
    // Parse flags: -f <Containerfile> -t <tag> [context_dir]
    var cf_path: ?[]const u8 = null;
    var tag: ?[]const u8 = null;
    var context_dir: []const u8 = "/";
    var arg_idx: u64 = 2; // skip "fnx" "build"

    while (arg_idx < argc) {
        const a = cstr(argv[arg_idx]);
        if (sliceEql(a, "-f")) {
            arg_idx += 1;
            if (arg_idx >= argc) {
                stderr.puts("fnx build: -f requires an argument\n");
                fx.exit(1);
            }
            cf_path = cstr(argv[arg_idx]);
        } else if (sliceEql(a, "-t")) {
            arg_idx += 1;
            if (arg_idx >= argc) {
                stderr.puts("fnx build: -t requires an argument\n");
                fx.exit(1);
            }
            tag = cstr(argv[arg_idx]);
        } else if (a.len > 0 and a[0] == '-') {
            stderr.puts("fnx build: unknown flag '");
            stderr.puts(a);
            stderr.puts("'\n");
            fx.exit(1);
        } else {
            context_dir = a;
        }
        arg_idx += 1;
    }

    if (tag == null) {
        stderr.puts("fnx build: -t <tag> is required\n");
        fx.exit(1);
    }
    const tag_name = tag.?;

    // Determine Containerfile path
    var default_cf: [256]u8 = undefined;
    const cf = cf_path orelse blk: {
        const len = fmtPath(&default_cf, context_dir, "/Containerfile", "");
        break :blk default_cf[0..len];
    };

    // Read Containerfile into dedicated buffer (keeps slices valid during processing)
    const source = readFileBuf(cf, &cf_source_buf) orelse {
        stderr.puts("fnx build: cannot read ");
        stderr.puts(cf);
        stderr.puts("\n");
        fx.exit(1);
    };

    // Parse instructions
    var instructions: [128]fx.containerfile.Instruction = undefined;
    const count = fx.containerfile.parse(source, &instructions);
    if (count == 0) {
        stderr.puts("fnx build: no instructions in Containerfile\n");
        fx.exit(1);
    }

    // Create image directory
    _ = fx.mkdir("/var/lib");
    _ = fx.mkdir("/var/lib/fnx");
    _ = fx.mkdir("/var/lib/fnx/images");
    var img_dir: [256]u8 = undefined;
    const img_dir_len = fmtPath(&img_dir, "/var/lib/fnx/images/", tag_name, "");
    _ = fx.mkdir(img_dir[0..img_dir_len]);

    var rootfs: [256]u8 = undefined;
    const rootfs_len = fmtPath(&rootfs, img_dir[0..img_dir_len], "/rootfs", "");
    _ = fx.mkdir(rootfs[0..rootfs_len]);
    const rootfs_path = rootfs[0..rootfs_len];

    // Track config values
    var cmd_val: [256]u8 = undefined;
    var cmd_len: usize = 0;
    var compat_linux = false;

    // Process each instruction
    for (instructions[0..count]) |inst| {
        switch (inst.kind) {
            .from => {
                const base = trim(inst.args);
                if (!sliceEql(base, "scratch")) {
                    // Check base image compat
                    var compat_path: [256]u8 = undefined;
                    const cplen = fmtPath(&compat_path, "/var/lib/fnx/images/", base, "/compat");
                    if (readFileBuf(compat_path[0..cplen], &io_buf)) |data| {
                        if (starts(trim(data), "linux")) compat_linux = true;
                    }
                    // Copy base image rootfs
                    var base_rootfs: [256]u8 = undefined;
                    const blen = fmtPath(&base_rootfs, "/var/lib/fnx/images/", base, "/rootfs");
                    copyTree(base_rootfs[0..blen], rootfs_path);
                }
                out.puts("FROM ");
                out.puts(base);
                out.puts("\n");
            },
            .copy => {
                buildCopy(inst.args, context_dir, rootfs_path);
            },
            .run => {
                buildRun(inst.args, rootfs_path, compat_linux);
            },
            .cmd => {
                const val = fx.containerfile.parseJsonArray(inst.args);
                @memcpy(cmd_val[0..val.len], val);
                cmd_len = val.len;
            },
            .entrypoint => {
                const val = fx.containerfile.parseJsonArray(inst.args);
                @memcpy(cmd_val[0..val.len], val);
                cmd_len = val.len;
            },
            .workdir => {
                var wd: [512]u8 = undefined;
                const wlen = fmtPath(&wd, rootfs_path, "/", trim(inst.args));
                _ = fx.mkdir(wd[0..wlen]);
                out.puts("WORKDIR ");
                out.puts(trim(inst.args));
                out.puts("\n");
            },
            .env, .expose, .label, .add, .user => {},
        }
    }

    // Write config file (default command)
    if (cmd_len > 0) {
        var config_path: [256]u8 = undefined;
        const clen = fmtPath(&config_path, img_dir[0..img_dir_len], "/config", "");
        const cfd = fx.create(config_path[0..clen], 0);
        if (cfd >= 0) {
            _ = fx.write(cfd, cmd_val[0..cmd_len]);
            _ = fx.close(cfd);
        }
    }

    // Write compat file if linux
    if (compat_linux) {
        var compat_path: [256]u8 = undefined;
        const cplen = fmtPath(&compat_path, img_dir[0..img_dir_len], "/compat", "");
        const cfd = fx.create(compat_path[0..cplen], 0);
        if (cfd >= 0) {
            _ = fx.write(cfd, "linux");
            _ = fx.close(cfd);
        }
    }

    out.puts("Successfully built image '");
    out.puts(tag_name);
    out.puts("'\n");
}

/// Create parent directories of a path, starting from `start_pos` in the path.
fn mkdirParents(path: []const u8, start_pos: usize) void {
    var i: usize = start_pos + 1;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/') {
            var dir: [512]u8 = undefined;
            @memcpy(dir[0..i], path[0..i]);
            _ = fx.mkdir(dir[0..i]);
        }
    }
}

fn buildCopy(args: []const u8, context: []const u8, rootfs: []const u8) void {
    // Parse "src dest" from COPY args
    var i: usize = 0;
    // Skip any flags like --chown=...
    while (i < args.len and args[i] == '-') {
        while (i < args.len and args[i] != ' ' and args[i] != '\t') : (i += 1) {}
        while (i < args.len and (args[i] == ' ' or args[i] == '\t')) : (i += 1) {}
    }

    const src_start = i;
    while (i < args.len and args[i] != ' ' and args[i] != '\t') : (i += 1) {}
    if (i <= src_start) return;
    const src_name = args[src_start..i];

    while (i < args.len and (args[i] == ' ' or args[i] == '\t')) : (i += 1) {}
    const dest_name = trim(args[i..]);
    if (dest_name.len == 0) return;

    // Build full source path: context/src
    var full_src: [512]u8 = undefined;
    const src_len = fmtPath(&full_src, context, "/", src_name);

    // Build full dest path: rootfs + dest (avoid double slash)
    var full_dst: [512]u8 = undefined;
    const sep: []const u8 = if (dest_name.len > 0 and dest_name[0] == '/') "" else "/";
    const dst_len = fmtPath(&full_dst, rootfs, sep, dest_name);

    // Ensure parent directories exist in the rootfs
    mkdirParents(full_dst[0..dst_len], rootfs.len);

    copyFile(full_src[0..src_len], full_dst[0..dst_len]);
    out.puts("COPY ");
    out.puts(src_name);
    out.puts(" ");
    out.puts(dest_name);
    out.puts("\n");
}

fn buildRun(cmd: []const u8, rootfs: []const u8, compat_linux: bool) void {
    out.puts("RUN ");
    out.puts(cmd);
    out.puts("\n");

    // Create temp container for RUN execution
    const id = cloneContainer() orelse {
        stderr.puts("fnx build: failed to create container for RUN\n");
        return;
    };

    writeCtl(id, "name ", "build-tmp");
    writeCtl(id, "rootfs ", rootfs);
    if (compat_linux) {
        writeCtl(id, "compat ", "linux");
    }

    // Find a shell in the rootfs
    var shell_path: [512]u8 = undefined;
    var shell_name: []const u8 = "/bin/sh";
    var sp_len = fmtPath(&shell_path, rootfs, "/bin/sh", "");
    var shell_fd = fx.open(shell_path[0..sp_len]);
    if (shell_fd < 0) {
        sp_len = fmtPath(&shell_path, rootfs, "/bin/fsh", "");
        shell_fd = fx.open(shell_path[0..sp_len]);
        shell_name = "/bin/fsh";
    }
    if (shell_fd < 0) {
        stderr.puts("fnx build: no shell found in rootfs for RUN\n");
        ctlById(id, "destroy");
        return;
    }
    _ = fx.close(shell_fd);

    // Read shell ELF
    const shell_elf = readFileBuf(shell_path[0..sp_len], &elf_buf) orelse {
        stderr.puts("fnx build: failed to read shell binary\n");
        ctlById(id, "destroy");
        return;
    };

    // Build argv: [shell, "-c", cmd]
    var run_args: [3][]const u8 = .{ shell_name, "-c", cmd };
    const run_argv = fx.buildArgvBlock(&argv_buf, &run_args);

    // Start temp container
    const pid = fx.cntr_start(id, shell_elf, run_argv);
    if (pid < 0) {
        stderr.puts("fnx build: RUN failed to start\n");
        ctlById(id, "destroy");
        return;
    }

    // Wait for completion
    _ = fx.wait(@intCast(pid));

    // Destroy temp container
    ctlById(id, "destroy");
}

fn copyTree(src: []const u8, dst: []const u8) void {
    _ = fx.mkdir(dst);

    const fd = fx.open(src);
    if (fd < 0) return;
    // Use stack buffer for directory entries (4 KB = ~56 entries)
    var entries: [4096]u8 = undefined;
    const n = fx.read(fd, &entries);
    _ = fx.close(fd);
    if (n <= 0) return;

    const entry_size: usize = 72; // DirEntry: 64-byte name + 4-byte file_type + 4-byte size
    var off: usize = 0;
    const bytes: usize = @intCast(n);

    while (off + entry_size <= bytes) : (off += entry_size) {
        const name_bytes = entries[off..][0..64];
        var name_len: usize = 0;
        while (name_len < 64 and name_bytes[name_len] != 0) : (name_len += 1) {}
        if (name_len == 0) continue;
        const name = name_bytes[0..name_len];
        if (sliceEql(name, ".") or sliceEql(name, "..")) continue;

        // file_type at offset 64 (little-endian u32): 0=file, 1=directory
        const ft: u32 = @as(u32, entries[off + 64]) |
            (@as(u32, entries[off + 65]) << 8) |
            (@as(u32, entries[off + 66]) << 16) |
            (@as(u32, entries[off + 67]) << 24);

        var child_src: [512]u8 = undefined;
        const cs_len = fmtPath(&child_src, src, "/", name);
        var child_dst: [512]u8 = undefined;
        const cd_len = fmtPath(&child_dst, dst, "/", name);

        if (ft == 1) {
            copyTree(child_src[0..cs_len], child_dst[0..cd_len]);
        } else {
            copyFile(child_src[0..cs_len], child_dst[0..cd_len]);
        }
    }
}

fn copyFile(src: []const u8, dst: []const u8) void {
    const in_fd = fx.open(src);
    if (in_fd < 0) return;

    const out_fd = fx.create(dst, 0);
    if (out_fd < 0) {
        _ = fx.close(in_fd);
        return;
    }

    // Copy permissions
    var st: fx.Stat = undefined;
    _ = fx.stat(in_fd, &st);

    // Copy file data using elf_buf as transfer buffer
    while (true) {
        const nr = fx.read(in_fd, &elf_buf);
        if (nr <= 0) break;
        var written: usize = 0;
        const total: usize = @intCast(nr);
        while (written < total) {
            const w = fx.write(out_fd, elf_buf[written..total]);
            if (w <= 0) break;
            written += @intCast(w);
        }
    }

    _ = fx.wstat(out_fd, @intCast(st.mode & 0o7777), st.uid, st.gid, fx.WSTAT_MODE | fx.WSTAT_UID | fx.WSTAT_GID);
    _ = fx.close(out_fd);
    _ = fx.close(in_fd);
}
