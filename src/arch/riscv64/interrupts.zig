/// RISC-V trap dispatch for exceptions and interrupts.
///
/// Exports handleExceptionRv and handleInterruptRv called from entry.S.
/// Maps PLIC external interrupts to a handler table compatible with x86_64 API.
const serial = @import("../../serial.zig");
const klog = @import("../../klog.zig");
const cpu = @import("cpu.zig");
const paging = @import("paging.zig");
const plic = @import("plic.zig");
const supervisor = @import("../../supervisor.zig");
const process = @import("../../process.zig");

/// IRQ handler function type. Returns true if it handled the IRQ.
pub const IrqHandler = *const fn () bool;

/// Handler table for PLIC IRQs 0-63.
/// Each slot supports up to 2 handlers for IRQ sharing.
const MAX_HANDLERS_PER_IRQ: usize = 2;
var irq_handlers: [64][MAX_HANDLERS_PER_IRQ]?IrqHandler = [_][MAX_HANDLERS_PER_IRQ]?IrqHandler{
    [_]?IrqHandler{null} ** MAX_HANDLERS_PER_IRQ,
} ** 64;

/// Register an IRQ handler. Returns false if no slot available.
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

/// Output a u64 as hex using only serial.putChar (no memory reads for strings).
inline fn inlineHex(val: u64) void {
    serial.putChar('0');
    serial.putChar('x');
    inline for (0..16) |i| {
        const shift: u6 = @intCast(60 - i * 4);
        const nibble: u4 = @intCast((val >> shift) & 0xF);
        const n: u8 = nibble;
        const c: u8 = if (n < 10) '0' + n else 'A' - 10 + n;
        serial.putChar(c);
    }
}

/// Exception handler — called from entry.S for synchronous exceptions.
/// a0=frame_ptr, a1=scause, a2=stval
export fn handleExceptionRv(frame_ptr: u64, scause: u64, stval: u64) callconv(.c) void {
    _ = frame_ptr; // frame is on the stack, entry.S manages it

    // Check if the fault came from user mode (SSTATUS.SPP == 0)
    const sstatus = cpu.csrRead(cpu.CSR_SSTATUS);
    const from_user = (sstatus & cpu.SSTATUS_SPP) == 0;

    if (from_user) {
        const sepc = cpu.csrRead(cpu.CSR_SEPC);
        klog.debug("\n--- USER EXCEPTION ---\n");
        klog.debug("SCAUSE: ");
        klog.debugHex(scause);
        klog.debug(" SEPC: ");
        klog.debugHex(sepc);
        klog.debug(" STVAL: ");
        klog.debugHex(stval);
        klog.debug("\n");

        if (process.getCurrent()) |proc| {
            const pid = proc.pid;
            _ = supervisor.handleProcessFault(pid);
            proc.state = .dead;

            klog.warn("[Process ");
            klog.warnDec(pid);
            klog.warn(" faulted: scause=");
            klog.warnHex(scause);
            klog.warn("]\n");

            process.scheduleNext();
        } else {
            klog.err("[User fault with no current process]\n");
            cpu.halt();
        }
    } else {
        // Kernel-mode fault — always fatal
        serial.putChar('\n');
        serial.putChar('s');
        serial.putChar('=');
        inlineHex(scause);
        serial.putChar(' ');
        serial.putChar('p');
        serial.putChar('=');
        inlineHex(cpu.csrRead(cpu.CSR_SEPC));
        serial.putChar(' ');
        serial.putChar('v');
        serial.putChar('=');
        inlineHex(stval);
        serial.putChar('\r');
        serial.putChar('\n');
        cpu.halt();
    }
}

/// Interrupt handler — called from entry.S for asynchronous interrupts.
/// a0=scause (with bit 63 set), a1=frame_ptr
export fn handleInterruptRv(scause: u64, frame_ptr: u64) callconv(.c) void {
    _ = frame_ptr;
    // Increment per-core interrupt counter
    {
        const percpu = @import("../../percpu.zig");
        const core_id = percpu.getCoreId();
        percpu.percpu_array[core_id].interrupts += 1;
    }
    const cause = scause & ~cpu.SCAUSE_INT_BIT;

    switch (cause) {
        5 => {
            // Supervisor timer interrupt
            // Dispatch to IRQ 0 handlers (timer, compatible with x86_64 PIT)
            for (irq_handlers[0]) |maybe_handler| {
                if (maybe_handler) |handler| {
                    _ = handler();
                }
            }
            // Clear timer interrupt pending (will be re-armed by timer handler)
            cpu.csrClear(cpu.CSR_SIP, cpu.SIE_STIE);
        },
        9 => {
            // Supervisor external interrupt (PLIC)
            while (true) {
                const irq = plic.claim();
                if (irq == 0) break; // No more pending interrupts

                if (irq < 64) {
                    var handled = false;
                    for (irq_handlers[irq]) |maybe_handler| {
                        if (maybe_handler) |handler| {
                            if (handler()) handled = true;
                        }
                    }
                    if (!handled) {
                        klog.debug("PLIC IRQ ");
                        klog.debugDec(irq);
                        klog.debug(": unhandled\n");
                    }
                }

                plic.complete(irq);
            }
        },
        else => {
            klog.debug("Unknown interrupt cause: ");
            klog.debugHex(cause);
            klog.debug("\n");
        },
    }
}

pub fn init() void {
    plic.init();
    paging.init();
    klog.info("riscv64: PLIC + Sv48 paging initialized\n");
}
