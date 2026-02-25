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
///   pull <image[:tag]>    Pull image from OCI registry
///   import <tar> <name>   Import a tarball as an image
///   cp <src> <cntr:dest>  Copy file into container rootfs
const fx = @import("fornax");
const fnx_options = @import("fnx_options");
const has_tls = fnx_options.has_tls;
const tls = if (has_tls) @import("tls") else struct {};

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

// --- Pull command BSS buffers ---
const http = fx.http;
const deflate = fx.deflate;
const tar = fx.tar;
const json = fx.json;

var sliding_window: [32768]u8 linksection(".bss") = undefined;
var inflate_out_buf: [8192]u8 linksection(".bss") = undefined;
var manifest_buf: [32768]u8 linksection(".bss") = undefined;
var header_buf: [8192]u8 linksection(".bss") = undefined;
var pull_io_buf: [4096]u8 linksection(".bss") = undefined;
var path_scratch: [512]u8 linksection(".bss") = undefined;

// --- Auth token BSS buffers ---
var auth_token_buf: [4096]u8 linksection(".bss") = undefined;
var auth_token_len: usize = 0;
var auth_value_buf: [4112]u8 linksection(".bss") = undefined; // "Bearer " + token
var auth_value_len: usize = 0;
var combined_hdrs: [12]http.HeaderEntry = undefined;

// --- Persistent connection state for registry requests ---
var persistent_conn: http.Connection = .{
    .data_fd = -1,
    .ctl_fd = -1,
    .conn_num = &.{},
    .conn_num_buf = undefined,
    .conn_num_len = 0,
    .io = null,
};
var persistent_active: bool = false;
var persistent_host_buf: [128]u8 linksection(".bss") = undefined;
var persistent_host_len: usize = 0;
var persistent_port: u16 = 0;

// --- TLS support (always enabled on x86_64) ---
const TlsSupport = if (has_tls) struct {
    const T = @import("tls");

    pub var conn: T.TlsConnection linksection(".bss") = undefined;
    pub var pem_buf: [262144]u8 linksection(".bss") = undefined; // 256 KB for PEM file
    pub var ta_data: [131072]u8 linksection(".bss") = undefined; // 128 KB for DN + key data
    pub var anchors: [200]T.TrustAnchor linksection(".bss") = undefined;
    pub var anchor_count: usize = 0;
    pub var initialized: bool = false;
    pub var server_name_buf: [256]u8 = undefined;

    /// Load trust anchors from /etc/ssl/certs/ca-certificates.crt.
    pub fn init() bool {
        if (initialized) return anchor_count > 0;
        initialized = true;

        const fd = fx.open("/etc/ssl/certs/ca-certificates.crt");
        if (fd < 0) {
            stderr.puts("fnx: cannot open /etc/ssl/certs/ca-certificates.crt\n");
            return false;
        }

        // Read PEM file
        var pem_len: usize = 0;
        while (pem_len < pem_buf.len) {
            const n = fx.read(fd, pem_buf[pem_len..]);
            if (n <= 0) break;
            pem_len += @intCast(n);
        }
        _ = fx.close(fd);

        if (pem_len == 0) {
            stderr.puts("fnx: empty CA bundle\n");
            return false;
        }

        // Parse PEM → trust anchors
        var der_buf: [32768]u8 = undefined; // scratch for DER decoding
        if (T.loadTrustAnchors(
            pem_buf[0..pem_len],
            &der_buf,
            &ta_data,
            &anchors,
        )) |count| {
            anchor_count = count;
            stderr.print("fnx: loaded {d} CA certificates\n", .{count});
            return true;
        }

        stderr.puts("fnx: failed to parse CA certificates\n");
        return false;
    }

    /// http.RequestOptions on_connect callback for TLS.
    pub fn onConnect(data_fd: i32, host: []const u8) ?http.IoFns {
        // Copy host to null-terminated buffer for BearSSL SNI
        if (host.len >= server_name_buf.len) return null;
        @memcpy(server_name_buf[0..host.len], host);
        server_name_buf[host.len] = 0;
        const sname: [*:0]const u8 = @ptrCast(&server_name_buf);

        if (!conn.initInPlace(
            data_fd,
            sname,
            &anchors,
            anchor_count,
        )) {
            stderr.puts("fnx: TLS handshake failed\n");
            return null;
        }

        return conn.ioFns();
    }
} else struct {};

/// Build RequestOptions with TLS on_connect callback if the ImageRef needs TLS.
fn makeOpts(extra_headers: []const http.HeaderEntry, use_tls_for_request: bool) http.RequestOptions {
    var count: usize = 0;

    // Add auth header if token is present
    if (auth_token_len > 0) {
        combined_hdrs[count] = .{ .name = "Authorization", .value = auth_value_buf[0..auth_value_len] };
        count += 1;
    }

    // Copy caller's extra headers
    for (extra_headers) |h| {
        if (count < combined_hdrs.len) {
            combined_hdrs[count] = h;
            count += 1;
        }
    }

    var opts = http.RequestOptions{ .headers = combined_hdrs[0..count] };
    if (has_tls and use_tls_for_request) {
        opts.on_connect = &TlsSupport.onConnect;
    }
    return opts;
}

/// Initialize TLS if needed for this image ref. Returns true if ready (or not needed).
fn ensureTls(ref: *const ImageRef) bool {
    if (!has_tls) return !ref.use_tls;
    if (!ref.use_tls) return true;
    return TlsSupport.init();
}

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
    } else if (strEql(cmd_cstr, "pull")) {
        if (argc < 3) {
            stderr.puts("Usage: fnx pull <image[:tag]>\n");
            fx.exit(1);
        }
        cmdPull(cstr(argv[2]));
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
    out.puts("  pull <image[:tag]>      Pull image from OCI registry\n");
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

fn parseU64(s: []const u8) u64 {
    if (s.len == 0) return 0;
    var val: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        val = val * 10 + (c - '0');
    }
    return val;
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

// --- OCI Registry Pull ---

const MAX_LAYERS = 32;

const ImageRef = struct {
    registry_host: []const u8, // "10.0.2.2" or "myregistry.local"
    registry_port: u16, // 5000
    name: []const u8, // "library/alpine" or "myapp"
    tag: []const u8, // "latest"
    use_tls: bool, // true for HTTPS registries (port 443)
};

/// Parse image reference: [registry:port/]name[:tag]
/// Heuristic: if part before first '/' contains ':' or '.', it's a registry host.
fn parseImageRef(ref: []const u8) ImageRef {
    const S = struct {
        var library_name_buf: [256]u8 = undefined;
    };

    // Split on ':'  for tag (last colon after last '/')
    var tag_start: usize = ref.len;
    var last_slash: usize = ref.len;
    for (0..ref.len) |i| {
        if (ref[i] == '/') last_slash = i;
    }
    // Look for ':' after last slash (that's the tag separator)
    var i: usize = if (last_slash < ref.len) last_slash else 0;
    while (i < ref.len) : (i += 1) {
        if (ref[i] == ':') tag_start = i;
    }

    const tag = if (tag_start < ref.len) ref[tag_start + 1 ..] else "latest";
    const name_with_registry = ref[0..tag_start];

    // Find first '/'
    var first_slash: usize = name_with_registry.len;
    for (0..name_with_registry.len) |j| {
        if (name_with_registry[j] == '/') {
            first_slash = j;
            break;
        }
    }

    // Check if part before first '/' looks like a registry (contains ':' or '.')
    if (first_slash < name_with_registry.len) {
        const maybe_host = name_with_registry[0..first_slash];
        var has_registry_chars = false;
        for (maybe_host) |c| {
            if (c == ':' or c == '.') {
                has_registry_chars = true;
                break;
            }
        }
        if (has_registry_chars) {
            // Split registry host:port
            var colon: usize = maybe_host.len;
            for (0..maybe_host.len) |k| {
                if (maybe_host[k] == ':') {
                    colon = k;
                    break;
                }
            }
            var host = maybe_host[0..colon];
            var port: u16 = if (colon < maybe_host.len) parsePort(maybe_host[colon + 1 ..]) else 443;
            if (port == 0) port = 443;
            var name = name_with_registry[first_slash + 1 ..];

            // Docker Hub shorthand: docker.io → registry-1.docker.io
            if (sliceEql(host, "docker.io") or sliceEql(host, "index.docker.io")) {
                host = "registry-1.docker.io";
                port = 443;

                // Add "library/" prefix for single-name images (e.g. "alpine" → "library/alpine")
                var has_slash_in_name = false;
                for (name) |c| {
                    if (c == '/') {
                        has_slash_in_name = true;
                        break;
                    }
                }
                if (!has_slash_in_name and name.len > 0) {
                    const prefix = "library/";
                    if (prefix.len + name.len <= S.library_name_buf.len) {
                        @memcpy(S.library_name_buf[0..prefix.len], prefix);
                        @memcpy(S.library_name_buf[prefix.len..][0..name.len], name);
                        name = S.library_name_buf[0 .. prefix.len + name.len];
                    }
                }
            }

            return .{
                .registry_host = host,
                .registry_port = port,
                .name = name,
                .tag = tag,
                .use_tls = port == 443,
            };
        }
    }

    // No registry specified — use default, add "library/" prefix if no slash
    const name = if (first_slash >= name_with_registry.len) name_with_registry else name_with_registry;
    return .{
        .registry_host = "10.0.2.2",
        .registry_port = 5000,
        .name = name,
        .tag = tag,
        .use_tls = false,
    };
}

fn parsePort(s: []const u8) u16 {
    var val: u16 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        val = val * 10 + @as(u16, c - '0');
    }
    return if (val == 0) 5000 else val;
}

/// Build API path: /v2/<name>/<suffix> into buf
fn buildApiPath(buf: []u8, name: []const u8, suffix: []const u8) []const u8 {
    var pos: usize = 0;
    const prefix = "/v2/";
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    @memcpy(buf[pos..][0..name.len], name);
    pos += name.len;
    @memcpy(buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;
    return buf[0..pos];
}

/// Build registry host:port string for display
fn fmtRegistry(buf: []u8, host: []const u8, port: u16) []const u8 {
    var pos: usize = 0;
    @memcpy(buf[pos..][0..host.len], host);
    pos += host.len;
    buf[pos] = ':';
    pos += 1;
    pos += fmtU16(buf[pos..], port);
    return buf[0..pos];
}

fn fmtU16(buf: []u8, val: u16) usize {
    var tmp: [5]u8 = undefined;
    var len: usize = 0;
    var v = val;
    if (v == 0) {
        buf[0] = '0';
        return 1;
    }
    while (v > 0) : (v /= 10) {
        tmp[len] = @intCast('0' + (v % 10));
        len += 1;
    }
    for (0..len) |fi| {
        buf[fi] = tmp[len - 1 - fi];
    }
    return len;
}

/// HTTP reader context for streaming through deflate.
const HttpReaderCtx = struct {
    resp: *http.Response,
};

fn httpReadFn(ctx_ptr: *anyopaque, buf: []u8) isize {
    const ctx: *HttpReaderCtx = @ptrCast(@alignCast(ctx_ptr));
    return ctx.resp.readBody(buf);
}

/// Gzip reader that decompresses HTTP body into tar blocks.
const HttpGzipReader = struct {
    bit_reader: deflate.BitReader,
    inflater: deflate.Inflater,

    fn init(ctx: *HttpReaderCtx) HttpGzipReader {
        return .{
            .bit_reader = deflate.BitReader.init(&httpReadFn, @ptrCast(ctx), &pull_io_buf),
            .inflater = deflate.Inflater.init(&sliding_window, &inflate_out_buf),
        };
    }

    fn skipGzipHeader(self: *HttpGzipReader) bool {
        return deflate.skipGzipHeader(&self.bit_reader);
    }

    fn readBlock(self: *HttpGzipReader, dest: *[tar.HEADER_SIZE]u8) bool {
        var pos: usize = 0;
        while (pos < tar.HEADER_SIZE) {
            if (self.inflater.done) break;
            const n = self.inflater.readBytes(&self.bit_reader, dest[pos..]);
            if (n == 0) break;
            pos += n;
        }
        if (pos == 0) return false;
        if (pos < tar.HEADER_SIZE) {
            @memset(dest[pos..], 0);
        }
        return true;
    }
};

/// Extract a gzipped tar layer from an HTTP response into rootfs_path.
fn extractLayer(resp: *http.Response, rootfs_path: []const u8) bool {
    var ctx = HttpReaderCtx{ .resp = resp };
    var gz = HttpGzipReader.init(&ctx);

    if (!gz.skipGzipHeader()) {
        stderr.puts("fnx: invalid gzip header in layer\n");
        return false;
    }

    var zero_blocks: u32 = 0;
    var header: [tar.HEADER_SIZE]u8 = undefined;
    while (true) {
        if (!gz.readBlock(&header)) break;
        if (tar.isZeroBlock(&header)) {
            zero_blocks += 1;
            if (zero_blocks >= 2) break;
            continue;
        }
        zero_blocks = 0;
        extractEntry(&header, &gz, rootfs_path);
    }
    return true;
}

fn extractEntry(header_raw: *[tar.HEADER_SIZE]u8, gz: *HttpGzipReader, rootfs_path: []const u8) void {
    const hdr = tar.Header{ .raw = header_raw };

    if (!hdr.validateChecksum()) return;

    const name = hdr.name(&path_scratch);
    const size = hdr.size();
    const mode_val = hdr.mode();
    const uid_val = hdr.uid();
    const gid_val = hdr.gid();
    const typeflag = hdr.typeflag();

    if (!tar.isSafePath(name)) {
        if (size > 0 and (typeflag == '0' or typeflag == 0)) {
            skipGzBlocks(gz, size);
        }
        return;
    }

    // Build full path: rootfs_path + "/" + name
    var full_path: [512]u8 = undefined;
    var fpos: usize = 0;
    @memcpy(full_path[fpos..][0..rootfs_path.len], rootfs_path);
    fpos += rootfs_path.len;
    full_path[fpos] = '/';
    fpos += 1;
    // Strip leading "./" from tar names
    var clean_name = name;
    if (clean_name.len >= 2 and clean_name[0] == '.' and clean_name[1] == '/') {
        clean_name = clean_name[2..];
    }
    // Strip leading "/"
    while (clean_name.len > 0 and clean_name[0] == '/') {
        clean_name = clean_name[1..];
    }
    if (clean_name.len == 0) {
        if (size > 0 and (typeflag == '0' or typeflag == 0)) {
            skipGzBlocks(gz, size);
        }
        return;
    }
    if (fpos + clean_name.len > full_path.len) {
        if (size > 0 and (typeflag == '0' or typeflag == 0)) {
            skipGzBlocks(gz, size);
        }
        return;
    }
    @memcpy(full_path[fpos..][0..clean_name.len], clean_name);
    fpos += clean_name.len;
    const fpath = full_path[0..fpos];

    if (typeflag == '5') {
        // Directory
        pullEnsureParentDirs(fpath);
        var n_len = fpath.len;
        while (n_len > 0 and fpath[n_len - 1] == '/') n_len -= 1;
        if (n_len > 0) {
            _ = fx.mkdir(fpath[0..n_len]);
        }
    } else if (typeflag == '0' or typeflag == 0) {
        // Regular file
        pullEnsureParentDirs(fpath);
        const out_fd = fx.create(fpath, 0);
        if (out_fd < 0) {
            skipGzBlocks(gz, size);
            return;
        }

        var remaining: u64 = size;
        const blocks = (size + tar.HEADER_SIZE - 1) / tar.HEADER_SIZE;
        var block_i: u64 = 0;
        while (block_i < blocks) : (block_i += 1) {
            var block: [tar.HEADER_SIZE]u8 = undefined;
            if (!gz.readBlock(&block)) break;
            const to_write: usize = @intCast(@min(remaining, tar.HEADER_SIZE));
            _ = fx.syscall.write(out_fd, block[0..to_write]);
            remaining -= to_write;
        }

        _ = fx.wstat(out_fd, @intCast(mode_val & 0o7777), @intCast(uid_val), @intCast(gid_val), fx.WSTAT_MODE | fx.WSTAT_UID | fx.WSTAT_GID);
        _ = fx.close(out_fd);
    } else {
        // Symlinks, hardlinks, etc — skip data
        if (size > 0) {
            skipGzBlocks(gz, size);
        }
    }
}

fn skipGzBlocks(gz: *HttpGzipReader, size: u64) void {
    const blocks = (size + tar.HEADER_SIZE - 1) / tar.HEADER_SIZE;
    var block: [tar.HEADER_SIZE]u8 = undefined;
    var bi: u64 = 0;
    while (bi < blocks) : (bi += 1) {
        _ = gz.readBlock(&block);
    }
}

fn pullEnsureParentDirs(fpath: []const u8) void {
    var dir_buf: [512]u8 = undefined;
    var pi: usize = 0;
    while (pi < fpath.len) : (pi += 1) {
        if (fpath[pi] == '/' and pi > 0) {
            if (pi <= dir_buf.len) {
                @memcpy(dir_buf[0..pi], fpath[0..pi]);
                _ = fx.mkdir(dir_buf[0..pi]);
            }
        }
    }
}

/// Fetch a blob and read body into buf. Returns slice or null.
fn fetchBlob(ref: *const ImageRef, digest: []const u8, buf: []u8) ?[]const u8 {
    // Build path: /v2/<name>/blobs/<digest>
    var api_path: [512]u8 = undefined;
    var pos: usize = 0;
    const p1 = "/v2/";
    @memcpy(api_path[pos..][0..p1.len], p1);
    pos += p1.len;
    @memcpy(api_path[pos..][0..ref.name.len], ref.name);
    pos += ref.name.len;
    const p2 = "/blobs/";
    @memcpy(api_path[pos..][0..p2.len], p2);
    pos += p2.len;
    @memcpy(api_path[pos..][0..digest.len], digest);
    pos += digest.len;

    const accept_hdr = [_]http.HeaderEntry{
        .{ .name = "Accept", .value = "*/*" },
    };

    var rr = registryRequest(ref.registry_host, ref.registry_port, "GET", api_path[0..pos], &accept_hdr, ref.use_tls) orelse return null;

    if (rr.resp.status_code >= 300 and rr.resp.status_code < 400) {
        // Redirect (e.g. Docker Hub 307 to CDN) — persistent conn can't follow
        // cross-domain redirects. Drain body, fall back to http.request() with
        // redirect handling.
        if (!rr.resp.drainAndReady()) closePersistent();

        const opts = makeOpts(&accept_hdr, ref.use_tls);
        var result = http.request(ref.registry_host, ref.registry_port, "GET", api_path[0..pos], opts, &header_buf) orelse return null;
        defer result.conn.close();

        if (result.resp.status_code < 200 or result.resp.status_code >= 300) return null;

        var total: usize = 0;
        while (total < buf.len) {
            const n = result.resp.readBody(buf[total..]);
            if (n <= 0) break;
            total += @intCast(n);
        }
        if (total == 0) return null;
        return buf[0..total];
    }

    if (rr.resp.status_code < 200 or rr.resp.status_code >= 300) {
        if (!rr.resp.drainAndReady()) closePersistent();
        return null;
    }

    var total: usize = 0;
    while (total < buf.len) {
        const n = rr.resp.readBody(buf[total..]);
        if (n <= 0) break;
        total += @intCast(n);
    }

    // Body fully read — check if connection is reusable
    if (!rr.resp.drainAndReady()) closePersistent();

    if (total == 0) return null;
    return buf[0..total];
}

/// Parse OCI config JSON to extract Entrypoint + Cmd.
/// Returns command string or null.
fn parseOciConfig(config_json: []const u8, cmd_buf: []u8) ?[]const u8 {
    var parser = json.Parser.init(config_json);

    // Find top-level "config" key
    var tok = parser.next();
    if (tok.kind != .object_begin) return null;
    if (!parser.findKey("config")) return null;

    // Now inside config object
    tok = parser.next();
    if (tok.kind != .object_begin) return null;

    // Try Entrypoint first, then Cmd
    var cmd_pos: usize = 0;

    // Look for Entrypoint
    const saved_pos = parser.pos;
    if (parser.findKey("Entrypoint")) {
        cmd_pos = parseJsonArrayConcat(&parser, cmd_buf, cmd_pos);
    }

    // Look for Cmd (reset won't work simply, but Cmd often follows Entrypoint)
    // Try from current position
    if (parser.findKey("Cmd")) {
        cmd_pos = parseJsonArrayConcat(&parser, cmd_buf, cmd_pos);
    } else {
        // Restart from saved position to find Cmd before Entrypoint
        parser.pos = saved_pos;
        if (parser.findKey("Cmd")) {
            cmd_pos = parseJsonArrayConcat(&parser, cmd_buf, cmd_pos);
        }
    }

    if (cmd_pos == 0) return null;
    return cmd_buf[0..cmd_pos];
}

fn skipWs(parser: *json.Parser) void {
    while (parser.pos < parser.src.len) {
        switch (parser.src[parser.pos]) {
            ' ', '\t', '\n', '\r' => parser.pos += 1,
            else => return,
        }
    }
}

/// Parse a JSON array of strings and concatenate with spaces.
fn parseJsonArrayConcat(parser: *json.Parser, buf: []u8, start_pos: usize) usize {
    var pos = start_pos;
    const tok = parser.next();
    if (tok.kind == .null_val) return pos;
    if (tok.kind != .array_begin) return pos;

    var first = pos == 0;
    while (true) {
        skipWs(parser);
        if (parser.pos < parser.src.len and parser.src[parser.pos] == ']') {
            parser.pos += 1;
            break;
        }
        if (!first and pos > start_pos) {
            // Comma between elements
            const comma = parser.next();
            if (comma.kind != .comma) break;
        }
        const elem = parser.next();
        if (elem.kind != .string) break;

        if (pos > 0 and !first) {
            if (pos < buf.len) {
                buf[pos] = ' ';
                pos += 1;
            }
        }
        first = false;
        const val = elem.str_value;
        if (pos + val.len <= buf.len) {
            @memcpy(buf[pos..][0..val.len], val);
            pos += val.len;
        }
    }
    return pos;
}

/// Accept header for manifest requests — covers all common formats.
const MANIFEST_ACCEPT = "application/vnd.docker.distribution.manifest.v2+json, " ++
    "application/vnd.oci.image.manifest.v1+json, " ++
    "application/vnd.docker.distribution.manifest.list.v2+json, " ++
    "application/vnd.oci.image.index.v1+json";

/// Fetch manifest, resolving manifest lists to the amd64/linux platform manifest.
/// Returns the manifest JSON as a slice into `buf`. Exits on error.
fn fetchManifest(api_path_buf: []u8, ref: *const ImageRef, buf: []u8) []const u8 {
    const data = fetchManifestOnce(api_path_buf, ref, ref.tag, buf);

    // Check if this is a manifest list (contains "manifests" array)
    if (isManifestList(data)) {
        // Find amd64/linux platform digest
        const digest = findPlatformDigest(data) orelse {
            stderr.puts("fnx: no amd64/linux manifest in manifest list\n");
            fx.exit(1);
        };

        stderr.puts("Resolving manifest list -> amd64/linux\n");

        // Re-fetch using the platform-specific digest
        return fetchManifestOnce(api_path_buf, ref, digest, buf);
    }

    return data;
}

fn fetchManifestOnce(api_path_buf: []u8, ref: *const ImageRef, reference: []const u8, buf: []u8) []const u8 {
    var suf_buf: [256]u8 = undefined;
    var spos: usize = 0;
    const s1 = "/manifests/";
    @memcpy(suf_buf[spos..][0..s1.len], s1);
    spos += s1.len;
    @memcpy(suf_buf[spos..][0..reference.len], reference);
    spos += reference.len;

    const path = buildApiPath(api_path_buf, ref.name, suf_buf[0..spos]);

    const accept_hdr = [_]http.HeaderEntry{
        .{ .name = "Accept", .value = MANIFEST_ACCEPT },
    };

    var rr = registryRequest(ref.registry_host, ref.registry_port, "GET", path, &accept_hdr, ref.use_tls) orelse {
        stderr.puts("fnx: failed to fetch manifest\n");
        fx.exit(1);
    };

    if (rr.resp.status_code == 404) {
        if (!rr.resp.drainAndReady()) closePersistent();
        stderr.puts("fnx: image not found: ");
        stderr.puts(ref.name);
        stderr.puts(":");
        stderr.puts(reference);
        stderr.puts("\n");
        fx.exit(1);
    }
    if (rr.resp.status_code < 200 or rr.resp.status_code >= 300) {
        if (!rr.resp.drainAndReady()) closePersistent();
        stderr.puts("fnx: registry returned status ");
        stderr.print("{d}", .{rr.resp.status_code});
        stderr.puts(" for manifest\n");
        fx.exit(1);
    }

    var total: usize = 0;
    while (total < buf.len) {
        const n = rr.resp.readBody(buf[total..]);
        if (n <= 0) break;
        total += @intCast(n);
    }

    // Body fully read — check if connection is reusable
    if (!rr.resp.drainAndReady()) closePersistent();

    if (total == 0) {
        stderr.puts("fnx: empty manifest\n");
        fx.exit(1);
    }
    return buf[0..total];
}

/// Check if JSON contains a "manifests" key (= manifest list / OCI index).
fn isManifestList(data: []const u8) bool {
    // Quick substring scan — "manifests" only appears in list/index types
    var i: usize = 0;
    const needle = "\"manifests\"";
    while (i + needle.len <= data.len) : (i += 1) {
        if (data[i] == needle[0]) {
            var match = true;
            for (0..needle.len) |j| {
                if (data[i + j] != needle[j]) {
                    match = false;
                    break;
                }
            }
            if (match) return true;
        }
    }
    return false;
}

/// Find the digest of the amd64/linux platform in a manifest list.
/// Returns the digest string (slice into manifest data) or null.
/// Uses two passes per entry to handle arbitrary key order.
fn findPlatformDigest(data: []const u8) ?[]const u8 {
    var parser = json.Parser.init(data);
    var tok = parser.next();
    if (tok.kind != .object_begin) return null;

    if (!parser.findKey("manifests")) return null;
    tok = parser.next();
    if (tok.kind != .array_begin) return null;

    // Iterate manifest entries
    var first = true;
    while (true) {
        skipWs(&parser);
        if (parser.pos < parser.src.len and parser.src[parser.pos] == ']') break;

        if (!first) {
            const comma = parser.next();
            if (comma.kind != .comma) break;
        }
        first = false;

        // Each entry is an object — save position for two-pass scan
        tok = parser.next();
        if (tok.kind != .object_begin) break;

        const entry_start = parser.pos;

        // Pass 1: check platform
        var is_amd64_linux = false;
        if (parser.findKey("platform")) {
            const ptok = parser.next();
            if (ptok.kind == .object_begin) {
                var arch_ok = false;
                var os_ok = false;

                // Scan platform object keys in any order
                const plat_start = parser.pos;
                if (parser.findKey("architecture")) {
                    if (parser.expectString()) |arch| {
                        arch_ok = sliceEql(arch, "amd64");
                    }
                }
                if (parser.findKey("os")) {
                    if (parser.expectString()) |os_val| {
                        os_ok = sliceEql(os_val, "linux");
                    }
                }
                if (!os_ok) {
                    // os might have been before architecture — retry
                    parser.pos = plat_start;
                    if (parser.findKey("os")) {
                        if (parser.expectString()) |os_val| {
                            os_ok = sliceEql(os_val, "linux");
                        }
                    }
                }
                is_amd64_linux = arch_ok and os_ok;
            }
        }

        // Rewind to entry start for pass 2 (find digest) or to skip
        parser.pos = entry_start;

        var entry_digest: ?[]const u8 = null;
        if (is_amd64_linux) {
            if (parser.findKey("digest")) {
                entry_digest = parser.expectString();
            }
            // Rewind again to skip the full entry
            parser.pos = entry_start;
        }

        // Skip the entire entry object
        // We're positioned just after '{', need to skip to matching '}'
        var depth: u32 = 1;
        while (depth > 0) {
            const t = parser.next();
            if (t.kind == .object_begin) depth += 1;
            if (t.kind == .object_end) depth -= 1;
            if (t.kind == .eof) return null;
        }

        if (is_amd64_linux) {
            if (entry_digest) |d| return d;
        }
    }
    return null;
}

/// Fetch a Bearer token using a pre-parsed WWW-Authenticate header value.
fn fetchAuthToken(www_auth: []const u8, ref: *const ImageRef) bool {
    // Parse challenge
    var challenge: http.AuthChallenge = undefined;
    if (!http.parseWwwAuthenticate(www_auth, &challenge)) {
        stderr.puts("auth: failed to parse WWW-Authenticate\n");
        return false;
    }

    // Copy realm/service to stable buffers
    var realm_buf: [512]u8 = undefined;
    var service_buf: [128]u8 = undefined;
    if (challenge.realm.len > realm_buf.len or challenge.service.len > service_buf.len) return false;
    @memcpy(realm_buf[0..challenge.realm.len], challenge.realm);
    const realm = realm_buf[0..challenge.realm.len];
    @memcpy(service_buf[0..challenge.service.len], challenge.service);
    const service = service_buf[0..challenge.service.len];

    // Build token URL from realm
    var url_path_buf: [512]u8 = undefined;
    const parts = http.parseUrl(realm, &url_path_buf) orelse return false;

    // Build query string: ?service=<service>&scope=repository:<name>:pull
    var query_buf: [512]u8 = undefined;
    var qpos: usize = 0;

    if (parts.path.len > query_buf.len) return false;
    @memcpy(query_buf[0..parts.path.len], parts.path);
    qpos = parts.path.len;
    query_buf[qpos] = '?';
    qpos += 1;

    const svc_key = "service=";
    @memcpy(query_buf[qpos..][0..svc_key.len], svc_key);
    qpos += svc_key.len;
    const enc_svc = http.percentEncode(service, query_buf[qpos..]);
    qpos += enc_svc.len;

    const scope_key = "&scope=repository%3A";
    @memcpy(query_buf[qpos..][0..scope_key.len], scope_key);
    qpos += scope_key.len;
    const enc_name = http.percentEncode(ref.name, query_buf[qpos..]);
    qpos += enc_name.len;
    const scope_suf = "%3Apull";
    @memcpy(query_buf[qpos..][0..scope_suf.len], scope_suf);
    qpos += scope_suf.len;

    const token_path = query_buf[0..qpos];

    // Fetch token from auth endpoint (may be different host)
    var token_use_tls = parts.tls;
    if (!has_tls) token_use_tls = false;
    if (has_tls and token_use_tls and !TlsSupport.initialized) {
        _ = TlsSupport.init();
    }

    const token_opts = makeOpts(&.{}, token_use_tls);
    var token_result = http.request(parts.host, parts.port, "GET", token_path, token_opts, &header_buf) orelse return false;

    if (token_result.resp.status_code < 200 or token_result.resp.status_code >= 300) {
        token_result.conn.close();
        return false;
    }

    // Read token response body
    var token_body: [8192]u8 = undefined;
    var total: usize = 0;
    while (total < token_body.len) {
        const n = token_result.resp.readBody(token_body[total..]);
        if (n <= 0) break;
        total += @intCast(n);
    }
    token_result.conn.close();

    if (total == 0) return false;

    // Parse JSON response for "token" or "access_token" field
    var parser = json.Parser.init(token_body[0..total]);
    const tok = parser.next();
    if (tok.kind != .object_begin) return false;

    while (true) {
        const key_tok = parser.next();
        if (key_tok.kind == .object_end or key_tok.kind == .eof) break;
        if (key_tok.kind == .comma) continue;

        if (key_tok.kind == .string) {
            const is_token_key = sliceEql(key_tok.str_value, "token") or sliceEql(key_tok.str_value, "access_token");
            const colon = parser.next();
            if (colon.kind != .colon) break;

            if (is_token_key) {
                if (parser.expectString()) |token_val| {
                    if (token_val.len > auth_token_buf.len) return false;
                    @memcpy(auth_token_buf[0..token_val.len], token_val);
                    auth_token_len = token_val.len;

                    const prefix = "Bearer ";
                    @memcpy(auth_value_buf[0..prefix.len], prefix);
                    @memcpy(auth_value_buf[prefix.len..][0..token_val.len], token_val);
                    auth_value_len = prefix.len + token_val.len;

                    return true;
                }
                return false;
            } else {
                const val = parser.next();
                if (val.kind == .object_begin) {
                    var depth: u32 = 1;
                    while (depth > 0) {
                        const t = parser.next();
                        if (t.kind == .object_begin) depth += 1;
                        if (t.kind == .object_end) depth -= 1;
                        if (t.kind == .eof) break;
                    }
                }
            }
        }
    }

    return false;
}

// --- Persistent connection helpers ---

/// Get an existing persistent connection or open a new one.
/// Returns a pointer to the persistent_conn if successful, null otherwise.
fn getOrConnect(host: []const u8, port: u16, use_tls_flag: bool) ?*http.Connection {
    // Reuse if same host:port and still active
    if (persistent_active and port == persistent_port and
        host.len == persistent_host_len and
        sliceEql(host, persistent_host_buf[0..persistent_host_len]))
    {
        return &persistent_conn;
    }

    // Close any existing connection first
    if (persistent_active) closePersistent();

    // Resolve hostname
    var ip_buf: [64]u8 = undefined;
    const host_ip = if (http.isIpAddress(host)) host else (http.resolve(host, &ip_buf) orelse {
        stderr.puts("http: DNS resolution failed for ");
        stderr.puts(host);
        stderr.puts("\n");
        return null;
    });

    persistent_conn = http.Connection.connect(host_ip, port, &header_buf) orelse {
        stderr.puts("http: TCP connect failed\n");
        return null;
    };

    // TLS handshake if needed
    if (has_tls and use_tls_flag) {
        persistent_conn.io = TlsSupport.onConnect(persistent_conn.data_fd, host);
        if (persistent_conn.io == null) {
            stderr.puts("http: TLS handshake failed\n");
            persistent_conn.close();
            return null;
        }
    }

    // Save host/port state
    if (host.len <= persistent_host_buf.len) {
        @memcpy(persistent_host_buf[0..host.len], host);
        persistent_host_len = host.len;
    }
    persistent_port = port;
    persistent_active = true;
    return &persistent_conn;
}

/// Close persistent connection (TLS close_notify + TCP close + reset state).
fn closePersistent() void {
    if (!persistent_active) return;
    persistent_conn.close();
    persistent_conn.io = null;
    persistent_active = false;
    persistent_host_len = 0;
    persistent_port = 0;
}

const RegistryResult = struct {
    resp: http.Response,
};

/// Send a request on the persistent connection, reconnecting once if the
/// connection is dead. Returns null on failure.
fn registryRequest(
    host: []const u8,
    port: u16,
    method: []const u8,
    path: []const u8,
    extra_headers: []const http.HeaderEntry,
    use_tls_flag: bool,
) ?RegistryResult {
    const conn = getOrConnect(host, port, use_tls_flag) orelse return null;

    var opts = makeOpts(extra_headers, false); // on_connect already done
    opts.keep_alive = true;

    if (http.requestOnConnection(conn, host, method, path, opts, &header_buf)) |resp| {
        return .{ .resp = resp };
    }

    // Connection dead — reconnect once
    closePersistent();
    const conn2 = getOrConnect(host, port, use_tls_flag) orelse return null;
    if (http.requestOnConnection(conn2, host, method, path, opts, &header_buf)) |resp| {
        return .{ .resp = resp };
    }
    return null;
}


// -- Parallel pull progress display types and helpers --

const LayerState = enum(u8) { pending, downloading, downloaded, extracting, done, failed };

const LayerProgress = struct {
    state: u8, // atomic — LayerState
    bytes_done: u64, // atomic
    bytes_total: u64, // atomic
    digest_short: [12]u8,
};

const DownloadCtx = struct {
    // Inputs (set by main thread before spawn, read-only for worker)
    registry_host: []const u8,
    registry_port: u16,
    blob_path_buf: [512]u8,
    blob_path_len: usize,
    tmp_path_buf: [64]u8,
    tmp_path_len: usize,
    use_tls: bool,
    // Output (atomic writes by worker)
    progress: *LayerProgress,
};

fn fmtSize(buf: *[16]u8, bytes: u64) []const u8 {
    if (bytes >= 1_000_000) {
        // "X.Y MB"
        const mb_whole = bytes / 1_000_000;
        const mb_frac = (bytes % 1_000_000) / 100_000; // one decimal
        var pos: usize = 0;
        pos += fmtU64(buf[pos..], mb_whole);
        buf[pos] = '.';
        pos += 1;
        pos += fmtU64(buf[pos..], mb_frac);
        buf[pos] = ' ';
        pos += 1;
        buf[pos] = 'M';
        pos += 1;
        buf[pos] = 'B';
        pos += 1;
        return buf[0..pos];
    } else if (bytes >= 1_000) {
        const kb = bytes / 1_000;
        var pos: usize = 0;
        pos += fmtU64(buf[pos..], kb);
        buf[pos] = ' ';
        pos += 1;
        buf[pos] = 'K';
        pos += 1;
        buf[pos] = 'B';
        pos += 1;
        return buf[0..pos];
    } else {
        var pos: usize = 0;
        pos += fmtU64(buf[pos..], bytes);
        buf[pos] = ' ';
        pos += 1;
        buf[pos] = 'B';
        pos += 1;
        return buf[0..pos];
    }
}

fn fmtU64(buf: []u8, val: u64) usize {
    if (val == 0) {
        buf[0] = '0';
        return 1;
    }
    var tmp: [20]u8 = undefined;
    var n: usize = 0;
    var v = val;
    while (v > 0) : (v /= 10) {
        tmp[n] = @intCast('0' + (v % 10));
        n += 1;
    }
    // reverse into buf
    for (0..n) |i| {
        buf[i] = tmp[n - 1 - i];
    }
    return n;
}

fn renderLayerLine(progress: *const LayerProgress) void {
    const state: LayerState = @enumFromInt(@atomicLoad(u8, &progress.state, .acquire));
    const done = @atomicLoad(u64, &progress.bytes_done, .acquire);
    const total = @atomicLoad(u64, &progress.bytes_total, .acquire);

    // "\r\x1b[K" — clear line
    stderr.puts("\r\x1b[K");

    // digest
    stderr.puts(progress.digest_short[0..12]);
    stderr.puts(": ");

    switch (state) {
        .pending => stderr.puts("Waiting"),
        .downloading => {
            stderr.puts("Downloading [");
            renderBar(done, total);
            stderr.puts("] ");
            var sz1: [16]u8 = undefined;
            stderr.puts(fmtSize(&sz1, done));
            stderr.puts(" / ");
            var sz2: [16]u8 = undefined;
            stderr.puts(fmtSize(&sz2, total));
        },
        .downloaded => {
            stderr.puts("Download complete   | ");
            var sz: [16]u8 = undefined;
            stderr.puts(fmtSize(&sz, total));
        },
        .extracting => {
            stderr.puts("Extracting  [");
            renderBar(done, total);
            stderr.puts("] ");
            var sz1: [16]u8 = undefined;
            stderr.puts(fmtSize(&sz1, done));
            stderr.puts(" / ");
            var sz2: [16]u8 = undefined;
            stderr.puts(fmtSize(&sz2, total));
        },
        .done => stderr.puts("Pull complete"),
        .failed => stderr.puts("Failed"),
    }
    stderr.puts("\n");
}

fn renderBar(done: u64, total: u64) void {
    const bar_width: u64 = 20;
    const filled: u64 = if (total > 0) @min(done * bar_width / total, bar_width) else 0;
    var bar: [20]u8 = undefined;
    for (0..bar_width) |i| {
        if (i < filled) {
            bar[i] = '=';
        } else if (i == filled and filled < bar_width) {
            bar[i] = '>';
        } else {
            bar[i] = ' ';
        }
    }
    stderr.puts(bar[0..bar_width]);
}

fn renderAllLines(progress: []LayerProgress, layer_count: usize) void {
    // Move cursor up N lines
    stderr.print("\x1b[{d}A", .{layer_count});
    // Render each line
    for (0..layer_count) |i| {
        renderLayerLine(&progress[i]);
    }
}

fn allDownloaded(progress: []LayerProgress, layer_count: usize) bool {
    for (0..layer_count) |i| {
        const s: LayerState = @enumFromInt(@atomicLoad(u8, &progress[i].state, .acquire));
        if (s != .downloaded and s != .failed) return false;
    }
    return true;
}


fn downloadThreadFn(arg: *anyopaque) callconv(.c) void {
    const ctx: *DownloadCtx = @ptrCast(@alignCast(arg));
    const progress = ctx.progress;

    @atomicStore(u8, &progress.state, @intFromEnum(LayerState.downloading), .release);

    // Build headers on stack (avoid touching global combined_hdrs)
    var thr_hdrs: [4]http.HeaderEntry = undefined;
    var hdr_count: usize = 0;

    // Auth header (auth_token_buf/len are read-only during downloads)
    if (auth_token_len > 0) {
        thr_hdrs[hdr_count] = .{ .name = "Authorization", .value = auth_value_buf[0..auth_value_len] };
        hdr_count += 1;
    }
    thr_hdrs[hdr_count] = .{ .name = "Accept", .value = "application/vnd.docker.image.rootfs.diff.tar.gzip" };
    hdr_count += 1;

    // Threads are only used for non-TLS, so no TLS on_connect needed
    const opts = http.RequestOptions{ .headers = thr_hdrs[0..hdr_count] };

    // Stack-local buffers
    var thr_header_buf: [8192]u8 = undefined;
    var thr_io_buf: [16384]u8 = undefined;

    var result = http.request(
        ctx.registry_host,
        ctx.registry_port,
        "GET",
        ctx.blob_path_buf[0..ctx.blob_path_len],
        opts,
        &thr_header_buf,
    ) orelse {
        @atomicStore(u8, &progress.state, @intFromEnum(LayerState.failed), .release);
        return;
    };

    if (result.resp.status_code < 200 or result.resp.status_code >= 300) {
        result.conn.close();
        @atomicStore(u8, &progress.state, @intFromEnum(LayerState.failed), .release);
        return;
    }

    // Set total from Content-Length
    if (result.resp.content_length > 0) {
        @atomicStore(u64, &progress.bytes_total, @intCast(result.resp.content_length), .release);
    }

    // Create temp file
    const tmp_path = ctx.tmp_path_buf[0..ctx.tmp_path_len];
    const tmp_fd = fx.create(tmp_path, 0);
    if (tmp_fd < 0) {
        result.conn.close();
        @atomicStore(u8, &progress.state, @intFromEnum(LayerState.failed), .release);
        return;
    }

    // Download loop
    var total_written: u64 = 0;
    while (true) {
        const n = result.resp.readBody(&thr_io_buf);
        if (n <= 0) break;
        const nbytes: usize = @intCast(n);
        _ = fx.syscall.write(tmp_fd, thr_io_buf[0..nbytes]);
        total_written += nbytes;
        @atomicStore(u64, &progress.bytes_done, total_written, .release);
    }

    _ = fx.close(tmp_fd);
    result.conn.close();

    // Final total for display accuracy
    @atomicStore(u64, &progress.bytes_total, total_written, .release);
    @atomicStore(u64, &progress.bytes_done, total_written, .release);
    @atomicStore(u8, &progress.state, @intFromEnum(LayerState.downloaded), .release);
}

fn downloadSequential(ctx: *DownloadCtx) void {
    const progress = ctx.progress;
    @atomicStore(u8, &progress.state, @intFromEnum(LayerState.downloading), .release);

    const accept_hdr = [_]http.HeaderEntry{
        .{ .name = "Accept", .value = "application/vnd.docker.image.rootfs.diff.tar.gzip" },
    };
    const opts = makeOpts(&accept_hdr, ctx.use_tls);

    var result = http.request(
        ctx.registry_host,
        ctx.registry_port,
        "GET",
        ctx.blob_path_buf[0..ctx.blob_path_len],
        opts,
        &header_buf,
    ) orelse {
        @atomicStore(u8, &progress.state, @intFromEnum(LayerState.failed), .release);
        return;
    };

    if (result.resp.status_code < 200 or result.resp.status_code >= 300) {
        result.conn.close();
        @atomicStore(u8, &progress.state, @intFromEnum(LayerState.failed), .release);
        return;
    }

    if (result.resp.content_length > 0) {
        @atomicStore(u64, &progress.bytes_total, @intCast(result.resp.content_length), .release);
    }

    const tmp_path = ctx.tmp_path_buf[0..ctx.tmp_path_len];
    const tmp_fd = fx.create(tmp_path, 0);
    if (tmp_fd < 0) {
        result.conn.close();
        @atomicStore(u8, &progress.state, @intFromEnum(LayerState.failed), .release);
        return;
    }

    var total_written: u64 = 0;
    while (true) {
        const n = result.resp.readBody(&pull_io_buf);
        if (n <= 0) break;
        const nbytes: usize = @intCast(n);
        _ = fx.syscall.write(tmp_fd, pull_io_buf[0..nbytes]);
        total_written += nbytes;
        @atomicStore(u64, &progress.bytes_done, total_written, .release);
    }

    _ = fx.close(tmp_fd);
    result.conn.close();

    @atomicStore(u64, &progress.bytes_total, total_written, .release);
    @atomicStore(u64, &progress.bytes_done, total_written, .release);
    @atomicStore(u8, &progress.state, @intFromEnum(LayerState.downloaded), .release);
}

const FileReaderCtx = struct {
    fd: i32,
    bytes_read: u64,
};

fn fileReadFn(ctx_ptr: *anyopaque, buf: []u8) isize {
    const ctx: *FileReaderCtx = @ptrCast(@alignCast(ctx_ptr));
    const n = fx.syscall.read(ctx.fd, buf);
    if (n > 0) {
        ctx.bytes_read += @intCast(n);
    }
    return n;
}

const FileGzipReader = struct {
    bit_reader: deflate.BitReader,
    inflater: deflate.Inflater,

    fn init(ctx: *FileReaderCtx) FileGzipReader {
        return .{
            .bit_reader = deflate.BitReader.init(&fileReadFn, @ptrCast(ctx), &pull_io_buf),
            .inflater = deflate.Inflater.init(&sliding_window, &inflate_out_buf),
        };
    }

    fn skipGzipHeader(self: *FileGzipReader) bool {
        return deflate.skipGzipHeader(&self.bit_reader);
    }

    fn readBlock(self: *FileGzipReader, dest: *[tar.HEADER_SIZE]u8) bool {
        var pos: usize = 0;
        while (pos < tar.HEADER_SIZE) {
            if (self.inflater.done) break;
            const n = self.inflater.readBytes(&self.bit_reader, dest[pos..]);
            if (n == 0) break;
            pos += n;
        }
        if (pos == 0) return false;
        if (pos < tar.HEADER_SIZE) {
            @memset(dest[pos..], 0);
        }
        return true;
    }
};

fn extractLayerFromFile(file_fd: i32, rootfs_path: []const u8, progress: *LayerProgress, mkdir_cache: *[64]u64) bool {
    var ctx = FileReaderCtx{ .fd = file_fd, .bytes_read = 0 };
    var gz = FileGzipReader.init(&ctx);

    if (!gz.skipGzipHeader()) {
        stderr.puts("fnx: invalid gzip header in layer\n");
        return false;
    }

    var zero_blocks: u32 = 0;
    var header_raw: [tar.HEADER_SIZE]u8 = undefined;
    while (true) {
        if (!gz.readBlock(&header_raw)) break;
        if (tar.isZeroBlock(&header_raw)) {
            zero_blocks += 1;
            if (zero_blocks >= 2) break;
            continue;
        }
        zero_blocks = 0;
        extractEntryBuffered(&header_raw, &gz, rootfs_path, progress, mkdir_cache);
    }
    return true;
}


fn fnvHash(data: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (data) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

fn mkdirCached(fpath: []const u8, n_len: usize, cache: *[64]u64) void {
    if (n_len == 0) return;
    const h = fnvHash(fpath[0..n_len]);
    const slot = h % 64;
    if (cache[slot] == h) return; // already created
    _ = fx.mkdir(fpath[0..n_len]);
    cache[slot] = h;
}

fn ensureParentDirsCached(fpath: []const u8, cache: *[64]u64) void {
    var pi: usize = 0;
    while (pi < fpath.len) : (pi += 1) {
        if (fpath[pi] == '/' and pi > 0) {
            mkdirCached(fpath, pi, cache);
        }
    }
}

fn skipGzBlocksFile(gz: *FileGzipReader, size: u64) void {
    const blocks = (size + tar.HEADER_SIZE - 1) / tar.HEADER_SIZE;
    var block: [tar.HEADER_SIZE]u8 = undefined;
    var bi: u64 = 0;
    while (bi < blocks) : (bi += 1) {
        _ = gz.readBlock(&block);
    }
}

fn extractEntryBuffered(header_raw: *[tar.HEADER_SIZE]u8, gz: *FileGzipReader, rootfs_path: []const u8, progress: *LayerProgress, mkdir_cache: *[64]u64) void {
    const hdr = tar.Header{ .raw = header_raw };

    if (!hdr.validateChecksum()) return;

    const name = hdr.name(&path_scratch);
    const size = hdr.size();
    const mode_val = hdr.mode();
    const uid_val = hdr.uid();
    const gid_val = hdr.gid();
    const typeflag = hdr.typeflag();

    if (!tar.isSafePath(name)) {
        if (size > 0 and (typeflag == '0' or typeflag == 0)) {
            skipGzBlocksFile(gz, size);
        }
        return;
    }

    // Build full path: rootfs_path + "/" + name
    var full_path: [512]u8 = undefined;
    var fpos: usize = 0;
    @memcpy(full_path[fpos..][0..rootfs_path.len], rootfs_path);
    fpos += rootfs_path.len;
    full_path[fpos] = '/';
    fpos += 1;
    // Strip leading "./" from tar names
    var clean_name = name;
    if (clean_name.len >= 2 and clean_name[0] == '.' and clean_name[1] == '/') {
        clean_name = clean_name[2..];
    }
    // Strip leading "/"
    while (clean_name.len > 0 and clean_name[0] == '/') {
        clean_name = clean_name[1..];
    }
    if (clean_name.len == 0) {
        if (size > 0 and (typeflag == '0' or typeflag == 0)) {
            skipGzBlocksFile(gz, size);
        }
        return;
    }
    if (fpos + clean_name.len > full_path.len) {
        if (size > 0 and (typeflag == '0' or typeflag == 0)) {
            skipGzBlocksFile(gz, size);
        }
        return;
    }
    @memcpy(full_path[fpos..][0..clean_name.len], clean_name);
    fpos += clean_name.len;
    const fpath = full_path[0..fpos];

    if (typeflag == '5') {
        // Directory
        ensureParentDirsCached(fpath, mkdir_cache);
        var n_len = fpath.len;
        while (n_len > 0 and fpath[n_len - 1] == '/') n_len -= 1;
        if (n_len > 0) {
            mkdirCached(fpath, n_len, mkdir_cache);
        }
    } else if (typeflag == '0' or typeflag == 0) {
        // Regular file — buffered writes
        ensureParentDirsCached(fpath, mkdir_cache);
        const out_fd = fx.create(fpath, 0);
        if (out_fd < 0) {
            skipGzBlocksFile(gz, size);
            return;
        }

        var write_buf: [4096]u8 = undefined;
        var wb_pos: usize = 0;
        var remaining: u64 = size;
        const blocks = (size + tar.HEADER_SIZE - 1) / tar.HEADER_SIZE;
        var block_i: u64 = 0;
        while (block_i < blocks) : (block_i += 1) {
            var block: [tar.HEADER_SIZE]u8 = undefined;
            if (!gz.readBlock(&block)) break;
            const to_write: usize = @intCast(@min(remaining, tar.HEADER_SIZE));

            // Buffer the data
            var src_off: usize = 0;
            while (src_off < to_write) {
                const space = write_buf.len - wb_pos;
                const chunk = @min(to_write - src_off, space);
                @memcpy(write_buf[wb_pos..][0..chunk], block[src_off..][0..chunk]);
                wb_pos += chunk;
                src_off += chunk;

                if (wb_pos == write_buf.len) {
                    _ = fx.syscall.write(out_fd, write_buf[0..wb_pos]);
                    wb_pos = 0;
                }
            }

            remaining -= to_write;

            // Update extraction progress
            @atomicStore(u64, &progress.bytes_done, @atomicLoad(u64, &progress.bytes_done, .acquire) + to_write, .release);
        }

        // Flush remaining buffer
        if (wb_pos > 0) {
            _ = fx.syscall.write(out_fd, write_buf[0..wb_pos]);
        }

        _ = fx.wstat(out_fd, @intCast(mode_val & 0o7777), @intCast(uid_val), @intCast(gid_val), fx.WSTAT_MODE | fx.WSTAT_UID | fx.WSTAT_GID);
        _ = fx.close(out_fd);
    } else {
        // Symlinks, hardlinks, etc — skip data
        if (size > 0) {
            skipGzBlocksFile(gz, size);
        }
    }
}

fn cmdPull(image_str: []const u8) void {
    const ref = parseImageRef(image_str);

    // Display what we're pulling
    stderr.puts("Pulling ");
    stderr.puts(ref.name);
    stderr.puts(":");
    stderr.puts(ref.tag);
    stderr.puts(" from ");
    var reg_buf: [128]u8 = undefined;
    stderr.puts(fmtRegistry(&reg_buf, ref.registry_host, ref.registry_port));
    if (ref.use_tls) stderr.puts(" (TLS)");
    stderr.puts("\n");

    // Initialize TLS if this registry uses HTTPS
    if (!ensureTls(&ref)) {
        stderr.puts("fnx: TLS required but not available or CA bundle missing\n");
        fx.exit(1);
    }

    // Step 1: Check registry connectivity — GET /v2/ (with auth if needed)
    {
        var rr = registryRequest(ref.registry_host, ref.registry_port, "GET", "/v2/", &.{}, ref.use_tls) orelse {
            stderr.puts("fnx: cannot connect to registry ");
            stderr.puts(fmtRegistry(&reg_buf, ref.registry_host, ref.registry_port));
            stderr.puts("\n");
            fx.exit(1);
        };

        if (rr.resp.status_code == 401) {
            // Extract WWW-Authenticate before draining (points into header_buf)
            const www_auth = rr.resp.getHeader("WWW-Authenticate") orelse {
                stderr.puts("fnx: 401 but no WWW-Authenticate header\n");
                closePersistent();
                fx.exit(1);
            };
            // Copy to stable buffer before draining body (which reuses header_buf)
            var www_auth_copy: [512]u8 = undefined;
            if (www_auth.len > www_auth_copy.len) {
                closePersistent();
                fx.exit(1);
            }
            @memcpy(www_auth_copy[0..www_auth.len], www_auth);
            _ = rr.resp.drainAndReady();

            // Server may reject reuse after 401 — close and reconnect after auth
            closePersistent();

            // Fetch auth token using the challenge from the 401
            stderr.puts("Authenticating...\n");
            if (!fetchAuthToken(www_auth_copy[0..www_auth.len], &ref)) {
                stderr.puts("fnx: registry requires auth but token fetch failed\n");
                fx.exit(1);
            }
        } else {
            if (rr.resp.status_code != 200) {
                _ = rr.resp.drainAndReady();
                closePersistent();
                stderr.puts("fnx: registry returned status ");
                stderr.print("{d}", .{rr.resp.status_code});
                stderr.puts("\n");
                fx.exit(1);
            }
            // Drain 200 body to prepare connection for reuse
            if (!rr.resp.drainAndReady()) closePersistent();
        }
    }

    // Step 2: Fetch manifest (handles manifest lists / OCI indexes)
    var api_path: [512]u8 = undefined;
    var manifest_data: []const u8 = undefined;
    {
        manifest_data = fetchManifest(&api_path, &ref, manifest_buf[0..]);
    }

    // Step 3: Parse manifest — extract config digest + layer digests + sizes
    var config_digest: []const u8 = "";
    var layer_digests: [MAX_LAYERS][]const u8 = undefined;
    var layer_sizes: [MAX_LAYERS]u64 = undefined;
    var layer_count: usize = 0;
    {
        var parser = json.Parser.init(manifest_data);
        var tok = parser.next();
        if (tok.kind != .object_begin) {
            stderr.puts("fnx: invalid manifest format\n");
            fx.exit(1);
        }

        // Find "config" -> "digest"
        if (parser.findKey("config")) {
            tok = parser.next();
            if (tok.kind == .object_begin) {
                if (parser.findKey("digest")) {
                    if (parser.expectString()) |d| {
                        config_digest = d;
                    }
                }
                // Skip rest of config object
                // Find closing brace
                var depth: u32 = 1;
                while (depth > 0) {
                    const t = parser.next();
                    if (t.kind == .object_begin) depth += 1;
                    if (t.kind == .object_end) depth -= 1;
                    if (t.kind == .eof) break;
                }
            }
        }

        // Find "layers" array
        if (parser.findKey("layers")) {
            tok = parser.next();
            if (tok.kind == .array_begin) {
                while (layer_count < MAX_LAYERS) {
                    skipWs(&parser);
                    if (parser.pos < parser.src.len and parser.src[parser.pos] == ']') {
                        parser.pos += 1;
                        break;
                    }
                    if (layer_count > 0) {
                        const comma = parser.next();
                        if (comma.kind != .comma) break;
                    }
                    // Each layer is an object with "digest" and "size"
                    tok = parser.next();
                    if (tok.kind != .object_begin) break;

                    var got_digest = false;
                    var layer_size: u64 = 0;
                    const obj_start = parser.pos;

                    // Find "digest"
                    if (parser.findKey("digest")) {
                        if (parser.expectString()) |d| {
                            layer_digests[layer_count] = d;
                            got_digest = true;
                        }
                    }

                    // Reset and find "size"
                    parser.pos = obj_start;
                    if (parser.findKey("size")) {
                        if (parser.expectInt()) |sz| {
                            layer_size = if (sz > 0) @intCast(sz) else 0;
                        }
                    }

                    // Skip to end of layer object
                    parser.pos = obj_start;
                    var depth: u32 = 1;
                    while (depth > 0) {
                        const t = parser.next();
                        if (t.kind == .object_begin) depth += 1;
                        if (t.kind == .object_end) depth -= 1;
                        if (t.kind == .eof) break;
                    }
                    if (got_digest) {
                        layer_sizes[layer_count] = layer_size;
                        layer_count += 1;
                    }
                }
            }
        }
    }

    if (layer_count == 0) {
        stderr.puts("fnx: no layers in manifest\n");
        fx.exit(1);
    }

    // Step 4: Create image directory
    // Determine short name for directory (last component of name)
    var short_name = ref.name;
    for (0..ref.name.len) |ni| {
        if (ref.name[ni] == '/') {
            if (ni + 1 < ref.name.len) short_name = ref.name[ni + 1 ..];
        }
    }
    // Include tag if not "latest"
    var img_name_buf: [128]u8 = undefined;
    var img_name: []const u8 = undefined;
    if (!sliceEql(ref.tag, "latest")) {
        var np: usize = 0;
        @memcpy(img_name_buf[np..][0..short_name.len], short_name);
        np += short_name.len;
        img_name_buf[np] = ':';
        np += 1;
        @memcpy(img_name_buf[np..][0..ref.tag.len], ref.tag);
        np += ref.tag.len;
        img_name = img_name_buf[0..np];
    } else {
        img_name = short_name;
    }

    _ = fx.mkdir("/var/lib");
    _ = fx.mkdir("/var/lib/fnx");
    _ = fx.mkdir("/var/lib/fnx/images");

    var img_dir: [256]u8 = undefined;
    const img_dir_len = fmtPath(&img_dir, "/var/lib/fnx/images/", img_name, "");
    _ = fx.mkdir(img_dir[0..img_dir_len]);

    var rootfs: [256]u8 = undefined;
    const rootfs_len = fmtPath(&rootfs, img_dir[0..img_dir_len], "/rootfs", "");
    _ = fx.mkdir(rootfs[0..rootfs_len]);
    const rootfs_path = rootfs[0..rootfs_len];

    // Step 5: Save manifest
    {
        var mpath: [256]u8 = undefined;
        const mlen = fmtPath(&mpath, img_dir[0..img_dir_len], "/manifest.json", "");
        const mfd = fx.create(mpath[0..mlen], 0);
        if (mfd >= 0) {
            _ = fx.write(mfd, manifest_data);
            _ = fx.close(mfd);
        }
    }

    // Step 6: Fetch and parse config blob (uses persistent connection)
    if (config_digest.len > 0) {
        // Use elf_buf as temp for config JSON (it's large enough)
        if (fetchBlob(&ref, config_digest, &elf_buf)) |config_json| {
            var cmd_buf: [256]u8 = undefined;
            if (parseOciConfig(config_json, &cmd_buf)) |cmd_str| {
                var cpath: [256]u8 = undefined;
                const clen = fmtPath(&cpath, img_dir[0..img_dir_len], "/config", "");
                const cfd = fx.create(cpath[0..clen], 0);
                if (cfd >= 0) {
                    _ = fx.write(cfd, cmd_str);
                    _ = fx.close(cfd);
                }
            }

            // Check if this is a linux image (write compat file)
            // OCI config has "os" field at top level
            var os_parser = json.Parser.init(config_json);
            const otok = os_parser.next();
            if (otok.kind == .object_begin) {
                if (os_parser.findKey("os")) {
                    if (os_parser.expectString()) |os_str| {
                        if (sliceEql(os_str, "linux")) {
                            var compat_path: [256]u8 = undefined;
                            const cplen = fmtPath(&compat_path, img_dir[0..img_dir_len], "/compat", "");
                            const cpfd = fx.create(compat_path[0..cplen], 0);
                            if (cpfd >= 0) {
                                _ = fx.write(cpfd, "linux");
                                _ = fx.close(cpfd);
                            }
                        }
                    }
                }
            }
        }
    }

    // Close persistent connection before layer downloads (layers use
    // http.request() with redirect handling for CDN 307s)
    closePersistent();

    // Ensure /tmp exists for layer temp files
    _ = fx.mkdir("/tmp");

    // Step 7: Download and extract layers (parallel for non-TLS, sequential for TLS)
    var progress: [MAX_LAYERS]LayerProgress = undefined;
    var contexts: [MAX_LAYERS]DownloadCtx = undefined;
    var tmp_paths: [MAX_LAYERS][64]u8 = undefined;
    var tmp_path_lens: [MAX_LAYERS]usize = undefined;

    // Initialize progress and contexts for each layer
    for (0..layer_count) |li| {
        const digest = layer_digests[li];

        // Short digest for display (12 hex chars after "sha256:")
        var ds: [12]u8 = undefined;
        if (digest.len > 19) {
            @memcpy(ds[0..12], digest[7..19]);
        } else {
            const copy_len = @min(digest.len, @as(usize, 12));
            @memcpy(ds[0..copy_len], digest[0..copy_len]);
            if (copy_len < 12) @memset(ds[copy_len..], '0');
        }

        progress[li] = .{
            .state = @intFromEnum(LayerState.pending),
            .bytes_done = 0,
            .bytes_total = layer_sizes[li],
            .digest_short = ds,
        };

        // Build blob path: /v2/<name>/blobs/<digest>
        var bpos: usize = 0;
        const bp1 = "/v2/";
        @memcpy(contexts[li].blob_path_buf[bpos..][0..bp1.len], bp1);
        bpos += bp1.len;
        @memcpy(contexts[li].blob_path_buf[bpos..][0..ref.name.len], ref.name);
        bpos += ref.name.len;
        const bp2 = "/blobs/";
        @memcpy(contexts[li].blob_path_buf[bpos..][0..bp2.len], bp2);
        bpos += bp2.len;
        @memcpy(contexts[li].blob_path_buf[bpos..][0..digest.len], digest);
        bpos += digest.len;
        contexts[li].blob_path_len = bpos;

        // Build temp path: /tmp/fnx-layer-N
        var tpos: usize = 0;
        const tp1 = "/tmp/fnx-layer-";
        @memcpy(tmp_paths[li][tpos..][0..tp1.len], tp1);
        tpos += tp1.len;
        tpos += fmtU64(tmp_paths[li][tpos..], li);
        tmp_paths[li][tpos] = 0; // for display only
        tmp_path_lens[li] = tpos;
        @memcpy(contexts[li].tmp_path_buf[0..tpos], tmp_paths[li][0..tpos]);
        contexts[li].tmp_path_len = tpos;

        contexts[li].registry_host = ref.registry_host;
        contexts[li].registry_port = ref.registry_port;
        contexts[li].use_tls = ref.use_tls;
        contexts[li].progress = &progress[li];
    }

    // Print N blank lines for progress display
    for (0..layer_count) |_| {
        stderr.puts("\n");
    }

    if (!ref.use_tls) {
        // PARALLEL: Spawn download threads for non-TLS
        var handles: [MAX_LAYERS]fx.thread.ThreadHandle = undefined;
        var spawned: [MAX_LAYERS]bool = undefined;
        for (0..layer_count) |i| {
            if (fx.thread.spawnThread(downloadThreadFn, @ptrCast(&contexts[i]))) |h| {
                handles[i] = h;
                spawned[i] = true;
            } else |_| {
                // Fallback: download sequentially inline
                spawned[i] = false;
                downloadSequential(&contexts[i]);
            }
        }

        // Display loop until all downloaded
        while (!allDownloaded(progress[0..layer_count], layer_count)) {
            renderAllLines(progress[0..layer_count], layer_count);
            fx.sleep(200);
        }
        // Final render
        renderAllLines(progress[0..layer_count], layer_count);

        // Join all threads
        for (0..layer_count) |i| {
            if (spawned[i]) {
                fx.thread.join(&handles[i]);
            }
        }
    } else {
        // SEQUENTIAL (TLS): Download one at a time with progress
        for (0..layer_count) |i| {
            downloadSequential(&contexts[i]);
            renderAllLines(progress[0..layer_count], layer_count);
        }
    }

    // Extract phase (always sequential — reuses BSS globals)
    var mkdir_cache: [64]u64 = undefined;
    @memset(&mkdir_cache, 0);

    for (0..layer_count) |i| {
        @atomicStore(u8, &progress[i].state, @intFromEnum(LayerState.extracting), .release);
        @atomicStore(u64, &progress[i].bytes_done, 0, .release);

        const tmp_path = tmp_paths[i][0..tmp_path_lens[i]];
        const fd = fx.open(tmp_path);
        if (fd >= 0) {
            _ = extractLayerFromFile(fd, rootfs_path, &progress[i], &mkdir_cache);
            _ = fx.close(fd);
            _ = fx.remove(tmp_path);
            @atomicStore(u8, &progress[i].state, @intFromEnum(LayerState.done), .release);
        } else {
            @atomicStore(u8, &progress[i].state, @intFromEnum(LayerState.failed), .release);
        }
        renderAllLines(progress[0..layer_count], layer_count);
    }

    out.puts("Successfully pulled '");
    out.puts(img_name);
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
