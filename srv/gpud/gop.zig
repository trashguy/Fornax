const fx = @import("fornax");

var fb_virt: u64 = 0;
var fb_width: u32 = 0;
var fb_height: u32 = 0;
var fb_stride: u32 = 0;
var fb_is_bgr: bool = false;
var fb_size: u64 = 0;

/// Initialize GOP backend from framebuffer info.
/// Returns true on success.
pub fn gopInit(fb_phys: u64, width: u32, height: u32, stride: u32, is_bgr: bool) bool {
    const size: u64 = @as(u64, stride) * @as(u64, height) * 4;
    // Map framebuffer with write-combining (flag 0x1)
    const virt = fx.mmap_device(fb_phys, size, 0x1);
    if (virt == 0) return false;

    fb_virt = virt;
    fb_width = width;
    fb_height = height;
    fb_stride = stride;
    fb_is_bgr = is_bgr;
    fb_size = size;
    return true;
}

/// Format info string into buf, return bytes written.
pub fn gopGetInfo(buf: []u8) usize {
    const info = "backend: gop\n";
    var pos: usize = 0;

    if (pos + info.len > buf.len) return 0;
    @memcpy(buf[pos..][0..info.len], info);
    pos += info.len;

    pos += fmtField(buf[pos..], "width: ", fb_width);
    pos += fmtField(buf[pos..], "height: ", fb_height);
    pos += fmtField(buf[pos..], "stride: ", fb_stride);
    pos += fmtField(buf[pos..], "bpp: ", 32);
    pos += fmtField(buf[pos..], "format: ", if (fb_is_bgr) @as(u32, 1) else 0);
    return pos;
}

/// Read pixel data from framebuffer at offset.
pub fn gopReadFb(offset: u64, buf: []u8) usize {
    if (offset >= fb_size) return 0;
    const available = fb_size - offset;
    const to_copy = @min(available, buf.len);
    const src: [*]const u8 = @ptrFromInt(fb_virt + offset);
    @memcpy(buf[0..to_copy], src[0..to_copy]);
    return to_copy;
}

/// Write pixel data to framebuffer at offset.
pub fn gopWriteFb(offset: u64, data: []const u8) usize {
    if (offset >= fb_size) return 0;
    const available = fb_size - offset;
    const to_write = @min(available, data.len);
    const dst: [*]u8 = @ptrFromInt(fb_virt + offset);
    @memcpy(dst[0..to_write], data[0..to_write]);
    return to_write;
}

pub fn gopFbSize() u64 {
    return fb_size;
}

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
