/// fay-build — Fornax package builder (host tool).
///
/// Builds packages from FAYBUILD descriptions and generates repo.json.
///
/// Usage:
///   fay-build <ports-dir> <pkg-name> [--arch x86_64] [--output <dir>]
///   fay-build --gen-repo <ports-dir> --base-url <url> --output repo.json
const std = @import("std");

const FAYBUILD_NAME = "FAYBUILD";

// ── FAYBUILD JSON Schema ────────────────────────────────────────────
// {
//   "name": "hello",
//   "version": "1.0.0",
//   "description": "Hello world test package",
//   "category": "core",
//   "depends": [],
//   "sources": [{ "url": "...", "sha256": "..." }],
//   "build": ["make"],
//   "package": ["make DESTDIR=$pkgdir install"]
// }

const FayBuild = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,
    category: []const u8,
    depends: std.ArrayList([]const u8),
    sources: std.ArrayList(Source),
    build_cmds: std.ArrayList([]const u8),
    package_cmds: std.ArrayList([]const u8),

    const Source = struct {
        url: []const u8,
        sha256: []const u8,
    };
};

fn parseFayBuild(alloc: std.mem.Allocator, content: []const u8) !FayBuild {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, content, .{});
    const root = parsed.value;

    var fb = FayBuild{
        .name = "",
        .version = "",
        .description = "",
        .category = "",
        .depends = .empty,
        .sources = .empty,
        .build_cmds = .empty,
        .package_cmds = .empty,
    };

    // Support both schemas: name/version/description and pkgname/pkgver/pkgdesc
    if (root.object.get("name")) |v| fb.name = v.string;
    if (root.object.get("pkgname")) |v| fb.name = v.string;

    if (root.object.get("version")) |v| {
        fb.version = v.string;
    } else if (root.object.get("pkgver")) |v| {
        // Build version string: [epoch:]pkgver[-pkgrel]
        const pkgver = v.string;
        const epoch = if (root.object.get("epoch")) |e| e.integer else 0;
        const pkgrel = if (root.object.get("pkgrel")) |r| r.integer else 0;
        if (epoch > 0) {
            fb.version = try std.fmt.allocPrint(alloc, "{d}:{s}-{d}", .{ epoch, pkgver, pkgrel });
        } else if (pkgrel > 0) {
            fb.version = try std.fmt.allocPrint(alloc, "{s}-{d}", .{ pkgver, pkgrel });
        } else {
            fb.version = pkgver;
        }
    }

    if (root.object.get("description")) |v| fb.description = v.string;
    if (root.object.get("pkgdesc")) |v| fb.description = v.string;
    if (root.object.get("category")) |v| fb.category = v.string;

    if (root.object.get("depends")) |arr| {
        for (arr.array.items) |item| {
            try fb.depends.append(alloc, item.string);
        }
    }

    // Support both "sources" (new) and "source" (Arch-style) formats
    if (root.object.get("sources")) |arr| {
        for (arr.array.items) |item| {
            const url = if (item.object.get("url")) |v| v.string else continue;
            const s256 = if (item.object.get("sha256")) |v| v.string else "";
            try fb.sources.append(alloc, .{ .url = url, .sha256 = s256 });
        }
    } else if (root.object.get("source")) |arr| {
        const sha_arr = root.object.get("sha256sums");
        for (arr.array.items, 0..) |item, i| {
            const s256 = if (sha_arr) |sa| (if (i < sa.array.items.len) sa.array.items[i].string else "") else "";
            try fb.sources.append(alloc, .{ .url = item.string, .sha256 = s256 });
        }
    }

    if (root.object.get("build")) |arr| {
        for (arr.array.items) |item| {
            try fb.build_cmds.append(alloc, item.string);
        }
    }

    if (root.object.get("package")) |arr| {
        for (arr.array.items) |item| {
            try fb.package_cmds.append(alloc, item.string);
        }
    }

    if (fb.name.len == 0 or fb.version.len == 0) {
        return error.InvalidFayBuild;
    }

    return fb;
}

// ── SHA-256 file hashing ────────────────────────────────────────────

fn sha256File(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    const digest = hasher.finalResult();
    const hex_chars = "0123456789abcdef";
    const result = try alloc.alloc(u8, 64);
    for (0..32) |i| {
        result[i * 2] = hex_chars[digest[i] >> 4];
        result[i * 2 + 1] = hex_chars[digest[i] & 0x0F];
    }
    return result;
}

// ── Tar.gz package creation ─────────────────────────────────────────

fn createTarGz(alloc: std.mem.Allocator, pkg_dir: []const u8, output_path: []const u8, pkginfo_json: []const u8) !void {
    // Use system tar+gzip since we're a host tool
    // First write .PKGINFO into the package directory
    {
        const pkginfo_path = try std.fs.path.join(alloc, &.{ pkg_dir, ".PKGINFO" });
        const f = try std.fs.cwd().createFile(pkginfo_path, .{});
        defer f.close();
        try f.writeAll(pkginfo_json);
    }

    // Create tar.gz using system tar
    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "tar", "czf", output_path, "-C", pkg_dir, "." },
    });
    alloc.free(result.stdout);
    alloc.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        return error.TarFailed;
    }
}

// ── Build a single package ──────────────────────────────────────────

fn buildPackage(alloc: std.mem.Allocator, ports_dir: []const u8, pkg_name: []const u8, arch: []const u8, output_dir: []const u8) !void {
    // Find FAYBUILD — search category dirs
    var faybuild_path: ?[]const u8 = null;
    var fb_content: []const u8 = undefined;

    // Try direct path first: ports_dir/*/pkg_name/FAYBUILD
    var ports = try std.fs.cwd().openDir(ports_dir, .{ .iterate = true });
    defer ports.close();

    var iter = ports.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        const try_path = try std.fs.path.join(alloc, &.{ ports_dir, entry.name, pkg_name, FAYBUILD_NAME });
        if (std.fs.cwd().openFile(try_path, .{})) |f| {
            fb_content = try f.readToEndAlloc(alloc, 1024 * 1024);
            f.close();
            faybuild_path = try_path;
            break;
        } else |_| {}
    }

    if (faybuild_path == null) {
        std.debug.print("Error: FAYBUILD not found for package '{s}' in {s}\n", .{ pkg_name, ports_dir });
        std.process.exit(1);
    }

    std.debug.print("Building {s} from {s}\n", .{ pkg_name, faybuild_path.? });
    const fb = parseFayBuild(alloc, fb_content) catch |e| {
        std.debug.print("Error: invalid FAYBUILD: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };

    // Create build directory
    const build_dir = try std.fmt.allocPrint(alloc, "/tmp/fay-build-{s}-{s}", .{ fb.name, fb.version });
    const pkg_dir = try std.fmt.allocPrint(alloc, "/tmp/fay-pkg-{s}-{s}", .{ fb.name, fb.version });

    std.fs.cwd().makePath(build_dir) catch {};
    std.fs.cwd().makePath(pkg_dir) catch {};

    // Download sources
    for (fb.sources.items) |src| {
        std.debug.print("  Downloading {s}...\n", .{src.url});

        const basename = std.fs.path.basename(src.url);
        const dest = try std.fs.path.join(alloc, &.{ build_dir, basename });

        const curl_result = try std.process.Child.run(.{
            .allocator = alloc,
            .argv = &.{ "curl", "-fsSL", "-o", dest, src.url },
        });
        alloc.free(curl_result.stdout);
        alloc.free(curl_result.stderr);

        if (curl_result.term != .Exited or curl_result.term.Exited != 0) {
            std.debug.print("Error: download failed for {s}\n", .{src.url});
            std.process.exit(1);
        }

        // Verify SHA-256
        if (src.sha256.len > 0) {
            const actual = try sha256File(alloc, dest);
            if (!std.mem.eql(u8, actual, src.sha256)) {
                std.debug.print("Error: SHA-256 mismatch for {s}\n  expected: {s}\n  got:      {s}\n", .{ basename, src.sha256, actual });
                std.process.exit(1);
            }
            std.debug.print("  SHA-256 OK: {s}\n", .{basename});
        }
    }

    // Build env prefix for shell commands
    const env_prefix = try std.fmt.allocPrint(alloc,
        "srcdir='{s}' pkgdir='{s}' ARCH='{s}' ", .{ build_dir, pkg_dir, arch });

    // Run build commands
    for (fb.build_cmds.items) |cmd| {
        std.debug.print("  Build: {s}\n", .{cmd});
        const full_cmd = try std.fmt.allocPrint(alloc, "{s}{s}", .{ env_prefix, cmd });
        const result = try std.process.Child.run(.{
            .allocator = alloc,
            .argv = &.{ "sh", "-c", full_cmd },
            .cwd = build_dir,
        });
        alloc.free(result.stdout);
        if (result.stderr.len > 0) {
            std.debug.print("  stderr: {s}\n", .{result.stderr});
        }
        alloc.free(result.stderr);

        if (result.term != .Exited or result.term.Exited != 0) {
            const code: u8 = if (result.term == .Exited) result.term.Exited else 1;
            std.debug.print("Error: build command failed with exit code {d}\n", .{code});
            std.process.exit(1);
        }
    }

    // Run package commands
    for (fb.package_cmds.items) |cmd| {
        std.debug.print("  Package: {s}\n", .{cmd});
        const full_cmd = try std.fmt.allocPrint(alloc, "{s}{s}", .{ env_prefix, cmd });
        const result = try std.process.Child.run(.{
            .allocator = alloc,
            .argv = &.{ "sh", "-c", full_cmd },
            .cwd = build_dir,
        });
        alloc.free(result.stdout);
        alloc.free(result.stderr);

        if (result.term != .Exited or result.term.Exited != 0) {
            std.debug.print("Error: package command failed\n", .{});
            std.process.exit(1);
        }
    }

    // Generate .PKGINFO JSON
    var pkginfo: std.ArrayList(u8) = .empty;
    const writer = pkginfo.writer(alloc);

    try writer.writeAll("{\"name\":\"");
    try writer.writeAll(fb.name);
    try writer.writeAll("\",\"version\":\"");
    try writer.writeAll(fb.version);
    try writer.writeAll("\",\"description\":\"");
    try writer.writeAll(fb.description);
    try writer.writeAll("\",\"depends\":[");
    for (fb.depends.items, 0..) |dep, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeByte('"');
        try writer.writeAll(dep);
        try writer.writeByte('"');
    }
    try writer.writeAll("]}");

    // Create tar.gz
    const output_name = try std.fmt.allocPrint(alloc, "{s}-{s}.tar.gz", .{ fb.name, fb.version });
    const output_path = try std.fs.path.join(alloc, &.{ output_dir, output_name });

    try createTarGz(alloc, pkg_dir, output_path, pkginfo.items);

    // Print hash
    const pkg_hash = try sha256File(alloc, output_path);
    std.debug.print("  Output: {s}\n", .{output_path});
    std.debug.print("  SHA-256: {s}\n", .{pkg_hash});

    // Cleanup
    std.fs.cwd().deleteTree(build_dir) catch {};
    std.fs.cwd().deleteTree(pkg_dir) catch {};
}

// ── Generate repo.json ──────────────────────────────────────────────

fn genRepo(alloc: std.mem.Allocator, ports_dir: []const u8, base_url: []const u8, output_path: []const u8) !void {
    // Build entire repo.json in memory then write at once
    var buf: std.ArrayList(u8) = .empty;

    try buf.appendSlice(alloc, "{\n  \"packages\": {\n");

    var ports = try std.fs.cwd().openDir(ports_dir, .{ .iterate = true });
    defer ports.close();

    var pkg_count: usize = 0;
    var cat_iter = ports.iterate();
    while (try cat_iter.next()) |cat_entry| {
        if (cat_entry.kind != .directory) continue;

        var cat_dir = try ports.openDir(cat_entry.name, .{ .iterate = true });
        defer cat_dir.close();

        var pkg_iter = cat_dir.iterate();
        while (try pkg_iter.next()) |pkg_entry| {
            if (pkg_entry.kind != .directory) continue;

            const fb_rel = try std.fs.path.join(alloc, &.{ pkg_entry.name, FAYBUILD_NAME });
            const fb_file = cat_dir.openFile(fb_rel, .{}) catch continue;
            const fb_content = try fb_file.readToEndAlloc(alloc, 1024 * 1024);
            fb_file.close();

            const fb = parseFayBuild(alloc, fb_content) catch continue;

            if (pkg_count > 0) try buf.appendSlice(alloc, ",\n");

            const entry = try std.fmt.allocPrint(alloc,
                \\    "{s}": {{
                \\      "version": "{s}",
                \\      "description": "{s}",
                \\      "url": "{s}/{s}-{s}.tar.gz",
                \\      "depends": [
            , .{ fb.name, fb.version, fb.description, base_url, fb.name, fb.version });
            try buf.appendSlice(alloc, entry);

            for (fb.depends.items, 0..) |dep, i| {
                if (i > 0) try buf.appendSlice(alloc, ",");
                const dep_str = try std.fmt.allocPrint(alloc, "\"{s}\"", .{dep});
                try buf.appendSlice(alloc, dep_str);
            }
            try buf.appendSlice(alloc, "],\n");

            // SHA-256 of pre-built package (if it exists)
            const pkg_file_name = try std.fmt.allocPrint(alloc, "{s}-{s}.tar.gz", .{ fb.name, fb.version });
            const pkg_path = try std.fs.path.join(alloc, &.{ ports_dir, pkg_file_name });
            if (sha256File(alloc, pkg_path)) |hash| {
                const sha_line = try std.fmt.allocPrint(alloc, "      \"sha256\": \"{s}\"\n", .{hash});
                try buf.appendSlice(alloc, sha_line);
            } else |_| {
                try buf.appendSlice(alloc, "      \"sha256\": \"\"\n");
            }

            try buf.appendSlice(alloc, "    }");
            pkg_count += 1;
            std.debug.print("  Added: {s} {s}\n", .{ fb.name, fb.version });
        }
    }

    try buf.appendSlice(alloc, "\n  }\n}\n");

    // Write to file
    const out_file = try std.fs.cwd().createFile(output_path, .{});
    defer out_file.close();
    try out_file.writeAll(buf.items);

    std.debug.print("Generated {s} ({d} packages)\n", .{ output_path, pkg_count });
}

// ── Main ────────────────────────────────────────────────────────────

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try std.process.argsAlloc(alloc);

    if (args.len < 2) {
        printUsage();
        std.process.exit(1);
    }

    // Check for --gen-repo mode
    if (std.mem.eql(u8, args[1], "--gen-repo")) {
        var ports_dir: ?[]const u8 = null;
        var base_url: ?[]const u8 = null;
        var output: []const u8 = "repo.json";

        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--base-url") and i + 1 < args.len) {
                i += 1;
                base_url = args[i];
            } else if (std.mem.eql(u8, args[i], "--output") and i + 1 < args.len) {
                i += 1;
                output = args[i];
            } else if (ports_dir == null) {
                ports_dir = args[i];
            }
        }

        if (ports_dir == null or base_url == null) {
            std.debug.print("Usage: fay-build --gen-repo <ports-dir> --base-url <url> --output repo.json\n", .{});
            std.process.exit(1);
        }

        try genRepo(alloc, ports_dir.?, base_url.?, output);
        return;
    }

    // Build mode: fay-build <ports-dir> <pkg-name> [options]
    if (args.len < 3) {
        printUsage();
        std.process.exit(1);
    }

    const ports_dir = args[1];
    const pkg_name = args[2];
    var arch: []const u8 = "x86_64";
    var output_dir: []const u8 = ".";

    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--arch") and i + 1 < args.len) {
            i += 1;
            arch = args[i];
        } else if (std.mem.eql(u8, args[i], "--output") and i + 1 < args.len) {
            i += 1;
            output_dir = args[i];
        }
    }

    try buildPackage(alloc, ports_dir, pkg_name, arch, output_dir);
}

fn printUsage() void {
    std.debug.print(
        \\fay-build — Fornax package builder
        \\
        \\Usage:
        \\  fay-build <ports-dir> <pkg-name> [--arch x86_64] [--output <dir>]
        \\  fay-build --gen-repo <ports-dir> --base-url <url> [--output repo.json]
        \\
        \\Options:
        \\  --arch <arch>      Target architecture (default: x86_64)
        \\  --output <path>    Output directory or file
        \\  --base-url <url>   Base URL for package downloads
        \\
    , .{});
}
