/// hello — simple test program for Fornax.
const fx = @import("fornax");

export fn _start() noreturn {
    _ = fx.write(1, "Hello from Fornax!\n");
    fx.exit(0);
}
