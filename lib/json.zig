// SAX-style streaming JSON tokenizer.
// No DOM, no allocation. Operates on a source buffer (zero-copy string slices).

pub const TokenKind = enum {
    object_begin,
    object_end,
    array_begin,
    array_end,
    string,
    number,
    true_val,
    false_val,
    null_val,
    colon,
    comma,
    eof,
    err,
};

pub const Token = struct {
    kind: TokenKind,
    str_value: []const u8, // slice into source for strings/numbers
    int_value: i64, // parsed integer for number tokens
};

pub const Parser = struct {
    src: []const u8,
    pos: usize,

    pub fn init(source: []const u8) Parser {
        return .{ .src = source, .pos = 0 };
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.src.len) {
            switch (self.src[self.pos]) {
                ' ', '\t', '\n', '\r' => self.pos += 1,
                else => return,
            }
        }
    }

    pub fn next(self: *Parser) Token {
        self.skipWhitespace();
        if (self.pos >= self.src.len) return .{ .kind = .eof, .str_value = "", .int_value = 0 };

        const c = self.src[self.pos];
        switch (c) {
            '{' => {
                self.pos += 1;
                return .{ .kind = .object_begin, .str_value = "{", .int_value = 0 };
            },
            '}' => {
                self.pos += 1;
                return .{ .kind = .object_end, .str_value = "}", .int_value = 0 };
            },
            '[' => {
                self.pos += 1;
                return .{ .kind = .array_begin, .str_value = "[", .int_value = 0 };
            },
            ']' => {
                self.pos += 1;
                return .{ .kind = .array_end, .str_value = "]", .int_value = 0 };
            },
            ':' => {
                self.pos += 1;
                return .{ .kind = .colon, .str_value = ":", .int_value = 0 };
            },
            ',' => {
                self.pos += 1;
                return .{ .kind = .comma, .str_value = ",", .int_value = 0 };
            },
            '"' => return self.readString(),
            't' => return self.readLiteral("true", .true_val),
            'f' => return self.readLiteral("false", .false_val),
            'n' => return self.readLiteral("null", .null_val),
            '-', '0'...'9' => return self.readNumber(),
            else => {
                self.pos += 1;
                return .{ .kind = .err, .str_value = self.src[self.pos - 1 .. self.pos], .int_value = 0 };
            },
        }
    }

    fn readString(self: *Parser) Token {
        self.pos += 1; // skip opening "
        const start = self.pos;
        while (self.pos < self.src.len) {
            if (self.src[self.pos] == '\\') {
                self.pos += 2; // skip escaped char
                continue;
            }
            if (self.src[self.pos] == '"') {
                const val = self.src[start..self.pos];
                self.pos += 1; // skip closing "
                return .{ .kind = .string, .str_value = val, .int_value = 0 };
            }
            self.pos += 1;
        }
        return .{ .kind = .err, .str_value = self.src[start..self.pos], .int_value = 0 };
    }

    fn readNumber(self: *Parser) Token {
        const start = self.pos;
        var negative = false;
        if (self.pos < self.src.len and self.src[self.pos] == '-') {
            negative = true;
            self.pos += 1;
        }
        var val: i64 = 0;
        while (self.pos < self.src.len and self.src[self.pos] >= '0' and self.src[self.pos] <= '9') {
            val = val * 10 + (self.src[self.pos] - '0');
            self.pos += 1;
        }
        // Skip fractional part (no float support, but don't error)
        if (self.pos < self.src.len and self.src[self.pos] == '.') {
            self.pos += 1;
            while (self.pos < self.src.len and self.src[self.pos] >= '0' and self.src[self.pos] <= '9') {
                self.pos += 1;
            }
        }
        // Skip exponent
        if (self.pos < self.src.len and (self.src[self.pos] == 'e' or self.src[self.pos] == 'E')) {
            self.pos += 1;
            if (self.pos < self.src.len and (self.src[self.pos] == '+' or self.src[self.pos] == '-')) {
                self.pos += 1;
            }
            while (self.pos < self.src.len and self.src[self.pos] >= '0' and self.src[self.pos] <= '9') {
                self.pos += 1;
            }
        }
        if (negative) val = -val;
        return .{ .kind = .number, .str_value = self.src[start..self.pos], .int_value = val };
    }

    fn readLiteral(self: *Parser, expected: []const u8, kind: TokenKind) Token {
        if (self.pos + expected.len <= self.src.len) {
            for (0..expected.len) |i| {
                if (self.src[self.pos + i] != expected[i]) {
                    self.pos += 1;
                    return .{ .kind = .err, .str_value = "", .int_value = 0 };
                }
            }
            self.pos += expected.len;
            return .{ .kind = kind, .str_value = expected, .int_value = 0 };
        }
        self.pos += 1;
        return .{ .kind = .err, .str_value = "", .int_value = 0 };
    }

    /// Skip an entire JSON value (object, array, or primitive).
    pub fn skipValue(self: *Parser) bool {
        const tok = self.next();
        switch (tok.kind) {
            .object_begin => {
                var first = true;
                while (true) {
                    self.skipWhitespace();
                    if (self.pos < self.src.len and self.src[self.pos] == '}') {
                        self.pos += 1;
                        return true;
                    }
                    if (!first) {
                        const c = self.next();
                        if (c.kind != .comma) return false;
                    }
                    first = false;
                    // key
                    const k = self.next();
                    if (k.kind != .string) return false;
                    const col = self.next();
                    if (col.kind != .colon) return false;
                    if (!self.skipValue()) return false;
                }
            },
            .array_begin => {
                var first = true;
                while (true) {
                    self.skipWhitespace();
                    if (self.pos < self.src.len and self.src[self.pos] == ']') {
                        self.pos += 1;
                        return true;
                    }
                    if (!first) {
                        const c = self.next();
                        if (c.kind != .comma) return false;
                    }
                    first = false;
                    if (!self.skipValue()) return false;
                }
            },
            .string, .number, .true_val, .false_val, .null_val => return true,
            else => return false,
        }
    }

    /// Convenience: read the next token and return its string value if it's a string.
    pub fn expectString(self: *Parser) ?[]const u8 {
        const tok = self.next();
        if (tok.kind == .string) return tok.str_value;
        return null;
    }

    /// Convenience: read the next token and return its integer value if it's a number.
    pub fn expectInt(self: *Parser) ?i64 {
        const tok = self.next();
        if (tok.kind == .number) return tok.int_value;
        return null;
    }

    /// Scan an object for a key. Assumes we just read '{' or ',' within the object.
    /// Positions parser after the ':' so the caller can read the value.
    /// Returns true if key was found.
    pub fn findKey(self: *Parser, key: []const u8) bool {
        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.src.len) return false;
            if (self.src[self.pos] == '}') return false;

            // Skip comma if present
            if (self.src[self.pos] == ',') {
                self.pos += 1;
                self.skipWhitespace();
            }

            // Read key
            const tok = self.next();
            if (tok.kind != .string) return false;

            // Read colon
            const col = self.next();
            if (col.kind != .colon) return false;

            if (strEql(tok.str_value, key)) return true;

            // Skip value
            if (!self.skipValue()) return false;
        }
    }
};

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (ac != bc) return false;
    }
    return true;
}
