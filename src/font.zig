/// VGA 8x16 bitmap font loader.
/// Font covers ASCII 32 (space) through 126 (~), 95 glyphs, 16 bytes each.
const font_data = @embedFile("font8x16.bin");

pub const char_width = 8;
pub const char_height = 16;
pub const first_char = 32;
pub const last_char = 126;
const glyph_count = last_char - first_char + 1;

comptime {
    if (font_data.len != glyph_count * char_height) {
        @compileError("font8x16.bin has wrong size");
    }
}

/// Returns the 16-byte glyph bitmap for the given ASCII character,
/// or the glyph for '?' if the character is out of range.
pub fn getGlyph(c: u8) *const [char_height]u8 {
    const index: usize = if (c >= first_char and c <= last_char)
        c - first_char
    else
        '?' - first_char;
    return font_data[index * char_height ..][0..char_height];
}
