/// Fornax userspace network library — module root.
///
/// Re-exports all network submodules for convenient access via fx.net.
pub const ethernet = @import("ethernet.zig");
pub const ipv4 = @import("ipv4.zig");
pub const arp = @import("arp.zig");
pub const tcp = @import("tcp.zig");
pub const dns = @import("dns.zig");
pub const icmp = @import("icmp.zig");

// Convenience type aliases
pub const TcpStack = tcp.TcpStack;
pub const ArpTable = arp.ArpTable;
pub const DnsResolver = dns.DnsResolver;
pub const IcmpHandler = icmp.IcmpHandler;
