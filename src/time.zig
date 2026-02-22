/// Kernel wall-clock time module.
///
/// Architecture-independent — receives initial epoch from RTC at boot.
/// Combines boot_epoch + uptime + manual offset for wall-clock time.
const timer = @import("timer.zig");

var boot_epoch: u64 = 0;
var epoch_offset: i64 = 0;

/// Initialize with the epoch seconds read from hardware RTC.
pub fn init(rtc_epoch: u64) void {
    boot_epoch = rtc_epoch;
}

/// Current wall-clock time as Unix epoch seconds.
pub fn wallClock() u64 {
    const base = boot_epoch + uptime();
    if (epoch_offset >= 0) {
        return base +% @as(u64, @intCast(epoch_offset));
    } else {
        const neg: u64 = @intCast(-epoch_offset);
        return base -| neg;
    }
}

/// Seconds since boot.
pub fn uptime() u64 {
    return @as(u64, timer.getTicks()) / timer.TICKS_PER_SEC;
}

/// Milliseconds since boot.
pub fn uptimeMs() u64 {
    return @as(u64, timer.getTicks()) * 1000 / timer.TICKS_PER_SEC;
}

/// Adjust the clock offset (for NTP or manual `date -s`).
/// delta = desired_epoch - current wallClock()
pub fn setOffset(delta: i64) void {
    epoch_offset = delta;
}
