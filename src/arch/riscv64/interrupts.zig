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

/// Assembly trap entry point from entry.S — needed for early STVEC setup.
extern fn trap_entry() callconv(.naked) void;

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

/// Direct UART write — bypasses serial module entirely (no spinlock).
/// Uses the higher-half kernel address so it works with ANY page table
/// (user process tables don't have the identity map, but do have higher-half).
/// Safe to call from trap handlers, switchTo, and interrupt context.
pub fn rawPutChar(c: u8) void {
    const mem = @import("../../mem.zig");
    const base = @as(u64, 0x10000000) +% mem.KERNEL_VIRT_BASE;
    @as(*volatile u8, @ptrFromInt(base)).* = c;
}

/// Output a u64 as hex using raw UART writes (no serial module, no LSR polling).
pub fn rawHex(val: u64) void {
    rawPutChar('0');
    rawPutChar('x');
    inline for (0..16) |i| {
        const shift: u6 = @intCast(60 - i * 4);
        const nibble: u4 = @intCast((val >> shift) & 0xF);
        const n: u8 = nibble;
        const c: u8 = if (n < 10) '0' + n else 'A' - 10 + n;
        rawPutChar(c);
    }
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
    // Debug: 'E' = exception handler entered (raw UART, no dependencies)
    rawPutChar('E');
    rawPutChar('=');
    rawHex(scause);
    rawPutChar(' ');

    const frame: [*]const u64 = @ptrFromInt(frame_ptr);

    // Check if the fault came from user mode (SSTATUS.SPP == 0)
    const sstatus = cpu.csrRead(cpu.CSR_SSTATUS);
    const from_user = (sstatus & cpu.SSTATUS_SPP) == 0;

    if (from_user) {
        // On SMP, a process that already exited (.zombie/.dead) can still
        // be on a run queue from a stale push. When scheduled, it resumes
        // at stale user-mode RIP and faults. Silently discard these.
        if (process.getCurrent()) |proc| {
            switch (proc.state) {
                .zombie, .dead, .free => {
                    process.scheduleNext();
                },
                else => {},
            }
        }

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

            klog.warn("[Process ");
            klog.warnDec(pid);
            klog.warn(" faulted: scause=");
            klog.warnHex(scause);
            klog.warn("]\n");

            // Mark dead with exit status. sysWait reaps .dead children.
            proc.exit_status = 128;
            proc.state = .dead;

            // Process group cleanup: decrement count on fault
            if (proc.group_id != 0xFF) {
                const pg = @import("../../process_group.zig");
                if (pg.getById(proc.group_id)) |g| {
                    pg.removeProcess(g);
                }
            }

            // Kill orphaned children (Fornax orphan policy)
            process.killChildren(proc.pid);

            // Wake parent if it's blocked in wait() for this child
            if (proc.parent_pid) |ppid| {
                if (process.getByPid(ppid)) |parent| {
                    if (parent.state == .blocked) {
                        if (parent.waiting_for_pid) |wait_pid| {
                            if (wait_pid == proc.pid or wait_pid == 0) {
                                const child_pid: u64 = proc.pid;
                                parent.syscall_ret = (child_pid << 32) | (128 << 8);
                                process.markReady(parent);
                                parent.waiting_for_pid = null;
                            }
                        }
                    }
                }
            }

            process.scheduleNext();
        } else {
            klog.err("[User fault with no current process]\n");
            cpu.halt();
        }
    } else {
        // Kernel-mode fault — use raw UART writes (no serial module) to
        // avoid double-faulting if the UART is inaccessible through paging.
        rawPutChar('\r');
        rawPutChar('\n');
        rawPutChar('!');
        rawPutChar('K');
        rawPutChar('F');
        rawPutChar(' ');
        rawPutChar('s');
        rawPutChar('=');
        rawHex(scause);
        rawPutChar(' ');
        rawPutChar('p');
        rawPutChar('=');
        rawHex(cpu.csrRead(cpu.CSR_SEPC));
        rawPutChar(' ');
        rawPutChar('v');
        rawPutChar('=');
        rawHex(stval);
        rawPutChar('\r');
        rawPutChar('\n');
        rawPutChar('r');
        rawPutChar('a');
        rawPutChar('=');
        rawHex(frame[0]); // ra = x1
        rawPutChar(' ');
        rawPutChar('s');
        rawPutChar('0');
        rawPutChar('=');
        rawHex(frame[7]); // s0 = x8
        rawPutChar(' ');
        rawPutChar('a');
        rawPutChar('0');
        rawPutChar('=');
        rawHex(frame[9]); // a0 = x10
        rawPutChar('\r');
        rawPutChar('\n');

        // Halt — don't attempt recovery (percpu not yet initialized at boot)
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
    @import("../../trace.zig").trace(.irq_enter, @truncate(cause));

    switch (cause) {
        1 => {
            // Supervisor software interrupt (IPI from SBI sIPI)
            // Clear SSIP to acknowledge
            cpu.csrClear(cpu.CSR_SIP, cpu.SIE_SSIE);
            // Check TLB shootdown request
            const percpu = @import("../../percpu.zig");
            const core_id = percpu.getCoreId();
            if (@atomicLoad(bool, &percpu.percpu_array[core_id].tlb_flush_pending, .acquire)) {
                cpu.sfenceVma();
                @atomicStore(bool, &percpu.percpu_array[core_id].tlb_flush_pending, false, .release);
            }
            // Schedule IPI: no explicit action needed — returning from interrupt
            // allows the core to call scheduleNext on its next scheduling point.
        },
        5 => {
            // Supervisor timer interrupt
            // Dispatch to IRQ 0 handlers (timer, compatible with x86_64 PIT)
            for (irq_handlers[0]) |maybe_handler| {
                if (maybe_handler) |handler| {
                    _ = handler();
                }
            }
            // Note: sbiSetTimer already clears STIP as a side effect.
            // Do NOT csrClear SIP here — on some implementations the
            // SIE_STIE constant (bit 5) could alias the wrong CSR field.
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
    @import("../../trace.zig").trace(.irq_exit, @truncate(cause));
}

pub fn init() void {
    plic.init();

    // Set STVEC early so paging faults go to our handler, not OpenSBI.
    // Must set SSCRATCH=0 first (S-mode trap protocol in entry.S).
    cpu.csrWrite(cpu.CSR_SSCRATCH, 0);
    cpu.csrWrite(cpu.CSR_STVEC, @intFromPtr(&trap_entry));

    paging.init();
    klog.info("riscv64: PLIC + Sv39 paging initialized\n");
}
