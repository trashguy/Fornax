/// Timer tick counter for TCP retransmission and sleep.
///
/// x86_64: PIT IRQ 0 at ~18.2 Hz (default PIT frequency).
/// riscv64: CLINT via SBI set_timer at ~18 Hz (10 MHz timebase / 555555).
const builtin = @import("builtin");

const pic = switch (builtin.cpu.arch) {
    .x86_64 => @import("pic.zig"),
    else => struct {
        pub fn unmask(_: u8) void {}
    },
};

const interrupts = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/interrupts.zig"),
    .riscv64 => @import("arch/riscv64/interrupts.zig"),
    else => struct {
        pub fn registerIrqHandler(_: u8, _: anytype) bool {
            return false;
        }
    },
};

pub const TICKS_PER_SEC: u32 = 18;

/// CLINT timer interval for ~18 Hz at 10 MHz timebase
const CLINT_INTERVAL: u64 = 555555;

var ticks: u32 = 0;

pub fn init() void {
    _ = interrupts.registerIrqHandler(0, handleIrq);

    switch (builtin.cpu.arch) {
        .x86_64 => {
            pic.unmask(0);
        },
        .riscv64 => {
            // Program first timer interrupt via SBI
            const cpu = @import("arch/riscv64/cpu.zig");
            const now = cpu.rdtime();
            cpu.sbiSetTimer(now + CLINT_INTERVAL);
        },
        else => {},
    }
}

pub fn getTicks() u32 {
    return ticks;
}

fn handleIrq() bool {
    ticks +%= 1;

    // Re-arm timer on riscv64
    if (builtin.cpu.arch == .riscv64) {
        const cpu = @import("arch/riscv64/cpu.zig");
        const now = cpu.rdtime();
        cpu.sbiSetTimer(now + CLINT_INTERVAL);
    }

    // Wake processes whose sleep timer has expired
    const process = @import("process.zig");
    const table = process.getProcessTable();
    for (table) |*p| {
        if (p.state == .blocked and p.pending_op == .sleep) {
            if ((ticks -% p.sleep_until) < 0x8000_0000) {
                p.state = .ready;
            }
        }
    }

    return true;
}
