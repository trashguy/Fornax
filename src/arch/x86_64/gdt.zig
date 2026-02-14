const console = @import("../../console.zig");
const pmm = @import("../../pmm.zig");

const GdtEntry = packed struct {
    limit_low: u16,
    base_low: u16,
    base_mid: u8,
    access: u8,
    flags_limit_high: u8,
    base_high: u8,
};

const GdtPtr = packed struct {
    limit: u16,
    base: u64,
};

/// TSS structure for x86_64.
/// Must be exactly 104 bytes with specific field layout per Intel SDM.
pub const Tss = packed struct {
    reserved0: u32 = 0,
    /// RSP values for privilege level transitions.
    rsp0: u64 = 0,
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    reserved1: u64 = 0,
    /// IST (Interrupt Stack Table) entries.
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    reserved2: u64 = 0,
    reserved3: u16 = 0,
    iopb_offset: u16 = 104, // sizeof(Tss)
};

comptime {
    if (@bitSizeOf(Tss) != 104 * 8) @compileError("TSS must be 104 bytes (832 bits)");
}

/// GDT layout:
///   0: 0x00 - Null
///   1: 0x08 - Kernel Code (DPL=0)
///   2: 0x10 - Kernel Data (DPL=0)
///   3: 0x18 - User Data (DPL=3) — must come BEFORE user code for SYSCALL/SYSRET
///   4: 0x20 - User Code (DPL=3)
///   5-6: 0x28 - TSS (takes two GDT slots)
///
/// SYSCALL/SYSRET convention (AMD64):
///   STAR[47:32] = kernel CS selector = 0x08
///   STAR[63:48] = user CS base selector = 0x18
///     SYSRET loads CS = STAR[63:48] + 16 = 0x28... wait, that's wrong.
///
/// Actually, SYSRET loads:
///   CS = STAR[63:48] + 16 (for 64-bit mode)
///   SS = STAR[63:48] + 8
/// So if we want user CS=0x20 and user SS=0x18:
///   STAR[63:48] = 0x08 (then SS=0x08+8=0x10... no)
///
/// Let me re-derive. For SYSRET in 64-bit mode:
///   CS = STAR[63:48] + 16
///   SS = STAR[63:48] + 8
/// We want CS=0x20, SS=0x18:
///   STAR[63:48] + 16 = 0x20 → STAR[63:48] = 0x10
///   STAR[63:48] + 8  = 0x18 ✓
///
/// For SYSCALL:
///   CS = STAR[47:32]
///   SS = STAR[47:32] + 8
/// We want CS=0x08, SS=0x10:
///   STAR[47:32] = 0x08 ✓
///
/// So: STAR = (0x10 << 48) | (0x08 << 32)
/// But selectors need DPL in their RPL bits for user mode. SYSRET automatically
/// ORs RPL=3 into the loaded selectors.
pub const KERNEL_CS: u16 = 0x08;
pub const KERNEL_DS: u16 = 0x10;
pub const USER_DS: u16 = 0x18 | 3; // with RPL=3
pub const USER_CS: u16 = 0x20 | 3; // with RPL=3
pub const TSS_SEL: u16 = 0x28;

// 7 entries: null + kernel code + kernel data + user data + user code + TSS (2 slots)
var gdt_entries: [7]GdtEntry = .{
    // 0: Null
    .{ .limit_low = 0, .base_low = 0, .base_mid = 0, .access = 0, .flags_limit_high = 0, .base_high = 0 },
    // 1: Kernel Code 0x08: DPL=0, 64-bit, exec+read
    .{ .limit_low = 0xFFFF, .base_low = 0, .base_mid = 0, .access = 0x9A, .flags_limit_high = 0xAF, .base_high = 0 },
    // 2: Kernel Data 0x10: DPL=0, writable
    .{ .limit_low = 0xFFFF, .base_low = 0, .base_mid = 0, .access = 0x92, .flags_limit_high = 0xCF, .base_high = 0 },
    // 3: User Data 0x18: DPL=3, writable
    //    access = 0xF2 (present=1, DPL=3, S=1, type=data writable)
    .{ .limit_low = 0xFFFF, .base_low = 0, .base_mid = 0, .access = 0xF2, .flags_limit_high = 0xCF, .base_high = 0 },
    // 4: User Code 0x20: DPL=3, 64-bit, exec+read
    //    access = 0xFA (present=1, DPL=3, S=1, type=code exec+read)
    .{ .limit_low = 0xFFFF, .base_low = 0, .base_mid = 0, .access = 0xFA, .flags_limit_high = 0xAF, .base_high = 0 },
    // 5-6: TSS — filled in at runtime
    .{ .limit_low = 0, .base_low = 0, .base_mid = 0, .access = 0, .flags_limit_high = 0, .base_high = 0 },
    .{ .limit_low = 0, .base_low = 0, .base_mid = 0, .access = 0, .flags_limit_high = 0, .base_high = 0 },
};

var gdt_ptr: GdtPtr = undefined;
var tss: Tss = .{};

pub fn init() void {
    // Allocate a kernel stack for the TSS (used when transitioning from Ring 3 → Ring 0)
    const kernel_stack_page = pmm.allocPage() orelse {
        console.puts("GDT: failed to alloc TSS kernel stack!\n");
        return;
    };
    // Stack grows down, point to top of page
    tss.rsp0 = kernel_stack_page + 4096;

    // Set up TSS descriptor (occupies two GDT entries)
    const tss_addr = @intFromPtr(&tss);
    const tss_limit: u32 = @bitSizeOf(Tss) / 8 - 1; // 103

    // Low entry (index 5)
    gdt_entries[5] = .{
        .limit_low = @truncate(tss_limit),
        .base_low = @truncate(tss_addr),
        .base_mid = @truncate(tss_addr >> 16),
        .access = 0x89, // present, type=available 64-bit TSS
        .flags_limit_high = @truncate((tss_limit >> 16) & 0x0F),
        .base_high = @truncate(tss_addr >> 24),
    };

    // High entry (index 6): upper 32 bits of base address
    const tss_high: u32 = @truncate(tss_addr >> 32);
    gdt_entries[6] = @bitCast(
        @as(u64, tss_high) | (@as(u64, 0) << 32),
    );

    gdt_ptr = .{
        .limit = @sizeOf(@TypeOf(gdt_entries)) - 1,
        .base = @intFromPtr(&gdt_entries),
    };

    // Load GDT
    asm volatile ("lgdt (%[gdt_ptr])"
        :
        : [gdt_ptr] "r" (&gdt_ptr),
    );

    // Reload segment registers with new kernel selectors
    reloadSegments();

    // Load TSS
    asm volatile ("ltr %[sel]"
        :
        : [sel] "r" (TSS_SEL),
    );

    console.puts("GDT: loaded (7 entries + TSS)\n");
}

/// Update the kernel stack pointer in the TSS.
/// Called during context switch so that interrupts from Ring 3 use the correct stack.
pub fn setKernelStack(stack_top: u64) void {
    tss.rsp0 = stack_top;
}

fn reloadSegments() void {
    // Reload CS via far return
    asm volatile (
        \\push $0x08
        \\lea 1f(%%rip), %%rax
        \\push %%rax
        \\lretq
        \\1:
        :
        :
        : .{ .rax = true, .memory = true }
    );

    // Reload data segment registers
    asm volatile (
        \\mov $0x10, %%ax
        \\mov %%ax, %%ds
        \\mov %%ax, %%es
        \\mov %%ax, %%ss
        \\xor %%ax, %%ax
        \\mov %%ax, %%fs
        \\mov %%ax, %%gs
        :
        :
        : .{ .rax = true }
    );
}
