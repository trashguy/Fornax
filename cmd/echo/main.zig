/// echo — print arguments to stdout.
const fx = @import("fornax");

export fn _start() noreturn {
    const args = fx.getArgs();
    for (args[1..], 0..) |arg, i| {
        if (i > 0) _ = fx.write(1, " ");
        var len: usize = 0;
        while (arg[len] != 0) : (len += 1) {}
        _ = fx.write(1, arg[0..len]);
    }
    _ = fx.write(1, "\n");
    fx.exit(0);
}
