/// Goldfish RTC driver for riscv64.
///
/// QEMU virt machine provides a Goldfish RTC at MMIO address 0x101000.
/// Returns nanoseconds since Unix epoch.

pub var boot_epoch: u64 = 0;

/// MMIO base address of the Goldfish RTC on QEMU virt.
const RTC_BASE: usize = 0x101000;

pub fn init() void {
    // Read TIME_LOW first (latches TIME_HIGH), then TIME_HIGH
    const time_low = mmioRead32(RTC_BASE + 0x00);
    const time_high = mmioRead32(RTC_BASE + 0x04);

    const epoch_ns: u64 = (@as(u64, time_high) << 32) | @as(u64, time_low);
    boot_epoch = epoch_ns / 1_000_000_000;
}

fn mmioRead32(addr: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(addr)).*;
}
