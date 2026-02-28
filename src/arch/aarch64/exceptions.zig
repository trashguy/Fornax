/// AArch64 exception handlers called from entry.S.
///
/// The vector table is in entry.S. These Zig functions handle the dispatched
/// exceptions for kernel faults and user-mode faults.
const klog = @import("../../klog.zig");
const cpu = @import("cpu.zig");
const serial = @import("../../serial.zig");

/// Handle a kernel-mode synchronous exception.
/// Called from entry.S vector 4 (Current EL, SP_ELx, Sync).
export fn handleKernelException(esr: u64, elr: u64, far: u64) callconv(.c) void {
    serial.putChar('\n');
    klog.err("--- KERNEL EXCEPTION ---\n");

    const ec = (esr >> 26) & 0x3F;
    klog.err("EC: ");
    klog.errHex(ec);
    klog.err(" (");
    klog.err(ecName(ec));
    klog.err(")\n");

    klog.err("ESR: ");
    klog.errHex(esr);
    klog.err("\nELR: ");
    klog.errHex(elr);
    klog.err("\nFAR: ");
    klog.errHex(far);
    klog.err("\n--- Halting ---\n");

    cpu.halt();
}

/// Handle a user-mode synchronous exception (non-SVC).
/// Called from entry.S for data aborts, instruction aborts, etc.
export fn handleUserException(esr: u64, elr: u64, far: u64, frame_ptr: u64) callconv(.c) void {
    _ = frame_ptr;

    const process = @import("../../process.zig");
    const supervisor = @import("../../supervisor.zig");

    const proc = process.getCurrent() orelse {
        klog.err("User exception with no current process!\n");
        cpu.halt();
        return;
    };

    // Silently discard faults from already-exited processes
    if (proc.state == .zombie or proc.state == .dead or proc.state == .free) {
        process.scheduleNext();
    }

    const ec = (esr >> 26) & 0x3F;
    klog.err("[PID ");
    klog.errDec(proc.pid);
    klog.err("] ");
    klog.err(ecName(ec));
    klog.err(" at ");
    klog.errHex(elr);
    klog.err(" (FAR=");
    klog.errHex(far);
    klog.err(")\n");

    // Attempt supervisor recovery
    _ = supervisor.handleProcessFault(proc.pid);

    // Kill the process
    proc.state = .dead;
    proc.exit_status = 128;

    // Container cleanup: update container state if init faulted
    if (proc.container_id != 0xFF) {
        const container = @import("../../container.zig");
        if (container.getById(proc.container_id)) |ct| {
            container.removeProcess(ct);
            if (ct.init_pid != null and ct.init_pid.? == proc.pid) {
                container.killAllProcessesExcept(ct, proc.pid);
                ct.state = .failed;
                ct.init_pid = null;
            }
        }
    }

    // Kill orphaned children (Fornax orphan policy)
    process.killChildren(proc.pid);

    // Wake parent if waiting
    if (proc.parent_pid) |ppid| {
        const table = process.getProcessTable();
        if (ppid < process.MAX_PROCESSES) {
            const parent = &table[ppid];
            if (parent.state == .blocked and parent.waiting_for_pid != null) {
                const wait_pid = parent.waiting_for_pid.?;
                if (wait_pid == 0 or wait_pid == proc.pid) {
                    process.markReady(parent);
                }
            }
        }
    }

    process.scheduleNext();
}

fn ecName(ec: u64) []const u8 {
    return switch (ec) {
        0x00 => "Unknown",
        0x01 => "WFI/WFE trapped",
        0x15 => "SVC (AArch64)",
        0x18 => "MSR/MRS/System trapped",
        0x20 => "Instruction abort (lower EL)",
        0x21 => "Instruction abort (same EL)",
        0x24 => "Data abort (lower EL)",
        0x25 => "Data abort (same EL)",
        0x2C => "FP/SIMD trapped",
        else => "Other",
    };
}
