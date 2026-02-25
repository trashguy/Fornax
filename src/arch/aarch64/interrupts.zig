/// AArch64 interrupt dispatch for GICv2.
///
/// Exports handleInterruptAa64 called from entry.S (vector 9 — user IRQ,
/// and kernel_irq handler). Maps GIC IRQs to a handler table compatible
/// with x86_64/riscv64 API.
///
/// IRQ mapping for timer compatibility:
///   Handler slot 0 = timer (PPI 30 on GIC, mapped to slot 0 like x86_64 PIT)
///   Handler slot N = GIC IRQ N (for SPIs like UART0 = 33)
const klog = @import("../../klog.zig");
const gic = @import("gic.zig");
const paging = @import("paging.zig");

// Force exceptions.zig into the compilation — entry.S references
// handleKernelException and handleUserException exported from there.
comptime {
    _ = @import("exceptions.zig");
}

/// IRQ handler function type. Returns true if it handled the IRQ.
pub const IrqHandler = *const fn () bool;

/// Handler table for GIC IRQs 0-63.
/// Each slot supports up to 2 handlers for IRQ sharing.
const MAX_HANDLERS_PER_IRQ: usize = 2;
var irq_handlers: [64][MAX_HANDLERS_PER_IRQ]?IrqHandler = [_][MAX_HANDLERS_PER_IRQ]?IrqHandler{
    [_]?IrqHandler{null} ** MAX_HANDLERS_PER_IRQ,
} ** 64;

/// Register an IRQ handler. Returns false if no slot available.
/// Slot 0 is used for the timer (GIC PPI 30 is internally mapped to slot 0).
pub fn registerIrqHandler(irq: u8, handler: IrqHandler) bool {
    if (irq >= 64) return false;
    for (&irq_handlers[irq]) |*slot| {
        if (slot.* == null) {
            slot.* = handler;
            return true;
        }
    }
    return false;
}

/// Dispatch handlers for the given internal IRQ slot.
fn dispatchSlot(slot: usize) void {
    if (slot >= 64) return;
    for (irq_handlers[slot]) |maybe_handler| {
        if (maybe_handler) |handler| {
            _ = handler();
        }
    }
}

/// Main interrupt handler — called from entry.S for both user and kernel IRQs.
export fn handleInterruptAa64() callconv(.c) void {
    // Increment per-core interrupt counter
    {
        const percpu = @import("../../percpu.zig");
        const core_id = percpu.getCoreId();
        percpu.percpu_array[core_id].interrupts += 1;
    }

    while (true) {
        const irq = gic.claim();
        if (irq >= 1020) break; // 1023 = spurious, 1022 = group 1

        @import("../../trace.zig").trace(.irq_enter, @truncate(irq));

        if (irq == 30) {
            // PPI 30 = physical timer → dispatch as slot 0 (timer)
            dispatchSlot(0);
        } else if (irq < 64) {
            // SPI or other PPI → dispatch by IRQ number
            dispatchSlot(irq);
        } else {
            klog.debug("GIC IRQ ");
            klog.debugDec(irq);
            klog.debug(": unhandled (>63)\n");
        }

        gic.complete(irq);

        @import("../../trace.zig").trace(.irq_exit, @truncate(irq));
    }
}

pub fn init() void {
    gic.init();
    paging.init();
    klog.info("aarch64: GIC + paging initialized\n");
}
