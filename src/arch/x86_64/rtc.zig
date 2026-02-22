/// CMOS RTC driver for x86_64.
///
/// Reads the real-time clock at boot to obtain wall-clock time.
/// Uses I/O ports 0x70 (address) / 0x71 (data).
const cpu = @import("cpu.zig");

pub var boot_epoch: u64 = 0;

pub fn init() void {
    boot_epoch = readRtc();
}

fn readRtc() u64 {
    // Wait for any update-in-progress to finish
    waitForUpdate();

    // Read all fields
    const s1 = readCmos(0x00); // seconds
    const m1 = readCmos(0x02); // minutes
    const h1 = readCmos(0x04); // hours
    const d1 = readCmos(0x07); // day
    const mo1 = readCmos(0x08); // month
    const y1 = readCmos(0x09); // year
    const c1 = readCmos(0x32); // century

    // Double-read for consistency
    waitForUpdate();
    const s2 = readCmos(0x00);
    const m2 = readCmos(0x02);
    const h2 = readCmos(0x04);
    const d2 = readCmos(0x07);
    const mo2 = readCmos(0x08);
    const y2 = readCmos(0x09);

    // Use second read if consistent, else first
    var sec = if (s1 == s2) s1 else s2;
    var min = if (m1 == m2) m1 else m2;
    var hour = if (h1 == h2) h1 else h2;
    var day = if (d1 == d2) d1 else d2;
    var month = if (mo1 == mo2) mo1 else mo2;
    var year_lo = if (y1 == y2) y1 else y2;
    var century = c1;

    // Check if BCD mode (status register B, bit 2 = 0 means BCD)
    const reg_b = readCmos(0x0B);
    if (reg_b & 0x04 == 0) {
        sec = bcdToBin(sec);
        min = bcdToBin(min);
        hour = bcdToBin(hour & 0x7F) | (hour & 0x80); // preserve AM/PM bit
        day = bcdToBin(day);
        month = bcdToBin(month);
        year_lo = bcdToBin(year_lo);
        century = bcdToBin(century);
    }

    // 24-hour conversion (bit 1 of reg_b = 0 means 12-hour mode)
    if (reg_b & 0x02 == 0) {
        if (hour & 0x80 != 0) {
            // PM
            hour = (hour & 0x7F);
            if (hour != 12) hour += 12;
        } else {
            if (hour == 12) hour = 0;
        }
    }

    var year: u32 = @as(u32, century) * 100 + @as(u32, year_lo);
    if (year < 1970) year = 2000 + @as(u32, year_lo); // fallback

    return dateToEpoch(year, month, day, hour, min, sec);
}

fn waitForUpdate() void {
    // Wait until update-in-progress flag clears (register A, bit 7)
    var tries: u32 = 0;
    while (tries < 10000) : (tries += 1) {
        const reg_a = readCmos(0x0A);
        if (reg_a & 0x80 == 0) return;
        cpu.spinHint();
    }
}

fn readCmos(reg: u8) u8 {
    cpu.outb(0x70, reg);
    return cpu.inb(0x71);
}

fn bcdToBin(val: u8) u8 {
    return (val & 0x0F) + (val >> 4) * 10;
}

/// Convert date components to Unix epoch seconds.
pub fn dateToEpoch(year: u32, month: u8, day: u8, hour: u8, min: u8, sec: u8) u64 {
    // Days in each month (non-leap)
    const mdays = [_]u16{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };

    const y = year;
    var m = month;
    if (m < 1) m = 1;
    if (m > 12) m = 12;

    // Days from 1970 to start of year
    var days: u64 = 0;
    var yr: u32 = 1970;
    while (yr < y) : (yr += 1) {
        days += if (isLeap(yr)) 366 else 365;
    }

    // Days within year
    days += @as(u64, mdays[m - 1]);
    if (m > 2 and isLeap(y)) days += 1;
    days += @as(u64, day) -| 1;

    return days * 86400 + @as(u64, hour) * 3600 + @as(u64, min) * 60 + @as(u64, sec);
}

fn isLeap(y: u32) bool {
    return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0);
}
