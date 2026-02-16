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

// ── ANSI CSI state machine ─────────────────────────────────────────

const ParseState = enum { normal, esc_seen, csi_param };
var parse_state: ParseState = .normal;

var csi_params: [8]u16 = undefined;
var csi_param_count: u8 = 0;
var csi_private: bool = false;

// ── Attribute state ────────────────────────────────────────────────

var reverse_video: bool = false;
var fg_override: ?u32 = null;
var bg_override: ?u32 = null;

const ansi_palette = [8]u32{
    0x000000, // 0 black
    0xCC0000, // 1 red
    0x00CC00, // 2 green
    0xCCCC00, // 3 yellow
    0x0000CC, // 4 blue
    0xCC00CC, // 5 magenta
    0x00CCCC, // 6 cyan
    0xCCCCCC, // 7 white
};

pub fn getCols() u32 {
    return cols;
}

pub fn getRows() u32 {
    return rows;
}

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

    switch (parse_state) {
        .normal => {
            if (c == 0x1B) {
                parse_state = .esc_seen;
                return;
            }
            putCharNormal(c);
        },
        .esc_seen => {
            if (c == '[') {
                parse_state = .csi_param;
                csi_param_count = 0;
                csi_params[0] = 0;
                csi_private = false;
            } else {
                parse_state = .normal;
                // Not a CSI sequence — drop the ESC
            }
        },
        .csi_param => {
            if (c == '?') {
                csi_private = true;
            } else if (c >= '0' and c <= '9') {
                if (csi_param_count == 0) csi_param_count = 1;
                const idx = csi_param_count - 1;
                if (idx < csi_params.len) {
                    csi_params[idx] = csi_params[idx] *% 10 +% (c - '0');
                }
            } else if (c == ';') {
                if (csi_param_count < csi_params.len) {
                    csi_param_count += 1;
                    csi_params[csi_param_count - 1] = 0;
                }
            } else if (c >= 0x40 and c <= 0x7E) {
                // Final byte — execute and reset
                executeCsi(c);
                parse_state = .normal;
            } else {
                // Unknown char in CSI — abort
                parse_state = .normal;
            }
        },
    }
}

fn executeCsi(final: u8) void {
    const p0: u16 = if (csi_param_count >= 1) csi_params[0] else 0;
    const p1: u16 = if (csi_param_count >= 2) csi_params[1] else 0;

    switch (final) {
        'H', 'f' => {
            // Cursor position: ESC[row;colH (1-based)
            const row = if (p0 > 0) p0 - 1 else 0;
            const col = if (p1 > 0) p1 - 1 else 0;
            cursor_y = @min(row, rows -| 1);
            cursor_x = @min(col, cols -| 1);
        },
        'A' => {
            // Cursor up
            const n: u32 = if (p0 > 0) p0 else 1;
            cursor_y -|= n;
        },
        'B' => {
            // Cursor down
            const n: u32 = if (p0 > 0) p0 else 1;
            cursor_y = @min(cursor_y + n, rows -| 1);
        },
        'C' => {
            // Cursor forward
            const n: u32 = if (p0 > 0) p0 else 1;
            cursor_x = @min(cursor_x + n, cols -| 1);
        },
        'D' => {
            // Cursor back
            const n: u32 = if (p0 > 0) p0 else 1;
            cursor_x -|= n;
        },
        'J' => {
            if (p0 == 2) {
                clearScreen();
            }
        },
        'K' => {
            // Clear to end of line
            clearToEndOfLine();
        },
        'm' => {
            // SGR — Select Graphic Rendition
            if (csi_param_count == 0) {
                // ESC[m = reset
                reverse_video = false;
                fg_override = null;
                bg_override = null;
                return;
            }
            var i: u8 = 0;
            while (i < csi_param_count) : (i += 1) {
                const p = csi_params[i];
                switch (p) {
                    0 => {
                        reverse_video = false;
                        fg_override = null;
                        bg_override = null;
                    },
                    1 => {}, // bold — ignore
                    7 => reverse_video = true,
                    27 => reverse_video = false,
                    30...37 => fg_override = ansi_palette[p - 30],
                    39 => fg_override = null,
                    40...47 => bg_override = ansi_palette[p - 40],
                    49 => bg_override = null,
                    else => {},
                }
            }
        },
        'h' => {
            // ESC[?25h — show cursor (ignore, we don't have a hardware cursor)
        },
        'l' => {
            // ESC[?25l — hide cursor (ignore)
        },
        else => {},
    }
}

fn putCharNormal(c: u8) void {
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

    // Backspace: move cursor back one position
    if (c == 0x08) {
        if (cursor_x > 0) {
            cursor_x -= 1;
        }
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

    var fg_rgb = fg_override orelse fg_color_rgb;
    var bg_rgb = bg_override orelse bg_color;
    if (reverse_video) {
        const tmp = fg_rgb;
        fg_rgb = bg_rgb;
        bg_rgb = tmp;
    }

    const fg = packColor(fg_rgb);
    const bg = packColor(bg_rgb);

    for (0..font.char_height) |y| {
        const bits = glyph[y];
        const base = (py + @as(u32, @intCast(y))) * fb.stride + px;
        inline for (0..font.char_width) |x| {
            const mask = @as(u8, 0x80) >> @intCast(x);
            fb.base[base + @as(u32, @intCast(x))] = if (bits & mask != 0) fg else bg;
        }
    }
}

fn clearToEndOfLine() void {
    if (cursor_x >= cols) return;
    const bg_rgb = bg_override orelse bg_color;
    const bg = packColor(if (reverse_video) (fg_override orelse fg_color_rgb) else bg_rgb);

    const px_start = cursor_x * font.char_width;
    const py = cursor_y * font.char_height;

    for (0..font.char_height) |y| {
        const base = (py + @as(u32, @intCast(y))) * fb.stride + px_start;
        const remaining = cols * font.char_width - px_start;
        for (0..remaining) |x| {
            fb.base[base + @as(u32, @intCast(x))] = bg;
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
