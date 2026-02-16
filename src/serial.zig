/// Serial I/O for QEMU.
/// x86_64: COM1 at I/O port 0x3F8. riscv64: 16550 UART at MMIO 0x10000000.
/// 115200 baud, 8N1. Output for debugging, input for console.
const builtin = @import("builtin");

const cpu = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/cpu.zig"),
    .riscv64 => @import("arch/riscv64/cpu.zig"),
    else => struct {
        pub fn outb(_: u16, _: u8) void {}
        pub fn inb(_: u16) u8 {
            return 0;
        }
    },
};

const COM1: u16 = 0x3F8;

// QEMU virt UART base address
const UART_BASE: u64 = 0x1000_0000;

const paging = switch (builtin.cpu.arch) {
    .riscv64 => @import("arch/riscv64/paging.zig"),
    else => struct {
        pub fn isInitialized() bool {
            return false;
        }
    },
};

const mem = @import("mem.zig");

/// Get effective UART MMIO address (higher-half after paging init).
inline fn uartAddr(offset: u64) u64 {
    const addr = UART_BASE + offset;
    return if (paging.isInitialized()) addr +% mem.KERNEL_VIRT_BASE else addr;
}

var initialized: bool = false;

pub fn init() void {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            cpu.outb(COM1 + 1, 0x00); // Disable all interrupts
            cpu.outb(COM1 + 3, 0x80); // Enable DLAB (set baud rate divisor)
            cpu.outb(COM1 + 0, 0x01); // Set divisor to 1 (115200 baud)
            cpu.outb(COM1 + 1, 0x00); //   (hi byte)
            cpu.outb(COM1 + 3, 0x03); // 8 bits, no parity, one stop bit (8N1)
            cpu.outb(COM1 + 2, 0xC7); // Enable FIFO, clear them, 14-byte threshold
            cpu.outb(COM1 + 4, 0x0B); // IRQs enabled, RTS/DSR set
        },
        .riscv64 => {
            // 16550 UART at MMIO address — same register layout as COM1
            cpu.mmioWrite8(uartAddr(1), 0x00); // Disable all interrupts
            cpu.mmioWrite8(uartAddr(3), 0x80); // Enable DLAB
            cpu.mmioWrite8(uartAddr(0), 0x01); // Divisor = 1 (115200)
            cpu.mmioWrite8(uartAddr(1), 0x00);
            cpu.mmioWrite8(uartAddr(3), 0x03); // 8N1
            cpu.mmioWrite8(uartAddr(2), 0xC7); // Enable FIFO
            cpu.mmioWrite8(uartAddr(4), 0x0B); // IRQs enabled, RTS/DSR
        },
        else => return,
    }

    initialized = true;
}

/// Enable receive interrupts and register handler.
pub fn enableRxInterrupt() void {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            const pic = @import("pic.zig");
            const interrupts = @import("arch/x86_64/interrupts.zig");

            // Enable "data available" interrupt (IER bit 0)
            cpu.outb(COM1 + 1, 0x01);

            // Register IRQ 4 handler
            _ = interrupts.registerIrqHandler(4, handleIrq);

            // Unmask IRQ 4 on PIC
            pic.unmask(4);
        },
        .riscv64 => {
            const plic = @import("arch/riscv64/plic.zig");
            const interrupts = @import("arch/riscv64/interrupts.zig");

            // Enable "data available" interrupt (IER bit 0)
            cpu.mmioWrite8(uartAddr(1), 0x01);

            // Register PLIC IRQ 10 handler (UART0 on QEMU virt)
            _ = interrupts.registerIrqHandler(10, handleIrq);

            // Enable IRQ 10 on PLIC
            plic.enable(10);
        },
        else => {},
    }
}

fn handleIrq() bool {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            const lsr = cpu.inb(COM1 + 5);
            if (lsr & 0x01 == 0) return false;

            const keyboard = @import("keyboard.zig");
            var count: u32 = 0;
            while (cpu.inb(COM1 + 5) & 0x01 != 0 and count < 16) {
                const byte = cpu.inb(COM1);
                keyboard.handleChar(byte);
                count += 1;
            }
            return count > 0;
        },
        .riscv64 => {
            const lsr = cpu.mmioRead8(uartAddr(5));
            if (lsr & 0x01 == 0) return false;

            const keyboard = @import("keyboard.zig");
            var count: u32 = 0;
            while (cpu.mmioRead8(uartAddr(5)) & 0x01 != 0 and count < 16) {
                const byte = cpu.mmioRead8(uartAddr(0));
                keyboard.handleChar(byte);
                count += 1;
            }
            return count > 0;
        },
        else => return false,
    }
}

pub fn putChar(c: u8) void {
    if (!initialized) return;

    switch (builtin.cpu.arch) {
        .x86_64 => {
            while (cpu.inb(COM1 + 5) & 0x20 == 0) {}
            cpu.outb(COM1, c);
        },
        .riscv64 => {
            while (cpu.mmioRead8(uartAddr(5)) & 0x20 == 0) {}
            cpu.mmioWrite8(uartAddr(0), c);
        },
        else => {},
    }
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
