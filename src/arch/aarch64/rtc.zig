/// PL031 RTC driver for aarch64.
///
/// QEMU virt machine provides a PL031 RTC at MMIO address 0x09010000.
/// The RTCDR register (offset 0x000) returns seconds since Unix epoch.

pub var boot_epoch: u64 = 0;

/// MMIO base address of the PL031 RTC on QEMU virt.
const RTC_BASE: usize = 0x0901_0000;

pub fn init() void {
    // RTCDR: read-only data register, returns current time in seconds since epoch
    boot_epoch = mmioRead32(RTC_BASE + 0x00);
}

fn mmioRead32(addr: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(addr)).*;
}
