/// adduser — create a new user account (root only).
const fx = @import("fornax");

const out = fx.io.Writer.stdout;
const err = fx.io.Writer.stderr;

var file_buf: [4096]u8 linksection(".bss") = undefined;
var pw1_buf: [128]u8 = undefined;
var pw2_buf: [128]u8 = undefined;

fn argSlice(arg: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (arg[len] != 0) : (len += 1) {}
    return arg[0..len];
}

fn readLine(buf: []u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < buf.len) {
        var tmp: [1]u8 = undefined;
        const n = fx.read(0, &tmp);
        if (n <= 0) return null;
        if (tmp[0] == '\n' or tmp[0] == '\r') return buf[0..pos];
        if (tmp[0] == 0x7f or tmp[0] == 0x08) {
            if (pos > 0) pos -= 1;
            continue;
        }
        if (tmp[0] >= 0x20) {
            buf[pos] = tmp[0];
            pos += 1;
        }
    }
    return buf[0..pos];
}

fn eqlSlice(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

/// Find the next available UID by scanning /etc/passwd.
fn findNextUid() u16 {
    const fd = fx.open("/etc/passwd");
    if (fd < 0) return 1000;
    defer _ = fx.close(fd);

    const n = fx.read(fd, &file_buf);
    if (n <= 0) return 1000;

    var max_uid: u16 = 999;
    const data = file_buf[0..@intCast(n)];
    var start: usize = 0;
    for (data, 0..) |c, i| {
        if (c == '\n') {
            if (fx.passwd.parseLine(data[start..i])) |entry| {
                if (entry.uid >= 1000 and entry.uid > max_uid) {
                    max_uid = entry.uid;
                }
            }
            start = i + 1;
        }
    }
    if (start < data.len) {
        if (fx.passwd.parseLine(data[start..])) |entry| {
            if (entry.uid >= 1000 and entry.uid > max_uid) {
                max_uid = entry.uid;
            }
        }
    }

    return if (max_uid >= 1000) max_uid + 1 else 1000;
}

export fn _start() noreturn {
    // Check root
    if (fx.getuid() != 0) {
        err.puts("adduser: must be root\n");
        fx.exit(1);
    }

    const args = fx.getArgs();
    if (args.len != 2) {
        err.puts("usage: adduser <username>\n");
        fx.exit(1);
    }

    const username = argSlice(args[1]);
    if (username.len == 0 or username.len > 31) {
        err.puts("adduser: invalid username\n");
        fx.exit(1);
    }

    // Check for duplicates
    if (fx.passwd.lookupByName(username) != null) {
        err.print("adduser: user '{s}' already exists\n", .{username});
        fx.exit(1);
    }

    // Prompt for password
    out.print("New password for {s}: ", .{username});
    _ = fx.write(0, "echo off");
    const pw1 = readLine(&pw1_buf) orelse {
        _ = fx.write(0, "echo on");
        out.puts("\n");
        err.puts("adduser: failed to read password\n");
        fx.exit(1);
    };
    _ = fx.write(0, "echo on");
    out.puts("\n");

    out.puts("Retype password: ");
    _ = fx.write(0, "echo off");
    const pw2 = readLine(&pw2_buf) orelse {
        _ = fx.write(0, "echo on");
        out.puts("\n");
        err.puts("adduser: failed to read password\n");
        fx.exit(1);
    };
    _ = fx.write(0, "echo on");
    out.puts("\n");

    if (!eqlSlice(pw1, pw2)) {
        err.puts("adduser: passwords do not match\n");
        fx.exit(1);
    }

    // Hash password
    var hash_buf: [39]u8 = undefined;
    const hash = fx.crypt.hashPassword(&hash_buf, pw1);

    // Find next uid
    const uid = findNextUid();
    const gid: u16 = 100; // users group

    // Build passwd entry (hash goes in shadow, passwd gets "x")
    var entry: fx.passwd.PasswdEntry = .{};
    entry.username_len = @truncate(username.len);
    @memcpy(entry.username[0..username.len], username);
    entry.hash[0] = 'x';
    entry.hash_len = 1;
    entry.uid = uid;
    entry.gid = gid;

    // gecos = username
    entry.gecos_len = @truncate(username.len);
    @memcpy(entry.gecos[0..username.len], username);

    // home = /home/<username>
    const home_prefix = "/home/";
    const home_len = home_prefix.len + username.len;
    @memcpy(entry.home[0..home_prefix.len], home_prefix);
    @memcpy(entry.home[home_prefix.len..][0..username.len], username);
    entry.home_len = @truncate(home_len);

    // shell = /bin/fsh
    const shell = "/bin/fsh";
    entry.shell_len = @truncate(shell.len);
    @memcpy(entry.shell[0..shell.len], shell);

    // Format line
    var line_buf: [256]u8 = undefined;
    const line = fx.passwd.formatLine(&line_buf, &entry) orelse {
        err.puts("adduser: failed to format passwd line\n");
        fx.exit(1);
    };

    // Get current file size to append
    const fd = fx.open("/etc/passwd");
    if (fd < 0) {
        err.puts("adduser: cannot open /etc/passwd\n");
        fx.exit(1);
    }
    var st: fx.Stat = undefined;
    _ = fx.stat(fd, &st);
    _ = fx.close(fd);

    // Append to /etc/passwd using pwrite at file size
    const wfd = fx.open("/etc/passwd");
    if (wfd < 0) {
        err.puts("adduser: cannot open /etc/passwd for writing\n");
        fx.exit(1);
    }
    _ = fx.pwrite(wfd, line, st.size);
    _ = fx.close(wfd);

    // Append hash to /etc/shadow
    var shadow_entry: fx.shadow.ShadowEntry = .{};
    shadow_entry.username_len = @truncate(username.len);
    @memcpy(shadow_entry.username[0..username.len], username);
    shadow_entry.hash_len = @truncate(hash.len);
    @memcpy(shadow_entry.hash[0..hash.len], hash);

    var shadow_line_buf: [128]u8 = undefined;
    const shadow_line = fx.shadow.formatLine(&shadow_line_buf, &shadow_entry) orelse {
        err.puts("adduser: failed to format shadow line\n");
        fx.exit(1);
    };

    const sfd = fx.open("/etc/shadow");
    if (sfd >= 0) {
        var sst: fx.Stat = undefined;
        _ = fx.stat(sfd, &sst);
        _ = fx.close(sfd);

        const swfd = fx.open("/etc/shadow");
        if (swfd >= 0) {
            _ = fx.pwrite(swfd, shadow_line, sst.size);
            _ = fx.close(swfd);
        }
    }

    // Create home directory
    const home = entry.home[0..home_len];
    _ = fx.mkdir(home);
    const hfd = fx.open(home);
    if (hfd >= 0) {
        _ = fx.wstat(hfd, 0, uid, gid, fx.WSTAT_UID | fx.WSTAT_GID);
        _ = fx.close(hfd);
    }

    var uid_dec: [8]u8 = undefined;
    out.print("adduser: user '{s}' created (uid={s})\n", .{ username, fx.fmt.formatDec(&uid_dec, uid) });

    fx.exit(0);
}
