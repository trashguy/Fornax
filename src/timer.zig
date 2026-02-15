/// PIT tick counter for TCP retransmission timers.
///
/// Unmasks IRQ 0 (PIT) to get a ~18.2 Hz tick counter.
/// The default PIT frequency (~1.193 MHz / 65536 ≈ 18.2 Hz) is used as-is.
const pic = @import("pic.zig");
const interrupts = @import("arch/x86_64/interrupts.zig");

pub const TICKS_PER_SEC: u32 = 18;

var ticks: u32 = 0;

pub fn init() void {
    _ = interrupts.registerIrqHandler(0, handleIrq);
    pic.unmask(0);
}

pub fn getTicks() u32 {
    return ticks;
}

fn handleIrq() bool {
    ticks +%= 1;
    return true;
}
