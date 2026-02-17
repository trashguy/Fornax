/// Fornax login — authenticates users and starts their shell.
///
/// Prompts for username, verifies password, calls setuid, then exec's
/// the user's shell. When the shell exits, login's process dies and
/// init respawns a new login on that VT.
const fx = @import("fornax");

const out = fx.io.Writer.stdout;

/// 2 MB ELF buffer for loading shell binary.
var elf_buf: [2 * 1024 * 1024]u8 linksection(".bss") = undefined;
var line_buf: [256]u8 = undefined;
var pw_buf: [128]u8 = undefined;

fn readLine(buf: []u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < buf.len) {
        var tmp: [1]u8 = undefined;
        const n = fx.read(0, &tmp);
        if (n <= 0) return null;
        if (tmp[0] == '\n' or tmp[0] == '\r') {
            return buf[0..pos];
        }
        if (tmp[0] == 0x7f or tmp[0] == 0x08) { // backspace
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

export fn _start() noreturn {
    while (true) {
        out.puts("\nfornax login: ");

        const username = readLine(&line_buf) orelse {
            fx.sleep(1000);
            continue;
        };
        if (username.len == 0) continue;

        // Look up user
        const entry = fx.passwd.lookupByName(username) orelse {
            out.puts("Login incorrect\n");
            fx.sleep(2000);
            continue;
        };

        // Check password via /etc/shadow
        var hash_buf: [48]u8 = undefined;
        var hash_len: usize = 1;
        hash_buf[0] = 'x'; // default: no password
        if (fx.shadow.lookupByName(username)) |se| {
            const h = se.hashSlice();
            @memcpy(hash_buf[0..h.len], h);
            hash_len = h.len;
        }
        const hash = hash_buf[0..hash_len];
        if (!(hash.len == 1 and hash[0] == 'x')) {
            // User has a password — prompt for it
            out.puts("Password: ");
            _ = fx.write(0, "echo off");
            const password = readLine(&pw_buf) orelse {
                _ = fx.write(0, "echo on");
                out.puts("\n");
                fx.sleep(2000);
                continue;
            };
            _ = fx.write(0, "echo on");
            out.puts("\n");

            if (!fx.crypt.verifyPassword(hash, password)) {
                out.puts("Login incorrect\n");
                fx.sleep(2000);
                continue;
            }
        }

        // Create home directory if missing
        const home = entry.homeSlice();
        if (home.len > 1) { // not just "/"
            const home_fd = fx.open(home);
            if (home_fd < 0) {
                _ = fx.mkdir(home);
                // Set ownership on home dir
                const hfd = fx.open(home);
                if (hfd >= 0) {
                    _ = fx.wstat(hfd, 0, entry.uid, entry.gid, fx.WSTAT_UID | fx.WSTAT_GID);
                    _ = fx.close(hfd);
                }
            } else {
                _ = fx.close(home_fd);
            }
        }

        // Set process identity
        _ = fx.setuid(entry.uid, entry.gid);

        // Load shell
        const shell = entry.shellSlice();
        const shell_path = if (shell.len > 0) shell else "/bin/fsh";

        const fd = fx.open(shell_path);
        if (fd < 0) {
            out.puts("login: cannot open shell\n");
            fx.sleep(2000);
            continue;
        }

        var total: usize = 0;
        while (total < elf_buf.len) {
            const n = fx.read(fd, elf_buf[total..]);
            if (n <= 0) break;
            total += @intCast(n);
        }
        _ = fx.close(fd);

        if (total == 0) {
            out.puts("login: empty shell binary\n");
            fx.sleep(2000);
            continue;
        }

        // exec replaces this process image but preserves uid/gid/fds
        _ = fx.exec(elf_buf[0..total]);

        // If exec failed, loop back to login prompt
        out.puts("login: exec failed\n");
        fx.sleep(2000);
    }

    fx.exit(0);
}
