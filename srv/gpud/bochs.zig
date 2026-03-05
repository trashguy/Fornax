const fx = @import("fornax");

// VBE DISPI register indices
const VBE_DISPI_INDEX_ID = 0;
const VBE_DISPI_INDEX_XRES = 1;
const VBE_DISPI_INDEX_YRES = 2;
const VBE_DISPI_INDEX_BPP = 3;
const VBE_DISPI_INDEX_ENABLE = 4;
const VBE_DISPI_INDEX_VIRT_WIDTH = 6;

// VBE DISPI enable flags
const VBE_DISPI_ENABLED = 0x01;
const VBE_DISPI_LFB_ENABLED = 0x40;

// MMIO offsets from BAR2 base
const DISPI_MMIO_OFFSET: u64 = 0x500;

var fb_virt: u64 = 0;
var fb_size: u64 = 0;
var mmio_base: u64 = 0;
var fb_width: u32 = 0;
var fb_height: u32 = 0;
var fb_stride: u32 = 0;

/// Initialize Bochs VGA backend.
/// bar0_phys/bar0_size = VRAM, bar2_phys = MMIO (VBE DISPI registers at +0x500).
pub fn bochsInit(bar0_phys: u64, bar0_size: u64, bar2_phys: u64) bool {
    // Map VRAM with write-combining
    const vram = fx.mmap_device(bar0_phys, bar0_size, 0x1);
    if (vram == 0) return false;

    // Map MMIO region (4KB, uncached)
    const mmio = fx.mmap_device(bar2_phys, 4096, 0x0);
    if (mmio == 0) return false;

    fb_virt = vram;
    fb_size = bar0_size;
    mmio_base = mmio;

    // Read current resolution from VBE DISPI registers
    fb_width = dispiRead(VBE_DISPI_INDEX_XRES);
    fb_height = dispiRead(VBE_DISPI_INDEX_YRES);
    fb_stride = fb_width; // Bochs VGA stride = width in 32bpp mode

    // If resolution looks invalid, set a default
    if (fb_width == 0 or fb_height == 0 or fb_width > 4096 or fb_height > 4096) {
        if (!bochsSetMode(1024, 768)) return false;
    }

    return true;
}

/// Set display mode (resolution). Returns true on success.
pub fn bochsSetMode(width: u32, height: u32) bool {
    if (width == 0 or height == 0 or width > 4096 or height > 4096) return false;

    // Check VRAM can hold the mode
    const needed = @as(u64, width) * @as(u64, height) * 4;
    if (needed > fb_size) return false;

    // Disable display
    dispiWrite(VBE_DISPI_INDEX_ENABLE, 0);

    // Set resolution
    dispiWrite(VBE_DISPI_INDEX_XRES, @truncate(width));
    dispiWrite(VBE_DISPI_INDEX_YRES, @truncate(height));
    dispiWrite(VBE_DISPI_INDEX_BPP, 32);
    dispiWrite(VBE_DISPI_INDEX_VIRT_WIDTH, @truncate(width));

    // Enable with LFB
    dispiWrite(VBE_DISPI_INDEX_ENABLE, VBE_DISPI_ENABLED | VBE_DISPI_LFB_ENABLED);

    fb_width = width;
    fb_height = height;
    fb_stride = width;
    return true;
}

/// Format info string into buf, return bytes written.
pub fn bochsGetInfo(buf: []u8) usize {
    const info = "backend: bochs\n";
    var pos: usize = 0;

    if (pos + info.len > buf.len) return 0;
    @memcpy(buf[pos..][0..info.len], info);
    pos += info.len;

    pos += fmtField(buf[pos..], "width: ", fb_width);
    pos += fmtField(buf[pos..], "height: ", fb_height);
    pos += fmtField(buf[pos..], "stride: ", fb_stride);
    pos += fmtField(buf[pos..], "bpp: ", 32);
    return pos;
}

/// Read pixel data from framebuffer at offset.
pub fn bochsReadFb(offset: u64, buf: []u8) usize {
    const active_size = @as(u64, fb_stride) * @as(u64, fb_height) * 4;
    if (offset >= active_size) return 0;
    const available = active_size - offset;
    const to_copy = @min(available, buf.len);
    const src: [*]const u8 = @ptrFromInt(fb_virt + offset);
    @memcpy(buf[0..to_copy], src[0..to_copy]);
    return to_copy;
}

/// Write pixel data to framebuffer at offset.
pub fn bochsWriteFb(offset: u64, data: []const u8) usize {
    const active_size = @as(u64, fb_stride) * @as(u64, fb_height) * 4;
    if (offset >= active_size) return 0;
    const available = active_size - offset;
    const to_write = @min(available, data.len);
    const dst: [*]u8 = @ptrFromInt(fb_virt + offset);
    @memcpy(dst[0..to_write], data[0..to_write]);
    return to_write;
}

pub fn bochsFbSize() u64 {
    return @as(u64, fb_stride) * @as(u64, fb_height) * 4;
}

// --- MMIO register access ---

fn dispiRead(index: u16) u16 {
    const idx_ptr: *volatile u16 = @ptrFromInt(mmio_base + DISPI_MMIO_OFFSET);
    const data_ptr: *volatile u16 = @ptrFromInt(mmio_base + DISPI_MMIO_OFFSET + 2);
    idx_ptr.* = index;
    return data_ptr.*;
}

fn dispiWrite(index: u16, value: u16) void {
    const idx_ptr: *volatile u16 = @ptrFromInt(mmio_base + DISPI_MMIO_OFFSET);
    const data_ptr: *volatile u16 = @ptrFromInt(mmio_base + DISPI_MMIO_OFFSET + 2);
    idx_ptr.* = index;
    data_ptr.* = value;
}

// --- Formatting helpers ---

fn fmtField(buf: []u8, label: []const u8, val: u32) usize {
    var pos: usize = 0;
    if (pos + label.len >= buf.len) return 0;
    @memcpy(buf[pos..][0..label.len], label);
    pos += label.len;
    pos += fmtDec(buf[pos..], val);
    if (pos < buf.len) {
        buf[pos] = '\n';
        pos += 1;
    }
    return pos;
}

fn fmtDec(buf: []u8, val: u32) usize {
    if (val == 0) {
        if (buf.len > 0) buf[0] = '0';
        return 1;
    }
    var tmp: [10]u8 = undefined;
    var n: usize = 0;
    var v = val;
    while (v != 0) : (n += 1) {
        tmp[n] = @truncate((v % 10) + '0');
        v /= 10;
    }
    if (n > buf.len) return 0;
    for (0..n) |j| {
        buf[j] = tmp[n - 1 - j];
    }
    return n;
}
