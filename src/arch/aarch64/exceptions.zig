const console = @import("../../console.zig");
const cpu = @import("cpu.zig");

/// AArch64 exception vector table.
/// Must be 2048-byte aligned, with 16 entries at 128-byte intervals.
/// Each entry can hold up to 32 instructions.
///
/// Layout (4 groups of 4 vectors):
///   - Current EL with SP_EL0: Synchronous, IRQ, FIQ, SError
///   - Current EL with SP_ELx: Synchronous, IRQ, FIQ, SError
///   - Lower EL using AArch64:  Synchronous, IRQ, FIQ, SError
///   - Lower EL using AArch32:  Synchronous, IRQ, FIQ, SError
fn vectorTable() callconv(.naked) void {
    // We generate 16 vector entries, each 128 bytes (32 instructions) apart.
    // Each entry saves x0, x1, loads its vector index into x0, and branches to the common handler.
    comptime var i: u32 = 0;
    inline while (i < 16) : (i += 1) {
        asm volatile (
            \\.balign 128
            \\stp x29, x30, [sp, #-16]!
            \\mov x0, %[idx]
            \\bl exceptionEntry
            \\ldp x29, x30, [sp], #16
            \\eret
            :
            : [idx] "i" (i),
        );
    }
}

export fn exceptionEntry(vector_index: u64) void {
    handleException(vector_index);
}

const vector_names = [16][]const u8{
    "Sync (EL1t)",   "IRQ (EL1t)",   "FIQ (EL1t)",   "SError (EL1t)",
    "Sync (EL1h)",   "IRQ (EL1h)",   "FIQ (EL1h)",   "SError (EL1h)",
    "Sync (EL0/64)", "IRQ (EL0/64)", "FIQ (EL0/64)", "SError (EL0/64)",
    "Sync (EL0/32)", "IRQ (EL0/32)", "FIQ (EL0/32)", "SError (EL0/32)",
};

fn handleException(vector_index: u64) void {
    const esr = cpu.readEsr();
    const elr = cpu.readElr();
    const far = cpu.readFar();

    console.puts("\n--- EXCEPTION ---\n");

    if (vector_index < 16) {
        console.puts("Type: ");
        console.puts(vector_names[vector_index]);
    } else {
        console.puts("Vector: ");
        console.putDec(vector_index);
    }
    console.puts("\n");

    console.puts("ESR_EL1: ");
    console.putHex(esr);
    console.puts("\nELR_EL1: ");
    console.putHex(elr);
    console.puts("\nFAR_EL1: ");
    console.putHex(far);

    // Decode exception class from ESR bits [31:26]
    const ec = (esr >> 26) & 0x3F;
    console.puts("\nException class: ");
    console.putHex(ec);
    console.puts(" (");
    console.puts(switch (ec) {
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
    });
    console.puts(")\n");

    console.puts("--- Halting ---\n");
    cpu.halt();
}

pub fn init() void {
    // Install the vector table
    const vbar = @intFromPtr(&vectorTable);
    asm volatile ("msr vbar_el1, %[vbar]"
        :
        : [vbar] "r" (vbar),
    );
    cpu.isb();

    console.puts("aarch64: exception vectors installed\n");
}
