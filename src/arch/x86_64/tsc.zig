/// TSC (Time Stamp Counter) calibration for high-resolution timing on x86_64.
///
/// Provides sub-millisecond precision via RDTSC, calibrated at boot using
/// CPUID (leaf 0x15, 0x16, or hypervisor leaf 0x40000010).  Falls back to
/// PIT channel 2 one-shot measurement if no CPUID method is available.
const cpu = @import("cpu.zig");
const klog = @import("../../klog.zig");

/// TSC ticks per millisecond, set by calibrate().
var tsc_khz: u64 = 0;

/// Whether calibration produced a usable result.
var calibrated: bool = false;

/// Read the 64-bit Time Stamp Counter.
pub inline fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return @as(u64, hi) << 32 | lo;
}

/// Whether TSC calibration succeeded and getMillis/getMicros are usable.
pub fn isCalibrated() bool {
    return calibrated;
}

/// Calibrate TSC frequency. Called once at boot before PIT IRQ setup.
pub fn calibrate() void {
    // Try CPUID-based methods first (safe, no hardware side effects).
    tsc_khz = cpuidCalibrate();
    if (tsc_khz != 0) {
        calibrated = true;
        klog.info("tsc: calibrated via CPUID, tsc_khz=");
        klog.infoDec(tsc_khz);
        return;
    }

    // Fallback: PIT channel 2 one-shot calibration.
    tsc_khz = pitCalibrate();
    if (tsc_khz != 0) {
        calibrated = true;
        klog.info("tsc: calibrated via PIT, tsc_khz=");
        klog.infoDec(tsc_khz);
        return;
    }

    // Calibration failed — timer.zig will fall back to tick-based timing.
    klog.info("tsc: calibration failed, using tick fallback");
}

/// Try CPUID for direct TSC frequency.
/// Checks leaf 0x15, 0x16, and hypervisor leaf 0x40000010 (KVM).
/// Returns tsc_khz or 0 if unavailable.
fn cpuidCalibrate() u64 {
    const max_leaf = cpu.cpuid(0, 0).eax;

    // Leaf 0x15: TSC/crystal ratio (Intel, KVM passthrough)
    if (max_leaf >= 0x15) {
        const leaf15 = cpu.cpuid(0x15, 0);
        const denom = leaf15.eax;
        const numer = leaf15.ebx;
        const crystal_hz = leaf15.ecx;

        if (denom != 0 and numer != 0) {
            if (crystal_hz != 0) {
                const tsc_hz = @as(u64, crystal_hz) * numer / denom;
                return tsc_hz / 1000;
            }
        }
    }

    // Leaf 0x16: Processor frequency info (Intel)
    if (max_leaf >= 0x16) {
        const leaf16 = cpu.cpuid(0x16, 0);
        const base_mhz = leaf16.eax;
        if (base_mhz != 0) {
            return @as(u64, base_mhz) * 1000;
        }
    }

    // Hypervisor CPUID: check if running under a hypervisor (leaf 1, ECX bit 31)
    const leaf1 = cpu.cpuid(1, 0);
    if (leaf1.ecx & (1 << 31) != 0) {
        // Hypervisor present — try KVM-specific leaf 0x40000010 (TSC kHz)
        const hv_sig = cpu.cpuid(0x40000000, 0);
        const max_hv_leaf = hv_sig.eax;
        if (max_hv_leaf >= 0x40000010) {
            const tsc_leaf = cpu.cpuid(0x40000010, 0);
            const khz = tsc_leaf.eax;
            if (khz != 0) {
                return @as(u64, khz);
            }
        }
    }

    return 0;
}

/// PIT channel 2 one-shot calibration.
/// Programs PIT channel 2 in mode 0 (interrupt on terminal count),
/// waits ~10ms worth of PIT ticks, and measures TSC cycles elapsed.
/// Returns tsc_khz or 0 on failure.
fn pitCalibrate() u64 {
    const PIT_CH2: u16 = 0x42;
    const PIT_CMD: u16 = 0x43;
    const PIT_GATE: u16 = 0x61;
    const PIT_HZ: u64 = 1_193_182;

    // ~10ms calibration interval
    const target_count: u16 = @intCast(PIT_HZ / 100);

    // Save original port 0x61 state for restoration.
    const orig_gate = cpu.inb(PIT_GATE);

    // Ensure gate is LOW and speaker is off before programming.
    cpu.outb(PIT_GATE, (orig_gate & 0xFC));

    // Program PIT channel 2: mode 0 (one-shot), binary, lobyte/hibyte.
    // Command byte: channel 2 (10), access lo/hi (11), mode 0 (000), binary (0)
    cpu.outb(PIT_CMD, 0xB0);

    // Load count (lobyte first, then hibyte).
    cpu.outb(PIT_CH2, @truncate(target_count));
    cpu.outb(PIT_CH2, @truncate(target_count >> 8));

    // Start counting: raise gate (0→1 edge triggers mode 0 reload).
    cpu.outb(PIT_GATE, (orig_gate & 0xFC) | 0x01);

    const tsc_start = rdtsc();

    // Wait for PIT channel 2 output to go high (bit 5 of port 0x61).
    // Timeout after ~10M iterations to avoid hanging on broken PIT emulation.
    var timeout: u32 = 0;
    while (timeout < 10_000_000) : (timeout += 1) {
        if (cpu.inb(PIT_GATE) & 0x20 != 0) break;
    }

    const tsc_end = rdtsc();

    // Restore original port 0x61 state.
    cpu.outb(PIT_GATE, orig_gate & 0xFC);

    if (timeout >= 10_000_000) return 0;

    const tsc_elapsed = tsc_end - tsc_start;
    if (tsc_elapsed == 0) return 0;

    // tsc_khz = tsc_elapsed / (target_count / PIT_HZ) / 1000
    //         = tsc_elapsed * PIT_HZ / target_count / 1000
    const result = tsc_elapsed * PIT_HZ / target_count / 1000;

    // Sanity check: reject values outside 100 MHz – 100 GHz range.
    if (result < 100_000 or result > 100_000_000) return 0;

    return result;
}

/// Milliseconds since boot, derived from TSC.
pub fn getMillis() u64 {
    if (tsc_khz == 0) return 0;
    return rdtsc() / tsc_khz;
}

/// Microseconds since boot, derived from TSC.
pub fn getMicros() u64 {
    if (tsc_khz == 0) return 0;
    return rdtsc() * 1000 / tsc_khz;
}
