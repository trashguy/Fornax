const std = @import("std");
const path = @import("path");

const expectEqualStrings = std.testing.expectEqualStrings;

// ── PathBuf.from / appendRaw / slice ────────────────────────────────

test "PathBuf.from and slice" {
    const p = path.PathBuf.from("/hello");
    try expectEqualStrings("/hello", p.slice());
}

test "PathBuf.appendRaw" {
    var p = path.PathBuf.from("/hello");
    _ = p.appendRaw("/world");
    try expectEqualStrings("/hello/world", p.slice());
}

test "PathBuf.append adds separator" {
    var p = path.PathBuf.from("/hello");
    _ = p.append("world");
    try expectEqualStrings("/hello/world", p.slice());
}

test "PathBuf.append no double separator" {
    var p = path.PathBuf.from("/hello/");
    _ = p.append("world");
    try expectEqualStrings("/hello/world", p.slice());
}

test "PathBuf.reset" {
    var p = path.PathBuf.from("/hello");
    p.reset();
    try expectEqualStrings("", p.slice());
}

// ── normalize ───────────────────────────────────────────────────────

test "normalize: dot component" {
    var p = path.PathBuf.from("a/./b");
    _ = p.normalize();
    try expectEqualStrings("a/b", p.slice());
}

test "normalize: dotdot component" {
    var p = path.PathBuf.from("a/b/../c");
    _ = p.normalize();
    try expectEqualStrings("a/c", p.slice());
}

test "normalize: leading slash preserved" {
    var p = path.PathBuf.from("/a/./b/../c");
    _ = p.normalize();
    try expectEqualStrings("/a/c", p.slice());
}

test "normalize: root stays root" {
    var p = path.PathBuf.from("/");
    _ = p.normalize();
    try expectEqualStrings("/", p.slice());
}

test "normalize: collapse to root" {
    var p = path.PathBuf.from("/a/..");
    _ = p.normalize();
    try expectEqualStrings("/", p.slice());
}

test "normalize: multiple slashes" {
    var p = path.PathBuf.from("/a///b");
    _ = p.normalize();
    try expectEqualStrings("/a/b", p.slice());
}

// ── join ────────────────────────────────────────────────────────────

test "join: two components" {
    const p = path.join("/usr", "bin");
    try expectEqualStrings("/usr/bin", p.slice());
}

test "join: base with trailing slash" {
    const p = path.join("/usr/", "bin");
    try expectEqualStrings("/usr/bin", p.slice());
}

// ── basename ────────────────────────────────────────────────────────

test "basename: simple path" {
    try expectEqualStrings("file.txt", path.basename("/usr/bin/file.txt"));
}

test "basename: root" {
    try expectEqualStrings("", path.basename("/"));
}

test "basename: no slash" {
    try expectEqualStrings("hello", path.basename("hello"));
}

test "basename: empty" {
    try expectEqualStrings("", path.basename(""));
}

// ── dirname ─────────────────────────────────────────────────────────

test "dirname: simple path" {
    try expectEqualStrings("/usr/bin", path.dirname("/usr/bin/file.txt"));
}

test "dirname: root file" {
    try expectEqualStrings("/", path.dirname("/file.txt"));
}

test "dirname: no slash" {
    try expectEqualStrings(".", path.dirname("file.txt"));
}

test "dirname: empty" {
    try expectEqualStrings(".", path.dirname(""));
}
