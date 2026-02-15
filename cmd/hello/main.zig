/// hello — simple test program for Fornax.
const fx = @import("fornax");

export fn _start() noreturn {
    const out = fx.io.Writer.stdout;
    const args = fx.getArgs();

    if (args.len > 1) {
        out.puts("Hello");
        for (args[1..]) |arg| {
            out.putc(' ');
            // arg is [*:0]const u8, convert to slice
            var len: usize = 0;
            while (arg[len] != 0) : (len += 1) {}
            out.puts(arg[0..len]);
        }
        out.putc('\n');
    } else {
        out.puts("Hello from Fornax!\n");
    }
    fx.exit(0);
}
