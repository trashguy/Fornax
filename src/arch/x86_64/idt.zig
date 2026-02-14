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

/// Exception frame pushed by our ISR stubs.
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

// Exceptions that push their own error code
fn hasErrorCode(vector: u8) bool {
    return switch (vector) {
        8, 10, 11, 12, 13, 14, 17, 21, 29, 30 => true,
        else => false,
    };
}

/// Comptime-generate an ISR stub for each vector.
/// Each stub is self-contained: push error code (if needed), push vector,
/// save registers, call handler, restore registers, iretq.
fn makeIsrStub(comptime vector: u8) *const fn () callconv(.naked) void {
    return &struct {
        fn stub() callconv(.naked) void {
            if (comptime !hasErrorCode(vector)) {
                asm volatile ("push $0");
            }
            asm volatile ("push %[vec]"
                :
                : [vec] "i" (@as(u64, vector)),
            );
            asm volatile (
                \\push %%rax
                \\push %%rbx
                \\push %%rcx
                \\push %%rdx
                \\push %%rsi
                \\push %%rdi
                \\push %%rbp
                \\push %%r8
                \\push %%r9
                \\push %%r10
                \\push %%r11
                \\push %%r12
                \\push %%r13
                \\push %%r14
                \\push %%r15
                \\mov %%rsp, %%rdi
            );
            asm volatile ("call handleExceptionWrapper");
            asm volatile (
                \\pop %%r15
                \\pop %%r14
                \\pop %%r13
                \\pop %%r12
                \\pop %%r11
                \\pop %%r10
                \\pop %%r9
                \\pop %%r8
                \\pop %%rbp
                \\pop %%rdi
                \\pop %%rsi
                \\pop %%rdx
                \\pop %%rcx
                \\pop %%rbx
                \\pop %%rax
                \\add $16, %%rsp
                \\iretq
            );
        }
    }.stub;
}

export fn handleExceptionWrapper(frame: *ExceptionFrame) callconv(.c) void {
    const interrupts = @import("interrupts.zig");
    interrupts.handleException(frame);
}

fn setGate(vector: u8, handler: *const fn () callconv(.naked) void) void {
    const addr = @intFromPtr(handler);
    idt_entries[vector] = .{
        .offset_low = @truncate(addr),
        .selector = 0x08, // kernel code segment
        .ist = 0,
        .type_attr = 0x8E, // present, DPL=0, interrupt gate
        .offset_mid = @truncate(addr >> 16),
        .offset_high = @truncate(addr >> 32),
        .reserved = 0,
    };
}

/// Generate stubs for vectors 0-31 (CPU exceptions)
const isr_stubs = blk: {
    var stubs: [32]*const fn () callconv(.naked) void = undefined;
    for (0..32) |i| {
        stubs[i] = makeIsrStub(i);
    }
    break :blk stubs;
};

pub fn init() void {
    // Install exception handlers (vectors 0-31)
    for (0..32) |i| {
        setGate(@intCast(i), isr_stubs[i]);
    }

    idt_ptr = .{
        .limit = @sizeOf(@TypeOf(idt_entries)) - 1,
        .base = @intFromPtr(&idt_entries),
    };

    asm volatile ("lidt (%[idt_ptr])"
        :
        : [idt_ptr] "r" (&idt_ptr),
    );

    console.puts("IDT: loaded (256 entries, 32 exception handlers)\n");
}
