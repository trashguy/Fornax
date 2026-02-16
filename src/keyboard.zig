/// Keyboard module — translates evdev keycodes to ASCII.
///
/// Provides a 256-byte ring buffer for processed characters.
/// Supports line mode (default) with echo/backspace/enter and raw mode.
/// Tracks shift, ctrl, alt, and caps lock state.

const console = @import("console.zig");
const serial = @import("serial.zig");
const process = @import("process.zig");

/// Ring buffer for processed characters.
const RING_SIZE: usize = 256;
var ring: [RING_SIZE]u8 = undefined;
var ring_head: usize = 0; // next write position
var ring_tail: usize = 0; // next read position

/// Line editing buffer (for line mode).
const LINE_SIZE: usize = 256;
var line_buf: [LINE_SIZE]u8 = undefined;
var line_len: usize = 0;

/// Modifier state
var shift_held: bool = false;
var ctrl_held: bool = false;
var alt_held: bool = false;
var caps_lock: bool = false;

/// Console mode
var raw_mode: bool = false;
var echo_on: bool = true;

/// Blocking support: PID of process waiting for console input.
var waiting_pid: ?u16 = null;
/// User buffer pointer and size for the waiting read.
var waiting_buf_ptr: u64 = 0;
var waiting_buf_size: usize = 0;

/// Handle a console control command (Plan 9 style: write to fd 0).
pub fn handleCtl(cmd: []const u8) void {
    if (eql(cmd, "rawon")) {
        raw_mode = true;
    } else if (eql(cmd, "rawoff")) {
        raw_mode = false;
    } else if (eql(cmd, "echo on")) {
        echo_on = true;
    } else if (eql(cmd, "echo off")) {
        echo_on = false;
    } else if (eql(cmd, "size")) {
        // Return "cols rows\n" via ring buffer
        var buf: [24]u8 = undefined;
        var len: usize = 0;
        len += formatDecInto(buf[len..], console.getCols());
        buf[len] = ' ';
        len += 1;
        len += formatDecInto(buf[len..], console.getRows());
        buf[len] = '\n';
        len += 1;
        for (buf[0..len]) |c| pushToRing(c);
        wakeWaiter();
    }
}

fn formatDecInto(buf: []u8, val: u32) usize {
    if (val == 0) {
        if (buf.len > 0) buf[0] = '0';
        return 1;
    }
    var tmp: [12]u8 = undefined;
    var n = val;
    var i: usize = 0;
    while (n > 0) : (i += 1) {
        tmp[i] = @intCast(n % 10 + '0');
        n /= 10;
    }
    var j: usize = 0;
    while (j < i and j < buf.len) : (j += 1) {
        buf[j] = tmp[i - 1 - j];
    }
    return i;
}

/// Handle an evdev key event from the virtio-input driver.
/// code = Linux keycode, value = 0 (release), 1 (press), 2 (repeat).
pub fn handleEvdevKey(code: u16, value: u32) void {
    // Handle modifier keys
    switch (code) {
        KEY_LEFTSHIFT, KEY_RIGHTSHIFT => {
            shift_held = (value != 0);
            return;
        },
        KEY_LEFTCTRL, KEY_RIGHTCTRL => {
            ctrl_held = (value != 0);
            return;
        },
        KEY_LEFTALT, KEY_RIGHTALT => {
            alt_held = (value != 0);
            return;
        },
        KEY_CAPSLOCK => {
            if (value == 1) caps_lock = !caps_lock; // toggle on press only
            return;
        },
        else => {},
    }

    // Only process on press and repeat (not release)
    if (value == 0) return;

    // Arrow/Home/End keys: emit ANSI escape sequences in raw mode
    if (raw_mode) {
        const esc_char: ?u8 = switch (code) {
            KEY_UP => 'A',
            KEY_DOWN => 'B',
            KEY_RIGHT => 'C',
            KEY_LEFT => 'D',
            KEY_HOME => 'H',
            KEY_END => 'F',
            else => null,
        };
        if (esc_char) |c| {
            pushToRing(0x1B);
            pushToRing('[');
            pushToRing(c);
            wakeWaiter();
            return;
        }
    }

    // Translate keycode to ASCII
    const ascii = translateToAscii(code) orelse return;
    handleChar(ascii);
}

/// Handle a raw ASCII character (from serial or translated evdev key).
pub fn handleChar(ascii: u8) void {
    if (raw_mode) {
        // Raw mode: push immediately to ring buffer
        pushToRing(ascii);
        wakeWaiter();
    } else {
        // Line mode
        if (ascii == '\n' or ascii == '\r') {
            // Submit line
            if (echo_on) console.putChar('\n');
            // Copy line buffer to ring
            for (line_buf[0..line_len]) |c| {
                pushToRing(c);
            }
            pushToRing('\n');
            line_len = 0;
            wakeWaiter();
        } else if (ascii == 0x08 or ascii == 0x7F) {
            // Backspace
            if (line_len > 0) {
                line_len -= 1;
                if (echo_on) eraseChar();
            }
        } else if (ascii >= 0x20 or ascii == '\t') {
            // Printable character or tab
            if (line_len < LINE_SIZE) {
                line_buf[line_len] = ascii;
                line_len += 1;
                if (echo_on) console.putChar(ascii);
            }
        } else {
            // Control characters (Ctrl-C = 0x03, Ctrl-D = 0x04, etc.)
            pushToRing(ascii);
            wakeWaiter();
        }
    }
}

/// Read from the ring buffer. Returns number of bytes read.
pub fn read(buf: [*]u8, max_len: usize) usize {
    var count: usize = 0;
    while (count < max_len and ring_tail != ring_head) {
        buf[count] = ring[ring_tail];
        ring_tail = (ring_tail + 1) % RING_SIZE;
        count += 1;
        // In line mode, stop after newline
        if (!raw_mode and count > 0 and buf[count - 1] == '\n') break;
    }
    return count;
}

/// Check if data is available to read.
pub fn dataAvailable() bool {
    if (ring_tail == ring_head) return false;
    if (raw_mode) return true;
    // In line mode, only return true if there's a complete line (contains \n)
    var i = ring_tail;
    while (i != ring_head) {
        if (ring[i] == '\n') return true;
        i = (i + 1) % RING_SIZE;
    }
    return false;
}

/// Register a process as waiting for console input.
pub fn registerWaiter(pid: u16, buf_ptr: u64, buf_size: usize) void {
    waiting_pid = pid;
    waiting_buf_ptr = buf_ptr;
    waiting_buf_size = buf_size;
}

/// Get the waiting process info for delivery in switchTo.
pub fn getWaiter() ?struct { pid: u16, buf_ptr: u64, buf_size: usize } {
    const pid = waiting_pid orelse return null;
    return .{ .pid = pid, .buf_ptr = waiting_buf_ptr, .buf_size = waiting_buf_size };
}

/// Clear the waiter after delivery.
pub fn clearWaiter() void {
    waiting_pid = null;
    waiting_buf_ptr = 0;
    waiting_buf_size = 0;
}

// ---- Internal helpers ----

fn pushToRing(c: u8) void {
    const next = (ring_head + 1) % RING_SIZE;
    if (next == ring_tail) return; // buffer full, drop character
    ring[ring_head] = c;
    ring_head = next;
}

fn wakeWaiter() void {
    const pid = waiting_pid orelse return;
    if (process.getByPid(pid)) |proc| {
        if (proc.state == .blocked) {
            proc.state = .ready;
            proc.pending_op = .console_read;
        }
    }
}

fn eraseChar() void {
    // Move cursor back, draw space, move cursor back again
    console.putChar(0x08); // backspace moves cursor
    console.putChar(' '); // overwrite with space
    console.putChar(0x08); // move back again
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

/// Translate a Linux evdev keycode to ASCII, applying shift/ctrl/caps lock.
fn translateToAscii(code: u16) ?u8 {
    if (ctrl_held) {
        // Ctrl+letter → control character
        const base = keycodeToBase(code) orelse return null;
        if (base >= 'a' and base <= 'z') {
            return base - 'a' + 1; // Ctrl-A=1, Ctrl-C=3, Ctrl-D=4, etc.
        }
        return null;
    }

    const base = keycodeToBase(code) orelse return null;

    // Apply shift/caps lock for letters
    if (base >= 'a' and base <= 'z') {
        const shifted = shift_held != caps_lock; // XOR
        if (shifted) return base - 32; // uppercase
        return base;
    }

    // Shift for non-letters
    if (shift_held) {
        return shiftChar(base);
    }

    return base;
}

/// Map evdev keycode to unshifted ASCII base character.
fn keycodeToBase(code: u16) ?u8 {
    return switch (code) {
        KEY_1 => '1',
        KEY_2 => '2',
        KEY_3 => '3',
        KEY_4 => '4',
        KEY_5 => '5',
        KEY_6 => '6',
        KEY_7 => '7',
        KEY_8 => '8',
        KEY_9 => '9',
        KEY_0 => '0',
        KEY_MINUS => '-',
        KEY_EQUAL => '=',
        KEY_Q => 'q',
        KEY_W => 'w',
        KEY_E => 'e',
        KEY_R => 'r',
        KEY_T => 't',
        KEY_Y => 'y',
        KEY_U => 'u',
        KEY_I => 'i',
        KEY_O => 'o',
        KEY_P => 'p',
        KEY_LEFTBRACE => '[',
        KEY_RIGHTBRACE => ']',
        KEY_A => 'a',
        KEY_S => 's',
        KEY_D => 'd',
        KEY_F => 'f',
        KEY_G => 'g',
        KEY_H => 'h',
        KEY_J => 'j',
        KEY_K => 'k',
        KEY_L => 'l',
        KEY_SEMICOLON => ';',
        KEY_APOSTROPHE => '\'',
        KEY_GRAVE => '`',
        KEY_BACKSLASH => '\\',
        KEY_Z => 'z',
        KEY_X => 'x',
        KEY_C => 'c',
        KEY_V => 'v',
        KEY_B => 'b',
        KEY_N => 'n',
        KEY_M => 'm',
        KEY_COMMA => ',',
        KEY_DOT => '.',
        KEY_SLASH => '/',
        KEY_SPACE => ' ',
        KEY_TAB => '\t',
        KEY_ENTER => '\n',
        KEY_BACKSPACE => 0x08,
        KEY_ESC => 0x1B,
        KEY_DELETE => 0x7F,
        else => null,
    };
}

/// Map unshifted character to shifted character.
fn shiftChar(c: u8) u8 {
    return switch (c) {
        '1' => '!',
        '2' => '@',
        '3' => '#',
        '4' => '$',
        '5' => '%',
        '6' => '^',
        '7' => '&',
        '8' => '*',
        '9' => '(',
        '0' => ')',
        '-' => '_',
        '=' => '+',
        '[' => '{',
        ']' => '}',
        ';' => ':',
        '\'' => '"',
        '`' => '~',
        '\\' => '|',
        ',' => '<',
        '.' => '>',
        '/' => '?',
        else => c,
    };
}

// Linux evdev keycodes (from linux/input-event-codes.h)
const KEY_ESC: u16 = 1;
const KEY_1: u16 = 2;
const KEY_2: u16 = 3;
const KEY_3: u16 = 4;
const KEY_4: u16 = 5;
const KEY_5: u16 = 6;
const KEY_6: u16 = 7;
const KEY_7: u16 = 8;
const KEY_8: u16 = 9;
const KEY_9: u16 = 10;
const KEY_0: u16 = 11;
const KEY_MINUS: u16 = 12;
const KEY_EQUAL: u16 = 13;
const KEY_BACKSPACE: u16 = 14;
const KEY_TAB: u16 = 15;
const KEY_Q: u16 = 16;
const KEY_W: u16 = 17;
const KEY_E: u16 = 18;
const KEY_R: u16 = 19;
const KEY_T: u16 = 20;
const KEY_Y: u16 = 21;
const KEY_U: u16 = 22;
const KEY_I: u16 = 23;
const KEY_O: u16 = 24;
const KEY_P: u16 = 25;
const KEY_LEFTBRACE: u16 = 26;
const KEY_RIGHTBRACE: u16 = 27;
const KEY_ENTER: u16 = 28;
const KEY_LEFTCTRL: u16 = 29;
const KEY_A: u16 = 30;
const KEY_S: u16 = 31;
const KEY_D: u16 = 32;
const KEY_F: u16 = 33;
const KEY_G: u16 = 34;
const KEY_H: u16 = 35;
const KEY_J: u16 = 36;
const KEY_K: u16 = 37;
const KEY_L: u16 = 38;
const KEY_SEMICOLON: u16 = 39;
const KEY_APOSTROPHE: u16 = 40;
const KEY_GRAVE: u16 = 41;
const KEY_LEFTSHIFT: u16 = 42;
const KEY_BACKSLASH: u16 = 43;
const KEY_Z: u16 = 44;
const KEY_X: u16 = 45;
const KEY_C: u16 = 46;
const KEY_V: u16 = 47;
const KEY_B: u16 = 48;
const KEY_N: u16 = 49;
const KEY_M: u16 = 50;
const KEY_COMMA: u16 = 51;
const KEY_DOT: u16 = 52;
const KEY_SLASH: u16 = 53;
const KEY_RIGHTSHIFT: u16 = 54;
const KEY_SPACE: u16 = 57;
const KEY_CAPSLOCK: u16 = 58;
const KEY_DELETE: u16 = 111;
const KEY_RIGHTCTRL: u16 = 97;
const KEY_LEFTALT: u16 = 56;
const KEY_RIGHTALT: u16 = 100;

// Arrow keys, Home, End (evdev keycodes)
const KEY_UP: u16 = 103;
const KEY_DOWN: u16 = 108;
const KEY_LEFT: u16 = 105;
const KEY_RIGHT: u16 = 106;
const KEY_HOME: u16 = 102;
const KEY_END: u16 = 107;
