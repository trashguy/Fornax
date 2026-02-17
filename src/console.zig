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

pub const NUM_VTS: u8 = 4;
const MAX_COLS: u32 = 200;
const MAX_ROWS: u32 = 80;

// ── Character grid cell ──────────────────────────────────────────

const Cell = struct {
    char: u8 = ' ',
    /// Color byte: lo nibble = fg index (0=default, 1-8=ANSI), hi nibble = bg index.
    /// Reverse video is applied at store time (fg/bg swapped before storing).
    color: u8 = 0,
};

// ── ANSI CSI state machine ─────────────────────────────────────────

const ParseState = enum { normal, esc_seen, csi_param };

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

// ── Per-VT display state ─────────────────────────────────────────

const VtDisplay = struct {
    grid: [MAX_COLS * MAX_ROWS]Cell,
    cursor_x: u32,
    cursor_y: u32,
    reverse_video: bool,
    fg_override: ?u8, // ANSI palette index 0-7
    bg_override: ?u8,
    parse_state: ParseState,
    csi_params: [8]u16,
    csi_param_count: u8,
    csi_private: bool,
};

// ── Global state ─────────────────────────────────────────────────

var fb: Framebuffer = undefined;
var cols: u32 = 80;
var rows: u32 = 24;
var initialized: bool = false;
pub var active_vt: u8 = 0;
var vts: [NUM_VTS]VtDisplay linksection(".bss") = undefined;

// ── Public API ───────────────────────────────────────────────────

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
    for (&vts) |*vt| {
        initVt(vt);
    }
    active_vt = 0;
    initialized = true;
    clearFramebuffer();
}

fn initVt(vt: *VtDisplay) void {
    vt.cursor_x = 0;
    vt.cursor_y = 0;
    vt.reverse_video = false;
    vt.fg_override = null;
    vt.bg_override = null;
    vt.parse_state = .normal;
    vt.csi_param_count = 0;
    vt.csi_private = false;
    for (&vt.csi_params) |*p| p.* = 0;
    for (&vt.grid) |*cell| {
        cell.char = ' ';
        cell.color = 0;
    }
}

/// Clear framebuffer to default background.
fn clearFramebuffer() void {
    const total = fb.stride * fb.height;
    const bg = packColor(bg_color);
    for (0..total) |i| {
        fb.base[i] = bg;
    }
}

pub fn clearScreen() void {
    clearScreenForVt(active_vt);
}

fn clearScreenForVt(idx: u8) void {
    const vt = &vts[idx];
    vt.cursor_x = 0;
    vt.cursor_y = 0;
    // Clear grid
    const r = @min(rows, MAX_ROWS);
    const c = @min(cols, MAX_COLS);
    for (0..r) |row| {
        for (0..c) |col| {
            vt.grid[row * MAX_COLS + col] = .{ .char = ' ', .color = 0 };
        }
    }
    if (idx == active_vt) {
        clearFramebuffer();
    }
}

/// Switch active virtual terminal and repaint.
pub fn switchVt(n: u8) void {
    if (n >= NUM_VTS) return;
    active_vt = n;
    repaint(n);
}

/// Repaint framebuffer from VT's character grid.
fn repaint(idx: u8) void {
    if (!initialized) return;
    const vt = &vts[idx];
    const r = @min(rows, MAX_ROWS);
    const c = @min(cols, MAX_COLS);
    for (0..r) |row| {
        for (0..c) |col| {
            const cell = vt.grid[row * MAX_COLS + col];
            const fg_rgb = cellToFgRgb(cell.color);
            const bg_rgb = cellToBgRgb(cell.color);
            drawGlyph(@intCast(col), @intCast(row), cell.char, fg_rgb, bg_rgb);
        }
    }
}

// ── Output functions ─────────────────────────────────────────────

/// Write string to active VT (for kernel messages, logging).
pub fn puts(s: []const u8) void {
    for (s) |c| {
        putChar(c);
    }
}

/// Write string to a specific VT.
pub fn putsVt(idx: u8, s: []const u8) void {
    for (s) |c| {
        putCharForVt(idx, c);
    }
}

/// Write character to active VT.
pub fn putChar(c: u8) void {
    putCharForVt(active_vt, c);
}

/// Write character to a specific VT.
pub fn putCharForVt(idx: u8, c: u8) void {
    // Mirror all output to serial console
    if (c == '\n') serial.putChar('\r');
    serial.putChar(c);

    if (!initialized) return;
    if (idx >= NUM_VTS) return;

    const vt = &vts[idx];

    switch (vt.parse_state) {
        .normal => {
            if (c == 0x1B) {
                vt.parse_state = .esc_seen;
                return;
            }
            putCharNormalVt(vt, idx, c);
        },
        .esc_seen => {
            if (c == '[') {
                vt.parse_state = .csi_param;
                vt.csi_param_count = 0;
                vt.csi_params[0] = 0;
                vt.csi_private = false;
            } else {
                vt.parse_state = .normal;
                // Not a CSI sequence — drop the ESC
            }
        },
        .csi_param => {
            if (c == '?') {
                vt.csi_private = true;
            } else if (c >= '0' and c <= '9') {
                if (vt.csi_param_count == 0) vt.csi_param_count = 1;
                const i = vt.csi_param_count - 1;
                if (i < vt.csi_params.len) {
                    vt.csi_params[i] = vt.csi_params[i] *% 10 +% (c - '0');
                }
            } else if (c == ';') {
                if (vt.csi_param_count < vt.csi_params.len) {
                    vt.csi_param_count += 1;
                    vt.csi_params[vt.csi_param_count - 1] = 0;
                }
            } else if (c >= 0x40 and c <= 0x7E) {
                // Final byte — execute and reset
                executeCsiVt(vt, idx, c);
                vt.parse_state = .normal;
            } else {
                // Unknown char in CSI — abort
                vt.parse_state = .normal;
            }
        },
    }
}

fn executeCsiVt(vt: *VtDisplay, idx: u8, final: u8) void {
    const p0: u16 = if (vt.csi_param_count >= 1) vt.csi_params[0] else 0;
    const p1: u16 = if (vt.csi_param_count >= 2) vt.csi_params[1] else 0;

    switch (final) {
        'H', 'f' => {
            // Cursor position: ESC[row;colH (1-based)
            const row = if (p0 > 0) p0 - 1 else 0;
            const col = if (p1 > 0) p1 - 1 else 0;
            vt.cursor_y = @min(row, rows -| 1);
            vt.cursor_x = @min(col, cols -| 1);
        },
        'A' => {
            // Cursor up
            const n: u32 = if (p0 > 0) p0 else 1;
            vt.cursor_y -|= n;
        },
        'B' => {
            // Cursor down
            const n: u32 = if (p0 > 0) p0 else 1;
            vt.cursor_y = @min(vt.cursor_y + n, rows -| 1);
        },
        'C' => {
            // Cursor forward
            const n: u32 = if (p0 > 0) p0 else 1;
            vt.cursor_x = @min(vt.cursor_x + n, cols -| 1);
        },
        'D' => {
            // Cursor back
            const n: u32 = if (p0 > 0) p0 else 1;
            vt.cursor_x -|= n;
        },
        'J' => {
            if (p0 == 2) {
                clearScreenForVt(idx);
            }
        },
        'K' => {
            // Clear to end of line
            clearToEndOfLineVt(vt, idx);
        },
        'm' => {
            // SGR — Select Graphic Rendition
            if (vt.csi_param_count == 0) {
                // ESC[m = reset
                vt.reverse_video = false;
                vt.fg_override = null;
                vt.bg_override = null;
                return;
            }
            var i: u8 = 0;
            while (i < vt.csi_param_count) : (i += 1) {
                const p = vt.csi_params[i];
                switch (p) {
                    0 => {
                        vt.reverse_video = false;
                        vt.fg_override = null;
                        vt.bg_override = null;
                    },
                    1 => {}, // bold — ignore
                    7 => vt.reverse_video = true,
                    27 => vt.reverse_video = false,
                    30...37 => vt.fg_override = @intCast(p - 30),
                    39 => vt.fg_override = null,
                    40...47 => vt.bg_override = @intCast(p - 40),
                    49 => vt.bg_override = null,
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

fn putCharNormalVt(vt: *VtDisplay, idx: u8, c: u8) void {
    if (c == '\n') {
        vt.cursor_x = 0;
        vt.cursor_y += 1;
        if (vt.cursor_y >= rows) {
            scrollUpVt(vt, idx);
            vt.cursor_y = rows - 1;
        }
        return;
    }

    if (c == '\r') {
        vt.cursor_x = 0;
        return;
    }

    // Backspace: move cursor back one position
    if (c == 0x08) {
        if (vt.cursor_x > 0) {
            vt.cursor_x -= 1;
        }
        return;
    }

    if (vt.cursor_x >= cols) {
        vt.cursor_x = 0;
        vt.cursor_y += 1;
        if (vt.cursor_y >= rows) {
            scrollUpVt(vt, idx);
            vt.cursor_y = rows - 1;
        }
    }

    // Compute cell color (reverse video applied at store time)
    const color = makeCellColor(vt);

    // Update grid
    if (vt.cursor_y < MAX_ROWS and vt.cursor_x < MAX_COLS) {
        vt.grid[vt.cursor_y * MAX_COLS + vt.cursor_x] = .{ .char = c, .color = color };
    }

    // Draw to framebuffer only if this is the active VT
    if (idx == active_vt) {
        const fg_rgb = cellToFgRgb(color);
        const bg_rgb = cellToBgRgb(color);
        drawGlyph(vt.cursor_x, vt.cursor_y, c, fg_rgb, bg_rgb);
    }

    vt.cursor_x += 1;
}

fn drawGlyph(col: u32, row: u32, c: u8, fg_rgb: u32, bg_rgb: u32) void {
    const glyph = font.getGlyph(c);
    const px = col * font.char_width;
    const py = row * font.char_height;

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

fn clearToEndOfLineVt(vt: *VtDisplay, idx: u8) void {
    if (vt.cursor_x >= cols) return;

    // Clear grid cells from cursor to end of line
    const color = makeCellColor(vt);
    if (vt.cursor_y < MAX_ROWS) {
        const c = @min(cols, MAX_COLS);
        for (vt.cursor_x..c) |col| {
            vt.grid[vt.cursor_y * MAX_COLS + col] = .{ .char = ' ', .color = color };
        }
    }

    // Clear framebuffer only if active VT
    if (idx == active_vt) {
        const bg_rgb = cellToBgRgb(color);
        const bg = packColor(bg_rgb);

        const px_start = vt.cursor_x * font.char_width;
        const py = vt.cursor_y * font.char_height;

        for (0..font.char_height) |y| {
            const base = (py + @as(u32, @intCast(y))) * fb.stride + px_start;
            const remaining = cols * font.char_width - px_start;
            for (0..remaining) |x| {
                fb.base[base + @as(u32, @intCast(x))] = bg;
            }
        }
    }
}

fn scrollUpVt(vt: *VtDisplay, idx: u8) void {
    // Scroll grid: move rows up by one
    const r = @min(rows, MAX_ROWS);
    const c = @min(cols, MAX_COLS);
    for (1..r) |row| {
        for (0..c) |col| {
            vt.grid[(row - 1) * MAX_COLS + col] = vt.grid[row * MAX_COLS + col];
        }
    }
    // Clear last row in grid
    if (r > 0) {
        for (0..c) |col| {
            vt.grid[(r - 1) * MAX_COLS + col] = .{ .char = ' ', .color = 0 };
        }
    }

    // Scroll framebuffer only if active VT
    if (idx == active_vt) {
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
}

// ── Color helpers ────────────────────────────────────────────────

/// Compute cell color byte from current VT attribute state.
/// Reverse video is applied here (fg/bg indices swapped).
fn makeCellColor(vt: *const VtDisplay) u8 {
    var fg_idx: u8 = if (vt.fg_override) |idx| idx + 1 else 0;
    var bg_idx: u8 = if (vt.bg_override) |idx| idx + 1 else 0;
    if (vt.reverse_video) {
        const tmp = fg_idx;
        fg_idx = bg_idx;
        bg_idx = tmp;
    }
    return fg_idx | (bg_idx << 4);
}

/// Convert cell color byte's fg nibble to RGB.
fn cellToFgRgb(color: u8) u32 {
    const idx = color & 0x0F;
    return if (idx == 0) fg_color_rgb else ansi_palette[idx - 1];
}

/// Convert cell color byte's bg nibble to RGB.
fn cellToBgRgb(color: u8) u32 {
    const idx = (color >> 4) & 0x0F;
    return if (idx == 0) bg_color else ansi_palette[idx - 1];
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

// ── Numeric output (kernel logging) ──────────────────────────────

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
