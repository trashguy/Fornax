const console = @import("../../console.zig");

const IdtEntry = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    type_attr: u8,
    offset_mid: u16,
    offset_high: u32,
    reserved: u32,
};

const IdtPtr = packed struct {
    limit: u16,
    base: u64,
};

var idt_entries: [256]IdtEntry = [_]IdtEntry{.{
    .offset_low = 0,
    .selector = 0,
    .ist = 0,
    .type_attr = 0,
    .offset_mid = 0,
    .offset_high = 0,
    .reserved = 0,
}} ** 256;

var idt_ptr: IdtPtr = undefined;

/// Exception frame pushed by ISR stubs in entry.S.
pub const ExceptionFrame = extern struct {
    // Pushed by common stub (in reverse order)
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    // Pushed by stub
    vector: u64,
    error_code: u64,
    // Pushed by CPU
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

/// ISR stub address table defined in entry.S.
extern const isr_stub_table: [48]u64;

/// Exception handler wrapper called from entry.S using System V ABI.
export fn handleExceptionWrapper(frame: *ExceptionFrame) callconv(.{ .x86_64_sysv = .{} }) void {
    const interrupts = @import("interrupts.zig");
    interrupts.handleException(frame);
}

fn setGate(vector: u8, handler_addr: u64) void {
    idt_entries[vector] = .{
        .offset_low = @truncate(handler_addr),
        .selector = 0x08, // kernel code segment
        .ist = 0,
        .type_attr = 0x8E, // present, DPL=0, interrupt gate
        .offset_mid = @truncate(handler_addr >> 16),
        .offset_high = @truncate(handler_addr >> 32),
        .reserved = 0,
    };
}

pub fn init() void {
    // Install exception + IRQ handlers (vectors 0-47) from entry.S stubs
    for (0..48) |i| {
        setGate(@intCast(i), isr_stub_table[i]);
    }

    idt_ptr = .{
        .limit = @sizeOf(@TypeOf(idt_entries)) - 1,
        .base = @intFromPtr(&idt_entries),
    };

    asm volatile ("lidt (%[idt_ptr])"
        :
        : [idt_ptr] "r" (&idt_ptr),
    );

    console.puts("IDT: loaded (256 entries, 48 handlers)\n");
}
