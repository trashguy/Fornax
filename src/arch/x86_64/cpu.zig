pub fn halt() noreturn {
    while (true) {
        asm volatile ("cli");
        asm volatile ("hlt");
    }
}

pub fn disableInterrupts() void {
    asm volatile ("cli");
}

pub fn enableInterrupts() void {
    asm volatile ("sti");
}

pub fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "N{dx}" (port),
    );
}

pub fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[val]"
        : [val] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

pub fn outl(port: u16, val: u32) void {
    asm volatile ("outl %[val], %[port]"
        :
        : [val] "{eax}" (val),
          [port] "N{dx}" (port),
    );
}

pub fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[val]"
        : [val] "={eax}" (-> u32),
        : [port] "N{dx}" (port),
    );
}

pub fn outw(port: u16, val: u16) void {
    asm volatile ("outw %[val], %[port]"
        :
        : [val] "{ax}" (val),
          [port] "N{dx}" (port),
    );
}

pub fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[val]"
        : [val] "={ax}" (-> u16),
        : [port] "N{dx}" (port),
    );
}

/// Read a Model-Specific Register.
pub fn rdmsr(msr: u32) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (msr),
    );
    return @as(u64, high) << 32 | low;
}

/// Write a Model-Specific Register.
pub fn wrmsr(msr: u32, val: u64) void {
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [low] "{eax}" (@as(u32, @truncate(val))),
          [high] "{edx}" (@as(u32, @truncate(val >> 32))),
    );
}

/// Read CR2 (page fault linear address).
pub fn readCr2() u64 {
    return asm volatile ("mov %%cr2, %[cr2]"
        : [cr2] "=r" (-> u64),
    );
}

/// Read CR3 (page table base).
pub fn readCr3() u64 {
    return asm volatile ("mov %%cr3, %[cr3]"
        : [cr3] "=r" (-> u64),
    );
}

pub inline fn spinHint() void {
    asm volatile ("pause");
}

/// Flush TLB by reloading CR3.
pub fn flushTlb() void {
    asm volatile (
        \\mov %%cr3, %%rax
        \\mov %%rax, %%cr3
        :
        :
        : .{ .rax = true, .memory = true }
    );
}

/// ACPI shutdown: write S5 sleep type to QEMU PM1a control port.
pub fn acpiShutdown() noreturn {
    outw(0x604, 0x2000);
    halt();
}

/// System reset via keyboard controller CPU reset command.
pub fn resetSystem() noreturn {
    outb(0x64, 0xFE);
    halt();
}

pub const CpuidResult = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

pub fn cpuid(leaf: u32, subleaf: u32) CpuidResult {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

// MSR numbers
pub const MSR_EFER = 0xC0000080;
pub const MSR_STAR = 0xC0000081;
pub const MSR_LSTAR = 0xC0000082;
pub const MSR_SFMASK = 0xC0000084;

// EFER bits
pub const EFER_SCE: u64 = 1 << 0; // System Call Extensions
