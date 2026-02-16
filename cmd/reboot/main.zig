const fx = @import("fornax");
const out = fx.io.Writer.stdout;

export fn _start() noreturn {
    out.puts("System going down for reboot NOW\n");
    fx.reboot();
}
