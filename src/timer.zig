/// Timer tick counter for TCP retransmission and sleep.
///
/// x86_64: PIT IRQ 0 at ~18.2 Hz (default PIT frequency).
/// riscv64: CLINT via SBI set_timer at ~18 Hz (timebase / TICKS_PER_SEC).
const builtin = @import("builtin");

const rv_board = if (builtin.cpu.arch == .riscv64) @import("arch/riscv64/board/board.zig") else struct {
    pub const active = struct {
        pub const timer_freq: u32 = 0;
    };
};

const rv_fdt = if (builtin.cpu.arch == .riscv64) @import("arch/riscv64/fdt.zig") else struct {};

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

/// CLINT timer interval for ~18 Hz — default from board config, overridden
/// at init() if FDT provides a timebase-frequency.
const CLINT_INTERVAL_DEFAULT: u64 = if (builtin.cpu.arch == .riscv64)
    rv_board.active.timer_freq / TICKS_PER_SEC
else
    555555;

var clint_interval: u64 = CLINT_INTERVAL_DEFAULT;

/// Effective RISC-V timer frequency — FDT override or board default.
fn effectiveTimerFreq() u64 {
    if (builtin.cpu.arch != .riscv64) return 0;
    const fdt_freq = rv_fdt.fdt_config.timer_freq;
    if (fdt_freq != 0) return @as(u64, fdt_freq);
    return @as(u64, rv_board.active.timer_freq);
}

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
            // Override timer interval from FDT if available
            const fdt_freq = rv_fdt.fdt_config.timer_freq;
            if (fdt_freq != 0) {
                clint_interval = @as(u64, fdt_freq) / TICKS_PER_SEC;
            }
            // Program first timer interrupt via SBI
            const cpu = @import("arch/riscv64/cpu.zig");
            const now = cpu.rdtime();
            cpu.sbiSetTimer(now + clint_interval);
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
            const freq = effectiveTimerFreq();
            return cpu.rdtime() / (freq / 1000);
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
            const freq = effectiveTimerFreq();
            return cpu.rdtime() / (freq / 1_000_000);
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
        rearmRiscvTimer();
    }

    // Re-arm timer on aarch64 (per-core — PPI is private to each core)
    if (builtin.cpu.arch == .aarch64) {
        const cpu = @import("arch/aarch64/cpu.zig");
        cpu.writeCntpTval(arm_timer_interval);
    }

    // Only one core manages the global tick counter and sleep wakeups.
    // On Mars, core 0 busy-polls (no WFI/timer), so delegate to core 1.
    const tick_core: u32 = if (builtin.cpu.arch == .riscv64 and !rv_board.active.has_pci_ecam) 1 else 0;
    if (percpu.getCoreId() != tick_core) return true;

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

    // Poll UART RX on boards where the PLIC UART IRQ is disabled
    // (e.g. Milk-V Mars — U-Boot leaves UART in a state that floods IRQs).
    if (builtin.cpu.arch == .riscv64 and !rv_board.active.has_pci_ecam) {
        @import("serial.zig").pollRx();
    }

    // Check supervisor pending restarts and stability resets
    @import("supervisor.zig").timerTick(ticks);

    return true;
}

/// Re-arm the RISC-V timer. Safe to call from any context.
/// Exported so the scheduler idle loop can use it as a safety net.
pub fn rearmRiscvTimer() void {
    const cpu2 = @import("arch/riscv64/cpu.zig");
    const now = cpu2.rdtime();
    cpu2.sbiSetTimer(now + clint_interval);
}
