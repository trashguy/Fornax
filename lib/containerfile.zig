/// Containerfile/Dockerfile parser for Fornax.
///
/// Parses a Containerfile source into a list of instructions.
/// Supports: FROM, COPY, RUN, CMD, WORKDIR, ENV, EXPOSE,
///           ENTRYPOINT, LABEL, ADD, USER, comments (#),
///           line continuation (\).

pub const Kind = enum {
    from,
    copy,
    run,
    cmd,
    workdir,
    env,
    expose,
    entrypoint,
    label,
    add,
    user,
};

pub const Instruction = struct {
    kind: Kind,
    /// Raw argument text (points into source).
    args: []const u8,
    /// Line number (1-based) for error reporting.
    line: u32,
};

/// Parse a Containerfile source into a list of instructions.
/// Returns the number of instructions written to `out`.
pub fn parse(source: []const u8, out: []Instruction) usize {
    var count: usize = 0;
    var pos: usize = 0;
    var line_num: u32 = 1;

    while (pos < source.len and count < out.len) {
        // Skip leading whitespace
        while (pos < source.len and (source[pos] == ' ' or source[pos] == '\t')) : (pos += 1) {}

        // Empty line or end
        if (pos >= source.len) break;
        if (source[pos] == '\n') {
            pos += 1;
            line_num += 1;
            continue;
        }

        // Comment
        if (source[pos] == '#') {
            pos = skipToEol(source, pos);
            line_num += 1;
            continue;
        }

        // Find the end of the logical line (handle \ continuation)
        const logical_start = pos;
        var logical_end = pos;
        while (true) {
            logical_end = findEol(source, logical_end);
            // Check for line continuation: if last non-whitespace char before EOL is '\'
            if (logical_end > logical_start and source[logical_end - 1] == '\\') {
                // Skip past the newline
                if (logical_end < source.len and source[logical_end] == '\n') {
                    logical_end += 1;
                    line_num += 1;
                    continue;
                }
            }
            break;
        }

        const logical_line = source[logical_start..logical_end];

        // Parse instruction keyword
        const kw_end = findSpace(logical_line, 0);
        if (kw_end == 0) {
            pos = if (logical_end < source.len) logical_end + 1 else logical_end;
            line_num += 1;
            continue;
        }

        const keyword = logical_line[0..kw_end];
        const kind_opt = matchKeyword(keyword);

        if (kind_opt) |kind| {
            // Skip whitespace after keyword
            var args_start = kw_end;
            while (args_start < logical_line.len and (logical_line[args_start] == ' ' or logical_line[args_start] == '\t')) : (args_start += 1) {}

            // Trim trailing whitespace
            var args_end = logical_line.len;
            while (args_end > args_start and (logical_line[args_end - 1] == ' ' or logical_line[args_end - 1] == '\t' or
                logical_line[args_end - 1] == '\n' or logical_line[args_end - 1] == '\r'))
            {
                args_end -= 1;
            }

            out[count] = .{
                .kind = kind,
                .args = logical_line[args_start..args_end],
                .line = line_num,
            };
            count += 1;
        }

        pos = if (logical_end < source.len) logical_end + 1 else logical_end;
        line_num += 1;
    }

    return count;
}

/// Parse a CMD or ENTRYPOINT in JSON array form: ["cmd", "arg1", "arg2"]
/// Returns the inner string for single-element arrays, or the raw content.
pub fn parseJsonArray(args: []const u8) []const u8 {
    if (args.len < 2) return args;
    if (args[0] != '[') return args;

    // Find first quoted string
    var i: usize = 1;
    while (i < args.len and args[i] != '"') : (i += 1) {}
    if (i >= args.len) return args;
    i += 1; // skip opening quote
    const start = i;
    while (i < args.len and args[i] != '"') : (i += 1) {}
    return args[start..i];
}

// ── Internal helpers ──

fn matchKeyword(kw: []const u8) ?Kind {
    if (eqlCI(kw, "FROM")) return .from;
    if (eqlCI(kw, "COPY")) return .copy;
    if (eqlCI(kw, "RUN")) return .run;
    if (eqlCI(kw, "CMD")) return .cmd;
    if (eqlCI(kw, "WORKDIR")) return .workdir;
    if (eqlCI(kw, "ENV")) return .env;
    if (eqlCI(kw, "EXPOSE")) return .expose;
    if (eqlCI(kw, "ENTRYPOINT")) return .entrypoint;
    if (eqlCI(kw, "LABEL")) return .label;
    if (eqlCI(kw, "ADD")) return .add;
    if (eqlCI(kw, "USER")) return .user;
    return null;
}

fn eqlCI(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'a' and ca <= 'z') ca - 32 else ca;
        const lb = if (cb >= 'a' and cb <= 'z') cb - 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

fn findEol(src: []const u8, start: usize) usize {
    var i = start;
    while (i < src.len and src[i] != '\n') : (i += 1) {}
    return i;
}

fn skipToEol(src: []const u8, start: usize) usize {
    var i = start;
    while (i < src.len and src[i] != '\n') : (i += 1) {}
    if (i < src.len) i += 1; // skip the newline
    return i;
}

fn findSpace(line: []const u8, start: usize) usize {
    var i = start;
    while (i < line.len and line[i] != ' ' and line[i] != '\t') : (i += 1) {}
    return i;
}
