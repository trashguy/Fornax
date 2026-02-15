/// dnstest — DNS lookup test for Fornax.
///
/// Resolves example.com via QEMU DNS forwarder (10.0.2.3) and prints the IP.
const fx = @import("fornax");

const out = fx.io.Writer.stdout;

export fn _start() noreturn {
    out.puts("dnstest: resolving example.com...\n");

    // Open DNS query interface
    const dns_fd = fx.open("/net/dns");
    if (dns_fd < 0) {
        out.puts("dnstest: failed to open /net/dns\n");
        fx.exit(1);
    }

    // Send query
    const wr = fx.write(dns_fd, "query example.com");
    if (wr == 0) {
        out.puts("dnstest: query failed\n");
        fx.exit(1);
    }

    // Read result
    var buf: [64]u8 = undefined;
    const n = fx.read(dns_fd, &buf);
    if (n <= 0) {
        out.puts("dnstest: no result\n");
        _ = fx.close(dns_fd);
        fx.exit(1);
    }

    out.puts("dnstest: example.com -> ");
    out.puts(buf[0..@intCast(n)]);

    _ = fx.close(dns_fd);

    out.puts("dnstest: done\n");
    fx.exit(0);
}
