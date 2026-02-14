/// COM1 serial output (0x3F8) for QEMU `-serial stdio`.
/// 115200 baud, 8N1. Essential for debugging.
const cpu = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("arch/x86_64/cpu.zig"),
    else => struct {
        pub fn outb(_: u16, _: u8) void {}
        pub fn inb(_: u16) u8 {
            return 0;
        }
    },
};

const COM1: u16 = 0x3F8;

var initialized: bool = false;

pub fn init() void {
    if (@import("builtin").cpu.arch != .x86_64) return;

    cpu.outb(COM1 + 1, 0x00); // Disable all interrupts
    cpu.outb(COM1 + 3, 0x80); // Enable DLAB (set baud rate divisor)
    cpu.outb(COM1 + 0, 0x01); // Set divisor to 1 (115200 baud)
    cpu.outb(COM1 + 1, 0x00); //   (hi byte)
    cpu.outb(COM1 + 3, 0x03); // 8 bits, no parity, one stop bit (8N1)
    cpu.outb(COM1 + 2, 0xC7); // Enable FIFO, clear them, 14-byte threshold
    cpu.outb(COM1 + 4, 0x0B); // IRQs enabled, RTS/DSR set

    initialized = true;
}

pub fn putChar(c: u8) void {
    if (!initialized) return;

    // Wait for transmit buffer to be empty
    while (cpu.inb(COM1 + 5) & 0x20 == 0) {}
    cpu.outb(COM1, c);
}

pub fn puts(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') putChar('\r');
        putChar(c);
    }
}

pub fn putDec(val: u64) void {
    if (val == 0) {
        putChar('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var n = val;
    var i: usize = 0;
    while (n > 0) : (i += 1) {
        buf[i] = @intCast(n % 10 + '0');
        n /= 10;
    }
    while (i > 0) {
        i -= 1;
        putChar(buf[i]);
    }
}

pub fn putHex(val: u64) void {
    puts("0x");
    const hex = "0123456789ABCDEF";
    var started = false;
    var shift: u6 = 60;
    while (true) {
        const nibble: u4 = @intCast((val >> shift) & 0xF);
        if (nibble != 0) started = true;
        if (started) putChar(hex[nibble]);
        if (shift == 0) break;
        shift -= 4;
    }
    if (!started) putChar('0');
}
