const font = @import("font.zig");
const serial = @import("serial.zig");

pub const Framebuffer = struct {
    base: [*]volatile u32,
    width: u32,
    height: u32,
    stride: u32, // pixels per scan line
    is_bgr: bool,
};

const bg_color: u32 = 0x00001A;
const fg_color_rgb: u32 = 0xCCCCCC;

var fb: Framebuffer = undefined;
var cursor_x: u32 = 0;
var cursor_y: u32 = 0;
var cols: u32 = 0;
var rows: u32 = 0;
var initialized: bool = false;

pub fn init(framebuffer: Framebuffer) void {
    fb = framebuffer;
    cols = fb.width / font.char_width;
    rows = fb.height / font.char_height;
    cursor_x = 0;
    cursor_y = 0;
    initialized = true;
    clearScreen();
}

pub fn clearScreen() void {
    const total = fb.stride * fb.height;
    const bg = packColor(bg_color);
    for (0..total) |i| {
        fb.base[i] = bg;
    }
    cursor_x = 0;
    cursor_y = 0;
}

pub fn puts(s: []const u8) void {
    for (s) |c| {
        putChar(c);
    }
}

pub fn putChar(c: u8) void {
    // Mirror all output to serial console
    if (c == '\n') serial.putChar('\r');
    serial.putChar(c);

    if (!initialized) return;

    if (c == '\n') {
        cursor_x = 0;
        cursor_y += 1;
        if (cursor_y >= rows) {
            scrollUp();
            cursor_y = rows - 1;
        }
        return;
    }

    if (c == '\r') {
        cursor_x = 0;
        return;
    }

    if (cursor_x >= cols) {
        cursor_x = 0;
        cursor_y += 1;
        if (cursor_y >= rows) {
            scrollUp();
            cursor_y = rows - 1;
        }
    }

    drawGlyph(cursor_x, cursor_y, c);
    cursor_x += 1;
}

fn drawGlyph(col: u32, row: u32, c: u8) void {
    const glyph = font.getGlyph(c);
    const px = col * font.char_width;
    const py = row * font.char_height;
    const fg = packColor(fg_color_rgb);
    const bg = packColor(bg_color);

    for (0..font.char_height) |y| {
        const bits = glyph[y];
        const base = (py + @as(u32, @intCast(y))) * fb.stride + px;
        inline for (0..font.char_width) |x| {
            const mask = @as(u8, 0x80) >> @intCast(x);
            fb.base[base + @as(u32, @intCast(x))] = if (bits & mask != 0) fg else bg;
        }
    }
}

fn scrollUp() void {
    const line_pixels = font.char_height * fb.stride;
    const total_lines = (rows - 1) * line_pixels;

    // Move rows up by one text row
    for (0..total_lines) |i| {
        fb.base[i] = fb.base[i + line_pixels];
    }

    // Clear the last text row
    const bg = packColor(bg_color);
    for (total_lines..total_lines + line_pixels) |i| {
        fb.base[i] = bg;
    }
}

/// Convert 0xRRGGBB to the correct pixel format.
fn packColor(rgb: u32) u32 {
    if (fb.is_bgr) {
        // UEFI BGR: byte order is Blue, Green, Red, Reserved
        const r = (rgb >> 16) & 0xFF;
        const g = (rgb >> 8) & 0xFF;
        const b = rgb & 0xFF;
        return (r << 16) | (g << 8) | b;
    } else {
        return rgb;
    }
}

/// Print an unsigned integer in decimal.
pub fn putDec(val: u64) void {
    if (val == 0) {
        putChar('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var n = val;
    var i: usize = 0;
    while (n > 0) : (i += 1) {
        buf[i] = @intCast(n % 10 + '0');
        n /= 10;
    }
    while (i > 0) {
        i -= 1;
        putChar(buf[i]);
    }
}

/// Print an unsigned integer in hex with 0x prefix.
pub fn putHex(val: u64) void {
    puts("0x");
    const hex = "0123456789ABCDEF";
    var started = false;
    var shift: u6 = 60;
    while (true) {
        const nibble: u4 = @intCast((val >> shift) & 0xF);
        if (nibble != 0) started = true;
        if (started) putChar(hex[nibble]);
        if (shift == 0) break;
        shift -= 4;
    }
    if (!started) putChar('0');
}
