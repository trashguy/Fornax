/// dnstest — DNS lookup test for Fornax.
///
/// Resolves example.com via QEMU DNS forwarder (10.0.2.3) and prints the IP.
const fx = @import("fornax");

export fn _start() noreturn {
    _ = fx.write(1, "dnstest: resolving example.com...\n");

    // Open DNS query interface
    const dns_fd = fx.open("/net/dns");
    if (dns_fd < 0) {
        _ = fx.write(1, "dnstest: failed to open /net/dns\n");
        fx.exit(1);
    }

    // Send query
    const wr = fx.write(dns_fd, "query example.com");
    if (wr == 0) {
        _ = fx.write(1, "dnstest: query failed\n");
        fx.exit(1);
    }

    // Read result
    var buf: [64]u8 = undefined;
    const n = fx.read(dns_fd, &buf);
    if (n <= 0) {
        _ = fx.write(1, "dnstest: no result\n");
        _ = fx.close(dns_fd);
        fx.exit(1);
    }

    _ = fx.write(1, "dnstest: example.com -> ");
    _ = fx.write(1, buf[0..@intCast(n)]);

    _ = fx.close(dns_fd);

    _ = fx.write(1, "dnstest: done\n");
    fx.exit(0);
}
