// Test discovery root — imports all test modules.
// Run with: zig build test
comptime {
    _ = @import("fmt_test.zig");
    _ = @import("str_test.zig");
    _ = @import("path_test.zig");
    _ = @import("crc32_test.zig");
    _ = @import("sha256_test.zig");
    _ = @import("json_test.zig");
    _ = @import("ethernet_test.zig");
    _ = @import("ipv4_test.zig");
    _ = @import("arp_test.zig");
    _ = @import("tcp_test.zig");
    _ = @import("dns_test.zig");
    _ = @import("icmp_test.zig");
    _ = @import("time_test.zig");
}
