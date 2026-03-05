const serial = @import("../../serial.zig");
const klog = @import("../../klog.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const cpu = @import("cpu.zig");
const paging = @import("paging.zig");
const supervisor = @import("../../supervisor.zig");
const process = @import("../../process.zig");
const pic = @import("../../pic.zig");
const apic = @import("apic.zig");

const exception_names = [_][]const u8{
    "Division Error", // 0
    "Debug", // 1
    "NMI", // 2
    "Breakpoint", // 3
    "Overflow", // 4
    "Bound Range Exceeded", // 5
    "Invalid Opcode", // 6
    "Device Not Available", // 7
    "Double Fault", // 8
    "Coprocessor Segment", // 9
    "Invalid TSS", // 10
    "Segment Not Present", // 11
    "Stack-Segment Fault", // 12
    "General Protection Fault", // 13
    "Page Fault", // 14
    "Reserved", // 15
    "x87 Floating-Point", // 16
    "Alignment Check", // 17
    "Machine Check", // 18
    "SIMD Floating-Point", // 19
    "Virtualization", // 20
    "Control Protection", // 21
    "Reserved", // 22
    "Reserved", // 23
    "Reserved", // 24
    "Reserved", // 25
    "Reserved", // 26
    "Reserved", // 27
    "Hypervisor Injection", // 28
    "VMM Communication", // 29
    "Security Exception", // 30
    "Reserved", // 31
};

/// IRQ handler function type. Returns true if it handled the IRQ.
pub const IrqHandler = *const fn () bool;

/// Handler table for IRQs 0-15 (vectors 32-47).
/// Each slot supports up to 2 handlers for IRQ sharing.
const MAX_HANDLERS_PER_IRQ: usize = 2;
var irq_handlers: [16][MAX_HANDLERS_PER_IRQ]?IrqHandler = [_][MAX_HANDLERS_PER_IRQ]?IrqHandler{
    [_]?IrqHandler{null} ** MAX_HANDLERS_PER_IRQ,
} ** 16;

/// Register an IRQ handler. Returns false if no slot available.
pub fn registerIrqHandler(irq: u8, handler: IrqHandler) bool {
    if (irq >= 16) return false;
    for (&irq_handlers[irq]) |*slot| {
        if (slot.* == null) {
            slot.* = handler;
            return true;
        }
    }
    return false;
}

/// Generic vector handler table for dynamic vectors (48-252).
/// Used by MSI-X and IOAPIC-routed interrupts. LAPIC EOI is sent by the dispatcher.
pub const VectorHandler = *const fn () bool;
var vector_handlers: [256]?VectorHandler = [_]?VectorHandler{null} ** 256;

/// Register a handler for a specific LAPIC vector (typically 48-252).
/// Returns false if the vector already has a handler.
pub fn registerVectorHandler(vector: u8, handler: VectorHandler) bool {
    if (vector_handlers[vector] != null) return false;
    vector_handlers[vector] = handler;
    return true;
}

/// Unregister a handler for a specific vector.
pub fn unregisterVectorHandler(vector: u8) void {
    vector_handlers[vector] = null;
}

/// Output a u64 as hex using only serial.putChar and arithmetic (no memory reads).
/// Avoids both serial.putHex (function call) and string literals (.rodata access).
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

pub fn handleException(frame: *idt.ExceptionFrame) void {
    // IPI dispatch (vectors 253-255, LAPIC-sourced)
    if (frame.vector >= 253) {
        switch (frame.vector) {
            253 => {
                // TLB shootdown IPI — flush TLB if pending
                const percpu = @import("../../percpu.zig");
                const my_core = percpu.getCoreId();
                if (@atomicLoad(bool, &percpu.percpu_array[my_core].tlb_flush_pending, .acquire)) {
                    cpu.flushTlb();
                    @atomicStore(bool, &percpu.percpu_array[my_core].tlb_flush_pending, false, .release);
                }
            },
            254 => {
                // Schedule IPI — wakes core from hlt; run queue checked in scheduler loop
            },
            255 => {
                // Spurious APIC vector — no action needed
                return; // No EOI for spurious
            },
            else => {},
        }
        apic.sendEoi();
        return;
    }

    // IRQ dispatch (vectors 32-47)
    if (frame.vector >= 32 and frame.vector < 48) {
        // Increment per-core interrupt counter
        {
            const percpu = @import("../../percpu.zig");
            const core_id = percpu.getCoreId();
            percpu.percpu_array[core_id].interrupts += 1;
        }
        const irq: u8 = @intCast(frame.vector - 32);
        @import("../../trace.zig").trace(.irq_enter, irq);
        var handled = false;

        for (irq_handlers[irq]) |maybe_handler| {
            if (maybe_handler) |handler| {
                if (handler()) handled = true;
            }
        }

        if (!handled) {
            klog.debug("IRQ ");
            klog.debugDec(irq);
            klog.debug(": unhandled\n");
        }

        @import("../../trace.zig").trace(.irq_exit, irq);
        pic.sendEoi(irq);
        return;
    }

    // Dynamic vector dispatch (vectors 48-252) — MSI-X and IOAPIC-routed interrupts
    if (frame.vector >= 48 and frame.vector < 253) {
        {
            const percpu = @import("../../percpu.zig");
            const core_id = percpu.getCoreId();
            percpu.percpu_array[core_id].interrupts += 1;
        }
        const vec: u8 = @intCast(frame.vector);
        if (vector_handlers[vec]) |handler| {
            _ = handler();
        } else {
            klog.debug("Vector ");
            klog.debugDec(vec);
            klog.debug(": unhandled\n");
        }
        apic.sendEoi();
        return;
    }

    // Check if the fault came from user mode (RPL=3 in CS)
    const from_user = (frame.cs & 3) == 3;

    if (from_user) {
        // On SMP, a process that already exited (.zombie/.dead) can still
        // be on a run queue from a stale push. When scheduled, it resumes
        // at stale user-mode RIP and faults. Silently discard these —
        // the process is already dead, no logging or state change needed.
        if (process.getCurrent()) |proc| {
            switch (proc.state) {
                .zombie, .dead, .free => {
                    process.scheduleNext();
                },
                else => {},
            }
        }

        // User-mode fault — kill the process, don't panic the kernel
        klog.debug("\n--- USER EXCEPTION ---\n");
        klog.debug("Vector: ");
        klog.debugDec(frame.vector);
        klog.debug(" (");
        if (frame.vector < 32) {
            klog.debug(exception_names[frame.vector]);
        }
        klog.debug(")\nRIP: ");
        klog.debugHex(frame.rip);
        klog.debug("\n");

        if (frame.vector == 14) {
            klog.debug("CR2: ");
            klog.debugHex(cpu.readCr2());
            klog.debug("\n");
        }

        // Get the faulting process
        if (process.getCurrent()) |proc| {
            const pid = proc.pid;

            // Try supervisor restart for supervised services
            _ = supervisor.handleProcessFault(pid);

            klog.warn("[Process ");
            klog.warnDec(pid);
            klog.warn(" faulted: ");
            if (frame.vector < 32) {
                klog.warn(exception_names[frame.vector]);
            }
            klog.warn("]\n");

            // Mark dead with exit status. sysWait reaps .dead children.
            // We avoid calling the full sysExit() to keep stack usage minimal
            // on the 16 KB kernel stack (exception frame + handler locals).
            proc.exit_status = @truncate(128 + frame.vector);
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
                                const status: u64 = 128 + frame.vector;
                                parent.syscall_ret = (child_pid << 32) | ((status & 0xFF) << 8);
                                process.markReady(parent);
                                parent.waiting_for_pid = null;
                            }
                        }
                    }
                }
            }

            process.scheduleNext();
        } else {
            // No current process — shouldn't happen, but handle gracefully
            klog.err("[User fault with no current process]\n");
            cpu.halt();
        }
    } else {
        // Kernel-mode fault — attempt recovery instead of halting the core.
        // Print diagnostics via putChar (no locks, no .rodata pointers).
        serial.putChar('\n');
        serial.putChar('r');
        serial.putChar('=');
        inlineHex(frame.rip);
        serial.putChar(' ');
        serial.putChar('v');
        serial.putChar('=');
        inlineHex(frame.vector);
        serial.putChar(' ');
        serial.putChar('e');
        serial.putChar('=');
        inlineHex(frame.error_code);
        serial.putChar(' ');
        serial.putChar('s');
        serial.putChar('=');
        inlineHex(frame.rsp);
        if (frame.vector == 14) {
            serial.putChar(' ');
            serial.putChar('c');
            serial.putChar('=');
            inlineHex(cpu.readCr2());
        }
        // Print address of this function for base calculation
        serial.putChar(' ');
        serial.putChar('h');
        serial.putChar('=');
        inlineHex(@intFromPtr(&handleException));
        serial.putChar('\r');
        serial.putChar('\n');
        // Dump the 5-QWORD IRETQ frame at frame.rsp (only for #GP on iretq)
        if (frame.vector == 13 and frame.rsp >= 0xFFFF_8000_0000_0000) {
            const iret_frame: [*]const u64 = @ptrFromInt(frame.rsp);
            // iret[0]=RIP iret[1]=CS iret[2]=RFLAGS iret[3]=RSP iret[4]=SS
            serial.putChar('I');
            serial.putChar(':');
            inlineHex(iret_frame[0]); // RIP
            serial.putChar(' ');
            inlineHex(iret_frame[1]); // CS
            serial.putChar(' ');
            inlineHex(iret_frame[2]); // RFLAGS
            serial.putChar(' ');
            inlineHex(iret_frame[3]); // RSP
            serial.putChar(' ');
            inlineHex(iret_frame[4]); // SS
            serial.putChar('\r');
            serial.putChar('\n');
        }

        // Try to recover instead of halting.
        // Use per-core guard to prevent infinite recursion if the very
        // next switchTo also faults.
        const percpu = @import("../../percpu.zig");
        const my_core = percpu.getCoreId();
        if (percpu.percpu_array[my_core].in_fault_recovery) {
            // Already recovering — recursive fault, must halt.
            cpu.halt();
        }
        percpu.percpu_array[my_core].in_fault_recovery = true;

        // Kill the current process (if any). This may be an innocent
        // process that switchTo was about to resume, but we can't
        // safely continue its execution after a kernel fault.
        // sendToServer has guards to skip dead server_waiters entries.
        if (process.getCurrent()) |proc| {
            proc.state = .dead;
            percpu.percpu_array[my_core].current = null;
        }

        // Switch to kernel page tables (identity + higher-half) so
        // scheduleNext runs with a known-good CR3.
        paging.switchToKernel();

        // Leave in_fault_recovery set — it will catch any immediate
        // recursive fault in the next switchTo. It's cleared by
        // successful iretq/sysretq (never reached from here) or
        // will be set back to false if scheduleNext finds a good
        // process. Since scheduleNext is noreturn, we clear it just
        // before so the NEXT context switch can attempt recovery too.
        percpu.percpu_array[my_core].in_fault_recovery = false;

        process.scheduleNext();
    }
}

pub fn init() void {
    gdt.init();
    idt.init();
    paging.init();
    cpu.initPAT();
    klog.info("x86_64: GDT + IDT + paging initialized\n");
}
