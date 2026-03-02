/// Timer tick counter for TCP retransmission and sleep.
///
/// x86_64: PIT IRQ 0 at ~18.2 Hz (default PIT frequency).
/// riscv64: CLINT via SBI set_timer at ~18 Hz (10 MHz timebase / 555555).
const builtin = @import("builtin");

const tsc = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/tsc.zig"),
    else => struct {},
};

const pic = switch (builtin.cpu.arch) {
    .x86_64 => @import("pic.zig"),
    else => struct {
        pub fn unmask(_: u8) void {}
    },
};

const interrupts = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/interrupts.zig"),
    .riscv64 => @import("arch/riscv64/interrupts.zig"),
    .aarch64 => @import("arch/aarch64/interrupts.zig"),
    else => struct {
        pub fn registerIrqHandler(_: u8, _: anytype) bool {
            return false;
        }
    },
};

pub const TICKS_PER_SEC: u32 = 18;

/// CLINT timer interval for ~18 Hz at 10 MHz timebase
const CLINT_INTERVAL: u64 = 555555;

/// Generic Timer interval (computed at init from CNTFRQ_EL0)
var arm_timer_interval: u32 = 0;

var ticks: u32 = 0;

pub fn init() void {
    _ = interrupts.registerIrqHandler(0, handleIrq);

    switch (builtin.cpu.arch) {
        .x86_64 => {
            tsc.calibrate();
            pic.unmask(0);
        },
        .riscv64 => {
            // Program first timer interrupt via SBI
            const cpu = @import("arch/riscv64/cpu.zig");
            const now = cpu.rdtime();
            cpu.sbiSetTimer(now + CLINT_INTERVAL);
        },
        .aarch64 => {
            // ARM Generic Timer: compute interval from CNTFRQ_EL0
            const cpu = @import("arch/aarch64/cpu.zig");
            const freq = cpu.readCntfrq();
            arm_timer_interval = @intCast(freq / TICKS_PER_SEC);
            cpu.writeCntpTval(arm_timer_interval);
            cpu.writeCntpCtl(1); // ENABLE=1, IMASK=0

            // Enable GIC PPI 30 (physical timer)
            const gic = @import("arch/aarch64/gic.zig");
            gic.enable(30);
        },
        else => {},
    }
}

pub fn getTicks() u32 {
    return ticks;
}

pub fn getMillis() u64 {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            if (tsc.isCalibrated()) return tsc.getMillis();
            return @as(u64, ticks) * 1000 / TICKS_PER_SEC;
        },
        .riscv64 => {
            const cpu = @import("arch/riscv64/cpu.zig");
            return cpu.rdtime() / 10_000; // 10 MHz timebase
        },
        .aarch64 => {
            const cpu = @import("arch/aarch64/cpu.zig");
            const cnt = cpu.readCntvct();
            const freq = cpu.readCntfrq();
            if (freq == 0) return ticks * 1000 / TICKS_PER_SEC;
            return cnt * 1000 / freq;
        },
        else => {
            return @as(u64, ticks) * 1000 / TICKS_PER_SEC;
        },
    }
}

pub fn getMicros() u64 {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            if (tsc.isCalibrated()) return tsc.getMicros();
            return @as(u64, ticks) * 1_000_000 / TICKS_PER_SEC;
        },
        .riscv64 => {
            const cpu = @import("arch/riscv64/cpu.zig");
            return cpu.rdtime() / 10; // 10 MHz timebase → µs
        },
        .aarch64 => {
            const cpu = @import("arch/aarch64/cpu.zig");
            const cnt = cpu.readCntvct();
            const freq = cpu.readCntfrq();
            if (freq == 0) return @as(u64, ticks) * 1_000_000 / TICKS_PER_SEC;
            return cnt * 1_000_000 / freq;
        },
        else => {
            return @as(u64, ticks) * 1_000_000 / TICKS_PER_SEC;
        },
    }
}

fn handleIrq() bool {
    const percpu = @import("percpu.zig");

    // Re-arm timer on riscv64 (per-core — each core's timer is private)
    if (builtin.cpu.arch == .riscv64) {
        const cpu = @import("arch/riscv64/cpu.zig");
        const now = cpu.rdtime();
        cpu.sbiSetTimer(now + CLINT_INTERVAL);
    }

    // Re-arm timer on aarch64 (per-core — PPI is private to each core)
    if (builtin.cpu.arch == .aarch64) {
        const cpu = @import("arch/aarch64/cpu.zig");
        cpu.writeCntpTval(arm_timer_interval);
    }

    // Only BSP manages the global tick counter, sleep wakeups, and
    // supervisor checks.  On SMP, each core's timer PPI fires
    // independently — without this guard, ticks advances N× too fast
    // and sleep durations are wrong.
    if (percpu.getCoreId() != 0) return true;

    ticks +%= 1;
    @import("trace.zig").trace(.timer_tick, @truncate(ticks));

    // Wake processes whose sleep timer has expired
    const process = @import("process.zig");
    const table = process.getProcessTable();
    for (table) |*p| {
        if (p.state == .blocked and (p.pending_op == .sleep or p.pending_op == .poll_wait)) {
            if ((ticks -% p.sleep_until) < 0x8000_0000) {
                process.markReady(p);
            }
        }
    }

    // Poll USB HID events (x86_64 only)
    if (builtin.cpu.arch == .x86_64) {
        const xhci = @import("xhci.zig");
        xhci.pollUsbHid();
    }

    // Check supervisor pending restarts and stability resets
    @import("supervisor.zig").timerTick(ticks);

    return true;
}
