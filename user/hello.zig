const fornax = @import("fornax");

export fn _start() callconv(.naked) noreturn {
    // Call the actual main function — naked functions can't have local variables
    asm volatile ("call _main");
    unreachable;
}

export fn _main() callconv(.c) noreturn {
    _ = fornax.write(1, "Hello from Fornax userspace!\n");
    fornax.exit(0);
}
