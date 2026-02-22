/// mkdir — create directories.
const fx = @import("fornax");

const err = fx.io.Writer.stderr;

export fn _start() noreturn {
    const args = fx.getArgs();

    if (args.len <= 1) {
        err.puts("usage: mkdir [-p] dir...\n");
        fx.exit(1);
    }

    var create_parents = false;
    var start: usize = 1;

    // Check for -p flag
    if (args.len > 1) {
        var len: usize = 0;
        while (args[1][len] != 0) : (len += 1) {}
        if (len == 2 and args[1][0] == '-' and args[1][1] == 'p') {
            create_parents = true;
            start = 2;
        }
    }

    if (start >= args.len) {
        err.puts("usage: mkdir [-p] dir...\n");
        fx.exit(1);
    }

    for (args[start..]) |arg| {
        var len: usize = 0;
        while (arg[len] != 0) : (len += 1) {}
        const name = arg[0..len];

        if (create_parents) {
            mkdirp(name);
        } else {
            const result = fx.mkdir(name);
            if (result < 0) {
                err.print("mkdir: {s}: failed\n", .{name});
            }
        }
    }

    fx.exit(0);
}

/// Create directory and all parent directories as needed.
fn mkdirp(path: []const u8) void {
    if (path.len == 0) return;

    // Walk through each '/' and create intermediate directories
    var i: usize = 0;
    // Skip leading slash
    if (path[0] == '/') i = 1;

    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            // Create this prefix — ignore errors for existing dirs
            _ = fx.mkdir(path[0..i]);
        }
    }
}
