pub fn halt() noreturn {
    while (true) {
        asm volatile ("wfi");
    }
}

pub fn disableInterrupts() void {
    asm volatile ("msr daifset, #0xF");
}

pub fn enableInterrupts() void {
    asm volatile ("msr daifclr, #0xF");
}

pub fn isb() void {
    asm volatile ("isb");
}

pub fn dsb() void {
    asm volatile ("dsb sy");
}

pub fn readEsr() u64 {
    return asm volatile ("mrs %[esr], esr_el1"
        : [esr] "=r" (-> u64),
    );
}

pub fn readElr() u64 {
    return asm volatile ("mrs %[elr], elr_el1"
        : [elr] "=r" (-> u64),
    );
}

pub fn readFar() u64 {
    return asm volatile ("mrs %[far], far_el1"
        : [far] "=r" (-> u64),
    );
}
