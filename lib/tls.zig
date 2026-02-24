// TLS client wrapper around BearSSL.
// All buffers caller-provided (BSS). No allocation.

const fx = @import("fornax");

const c = @cImport({
    @cInclude("bearssl.h");
});

pub const BR_SSL_CLOSED = 0x0001;
pub const BR_SSL_SENDREC = 0x0002;
pub const BR_SSL_RECVREC = 0x0004;
pub const BR_SSL_SENDAPP = 0x0008;
pub const BR_SSL_RECVAPP = 0x0010;

/// Half-duplex I/O buffer size (sufficient for HTTP request-then-response).
pub const IOBUF_SIZE = 16384 + 325; // BR_SSL_BUFSIZE_MONO

/// X.509 proxy that delegates to br_x509_minimal but overrides end_chain
/// to always return 0 (success), skipping certificate chain validation.
/// This allows insecure TLS connections (-k / --insecure).
const NoValidateX509 = struct {
    vtable: [*c]const c.br_x509_class,
    inner: *c.br_x509_minimal_context, // points to TlsConnection.x509_ctx

    const vtable_impl = c.br_x509_class{
        .context_size = @sizeOf(NoValidateX509),
        .start_chain = proxyStartChain,
        .start_cert = proxyStartCert,
        .append = proxyAppend,
        .end_cert = proxyEndCert,
        .end_chain = proxyEndChain,
        .get_pkey = proxyGetPkey,
    };

    fn init(self: *NoValidateX509, inner: *c.br_x509_minimal_context) void {
        self.vtable = &vtable_impl;
        self.inner = inner;
    }

    fn getInner(ctx_pp: [*c][*c]const c.br_x509_class) *NoValidateX509 {
        return @fieldParentPtr("vtable", @as(*[*c]const c.br_x509_class, @ptrCast(ctx_pp)));
    }

    fn proxyStartChain(ctx_pp: [*c][*c]const c.br_x509_class, server_name: [*c]const u8) callconv(.c) void {
        const self = getInner(ctx_pp);
        self.inner.vtable.*.start_chain.?(@ptrCast(&self.inner.vtable), server_name);
    }
    fn proxyStartCert(ctx_pp: [*c][*c]const c.br_x509_class, length: u32) callconv(.c) void {
        const self = getInner(ctx_pp);
        self.inner.vtable.*.start_cert.?(@ptrCast(&self.inner.vtable), length);
    }
    fn proxyAppend(ctx_pp: [*c][*c]const c.br_x509_class, buf: [*c]const u8, len: usize) callconv(.c) void {
        const self = getInner(ctx_pp);
        self.inner.vtable.*.append.?(@ptrCast(&self.inner.vtable), buf, len);
    }
    fn proxyEndCert(ctx_pp: [*c][*c]const c.br_x509_class) callconv(.c) void {
        const self = getInner(ctx_pp);
        self.inner.vtable.*.end_cert.?(@ptrCast(&self.inner.vtable));
    }
    fn proxyEndChain(ctx_pp: [*c][*c]const c.br_x509_class) callconv(.c) c_uint {
        const self = getInner(ctx_pp);
        // Call inner to let it finish parsing, but ignore the result
        _ = self.inner.vtable.*.end_chain.?(@ptrCast(&self.inner.vtable));
        return 0; // Always succeed — skip chain validation
    }
    fn proxyGetPkey(ctx_pp: [*c]const [*c]const c.br_x509_class, usages: [*c]c_uint) callconv(.c) [*c]const c.br_x509_pkey {
        // Cast away const for @fieldParentPtr (safe: we only read through it)
        const mutable_pp: [*c][*c]const c.br_x509_class = @constCast(ctx_pp);
        const self = getInner(mutable_pp);
        // Clear any validation error (e.g. expired cert) so the inner's
        // get_pkey returns the key instead of NULL. In skip_verify mode
        // we accepted the chain regardless, but the inner still has
        // its error flag set from end_chain/end_cert processing.
        self.inner.err = 0;
        return self.inner.vtable.*.get_pkey.?(@ptrCast(&self.inner.vtable), usages);
    }
};

/// TLS client connection. ~26 KB — MUST be BSS-allocated, never returned by value.
pub const TlsConnection = struct {
    client_ctx: c.br_ssl_client_context,
    x509_ctx: c.br_x509_minimal_context,
    noval_ctx: NoValidateX509,
    iobuf: [IOBUF_SIZE]u8,
    data_fd: i32,
    net_buf: [4096]u8,
    net_buf_pos: usize, // start of unconsumed data
    net_buf_len: usize, // total valid data in net_buf
    closed: bool,

    /// Initialize a TLS connection over an existing TCP data fd.
    /// server_name must be null-terminated (for BearSSL SNI).
    /// Returns true on successful handshake, false on failure.
    pub fn initInPlace(
        self: *TlsConnection,
        data_fd: i32,
        server_name: [*:0]const u8,
        anchors: [*]const c.br_x509_trust_anchor,
        anchor_count: usize,
    ) bool {
        return self.initInPlaceEx(data_fd, server_name, anchors, anchor_count, false);
    }

    /// Initialize with optional certificate verification skip.
    /// When skip_verify is true, all server certificates are accepted (insecure).
    pub fn initInsecure(
        self: *TlsConnection,
        data_fd: i32,
        server_name: [*:0]const u8,
    ) bool {
        // Dummy pointer — never dereferenced since anchor_count=0
        const dummy: [*]const c.br_x509_trust_anchor = @ptrFromInt(@intFromPtr(&self.client_ctx));
        return self.initInPlaceEx(data_fd, server_name, dummy, 0, true);
    }

    fn initInPlaceEx(
        self: *TlsConnection,
        data_fd: i32,
        server_name: [*:0]const u8,
        anchors: [*]const c.br_x509_trust_anchor,
        anchor_count: usize,
        skip_verify: bool,
    ) bool {
        self.data_fd = data_fd;
        self.closed = false;
        self.net_buf_pos = 0;
        self.net_buf_len = 0;

        if (skip_verify) {
            // Initialize minimal x509 with 0 anchors (will fail validation),
            // then wrap with proxy that overrides end_chain to always succeed
            const dummy: [*]const c.br_x509_trust_anchor = @ptrFromInt(@intFromPtr(&self.client_ctx));
            c.br_ssl_client_init_full(&self.client_ctx, &self.x509_ctx, dummy, 0);
            self.noval_ctx.init(&self.x509_ctx);
            c.br_ssl_engine_set_x509(&self.client_ctx.eng, @ptrCast(&self.noval_ctx.vtable));
        } else {
            // Initialize client context with all default algorithms
            c.br_ssl_client_init_full(&self.client_ctx, &self.x509_ctx, anchors, anchor_count);
        }

        // Set current time for certificate validation.
        // BearSSL days count from Jan 1, year 0 (proleptic Gregorian),
        // NOT from Unix epoch (1970). Add the 719528-day offset.
        const epoch_secs = fx.time();
        if (epoch_secs > 0) {
            const UNIX_EPOCH_DAYS: u32 = 719528; // days from year 0 to 1970-01-01
            const days: u32 = UNIX_EPOCH_DAYS + @as(u32, @intCast(epoch_secs / 86400));
            const secs: u32 = @intCast(epoch_secs % 86400);
            c.br_x509_minimal_set_time(&self.x509_ctx, days, secs);
        }

        // Set ALPN protocol names (required by many CDN/load balancers)
        const alpn_names: [1][*c]const u8 = .{"http/1.1"};
        c.br_ssl_engine_set_protocol_names(&self.client_ctx.eng, @constCast(@ptrCast(&alpn_names)), 1);

        // Set half-duplex I/O buffer
        c.br_ssl_engine_set_buffer(&self.client_ctx.eng, &self.iobuf, IOBUF_SIZE, 0);

        // Seed PRNG from /dev/random
        var seed: [48]u8 = undefined;
        const rfd = fx.open("/dev/random");
        if (rfd < 0) return false;
        var total: usize = 0;
        while (total < seed.len) {
            const n = fx.read(rfd, seed[total..]);
            if (n <= 0) break;
            total += @intCast(n);
        }
        _ = fx.close(rfd);
        if (total < 32) return false; // need at least 32 bytes of entropy
        c.br_ssl_engine_inject_entropy(&self.client_ctx.eng, &seed, total);

        // Start handshake
        if (c.br_ssl_client_reset(&self.client_ctx, server_name, 0) == 0) {
            return false;
        }

        // Run handshake to completion
        return self.runHandshake();
    }

    fn runHandshake(self: *TlsConnection) bool {
        var rounds: u32 = 0;
        while (rounds < 200) : (rounds += 1) {
            const state = c.br_ssl_engine_current_state(&self.client_ctx.eng);

            if (state & BR_SSL_CLOSED != 0) {
                return false;
            }

            // Check for app data readiness BEFORE RECVREC — after the
            // handshake completes, both SENDAPP and RECVREC may be set
            // (engine is ready for app data but also willing to receive
            // more records). We must detect completion before reading
            // more data, or we'll consume the server's first response
            // record (or a close_notify) during what should be the
            // post-handshake phase.
            if (state & (BR_SSL_SENDAPP | BR_SSL_RECVAPP) != 0) {
                return true;
            }

            if (state & BR_SSL_SENDREC != 0) {
                if (!self.flushSendrec()) {
                    return false;
                }
                continue;
            }

            if (state & BR_SSL_RECVREC != 0) {
                if (!self.fillRecvrec()) {
                    return false;
                }
                continue;
            }

            // No progress possible
            return false;
        }
        return false;
    }

    /// Read decrypted data. Returns bytes read, 0 on EOF, negative on error.
    pub fn read(self: *TlsConnection, buf: []u8) isize {
        if (self.closed) return 0;
        if (buf.len == 0) return 0;

        while (true) {
            const state = c.br_ssl_engine_current_state(&self.client_ctx.eng);

            if (state & BR_SSL_CLOSED != 0) {
                self.closed = true;
                return 0;
            }

            if (state & BR_SSL_RECVAPP != 0) {
                // Decrypted data available
                var avail: usize = 0;
                const ptr = c.br_ssl_engine_recvapp_buf(&self.client_ctx.eng, &avail);
                if (avail == 0) continue;
                const take = @min(avail, buf.len);
                @memcpy(buf[0..take], ptr[0..take]);
                c.br_ssl_engine_recvapp_ack(&self.client_ctx.eng, take);
                return @intCast(take);
            }

            if (state & BR_SSL_SENDREC != 0) {
                if (!self.flushSendrec()) {
                    self.closed = true;
                    return 0;
                }
                continue;
            }

            if (state & BR_SSL_RECVREC != 0) {
                if (!self.fillRecvrec()) {
                    self.closed = true;
                    return 0;
                }
                continue;
            }

            return 0;
        }
    }

    /// Write plaintext data through TLS. Returns bytes written.
    pub fn write(self: *TlsConnection, data: []const u8) isize {
        if (self.closed) return 0;
        if (data.len == 0) return 0;

        var total: usize = 0;
        while (total < data.len) {
            const state = c.br_ssl_engine_current_state(&self.client_ctx.eng);

            if (state & BR_SSL_CLOSED != 0) {
                self.closed = true;
                break;
            }

            if (state & BR_SSL_SENDAPP != 0) {
                var avail: usize = 0;
                const ptr = c.br_ssl_engine_sendapp_buf(&self.client_ctx.eng, &avail);
                if (avail == 0) continue;
                const chunk = @min(avail, data.len - total);
                @memcpy(ptr[0..chunk], data[total..][0..chunk]);
                c.br_ssl_engine_sendapp_ack(&self.client_ctx.eng, chunk);
                total += chunk;
                // Flush after writing
                c.br_ssl_engine_flush(&self.client_ctx.eng, 0);
                continue;
            }

            if (state & BR_SSL_SENDREC != 0) {
                if (!self.flushSendrec()) {
                    self.closed = true;
                    break;
                }
                continue;
            }

            if (state & BR_SSL_RECVREC != 0) {
                if (!self.fillRecvrec()) {
                    self.closed = true;
                    break;
                }
                continue;
            }

            break; // No progress
        }

        // Ensure all encrypted data is sent on the wire before returning.
        if (total > 0 and !self.closed) {
            var flush_iters: u32 = 0;
            while (flush_iters < 100) : (flush_iters += 1) {
                const state = c.br_ssl_engine_current_state(&self.client_ctx.eng);
                if (state & BR_SSL_SENDREC != 0) {
                    if (!self.flushSendrec()) {
                        self.closed = true;
                        break;
                    }
                } else break;
            }
        }

        if (total > 0) return @intCast(total);
        return 0;
    }

    /// Close the TLS connection (sends close_notify).
    pub fn close(self: *TlsConnection) void {
        if (self.closed) return;
        c.br_ssl_engine_close(&self.client_ctx.eng);

        // Flush close_notify record
        var attempts: u32 = 0;
        while (attempts < 10) : (attempts += 1) {
            const state = c.br_ssl_engine_current_state(&self.client_ctx.eng);
            if (state & BR_SSL_CLOSED != 0) break;
            if (state & BR_SSL_SENDREC != 0) {
                if (!self.flushSendrec()) break;
            } else {
                break;
            }
        }
        self.closed = true;
    }

    /// Get the last BearSSL error code.
    pub fn lastError(self: *const TlsConnection) c_int {
        return c.br_ssl_engine_last_error(&self.client_ctx.eng);
    }

    // ── Internal: pump data between BearSSL and network fd ──────────

    fn flushSendrec(self: *TlsConnection) bool {
        var avail: usize = 0;
        const ptr = c.br_ssl_engine_sendrec_buf(&self.client_ctx.eng, &avail);
        if (avail == 0) return true;

        var sent: usize = 0;
        while (sent < avail) {
            const n = fx.write(self.data_fd, ptr[sent..avail]);
            if (n <= 0) return false;
            sent += @intCast(n);
        }
        c.br_ssl_engine_sendrec_ack(&self.client_ctx.eng, sent);
        return true;
    }

    fn fillRecvrec(self: *TlsConnection) bool {
        var avail: usize = 0;
        const ptr = c.br_ssl_engine_recvrec_buf(&self.client_ctx.eng, &avail);
        if (avail == 0) return true;

        // If we have buffered data from a previous over-read, use it first
        if (self.net_buf_pos < self.net_buf_len) {
            const buffered = self.net_buf_len - self.net_buf_pos;
            const to_copy = @min(buffered, avail);
            @memcpy(ptr[0..to_copy], self.net_buf[self.net_buf_pos..][0..to_copy]);
            self.net_buf_pos += to_copy;
            c.br_ssl_engine_recvrec_ack(&self.client_ctx.eng, to_copy);
            return true;
        }

        // Read fresh data — always read into full net_buf to handle kernel
        // returning more bytes than the slice length (Fornax IPC read quirk)
        const n = fx.read(self.data_fd, &self.net_buf);
        if (n <= 0) return false;

        const nbytes: usize = @intCast(n);
        const to_copy = @min(nbytes, avail);
        @memcpy(ptr[0..to_copy], self.net_buf[0..to_copy]);
        c.br_ssl_engine_recvrec_ack(&self.client_ctx.eng, to_copy);

        // Buffer any excess for next call
        if (nbytes > to_copy) {
            self.net_buf_pos = to_copy;
            self.net_buf_len = nbytes;
        } else {
            self.net_buf_pos = 0;
            self.net_buf_len = 0;
        }
        return true;
    }

    // ── Adapters for http.zig IoFns ─────────────────────────────────

    pub fn httpReadAdapter(ctx: *anyopaque, buf: []u8) isize {
        const self: *TlsConnection = @ptrCast(@alignCast(ctx));
        return self.read(buf);
    }

    pub fn httpWriteAdapter(ctx: *anyopaque, data: []const u8) isize {
        const self: *TlsConnection = @ptrCast(@alignCast(ctx));
        return self.write(data);
    }

    pub fn ioFns(self: *TlsConnection) IoFns {
        return .{
            .read = httpReadAdapter,
            .write = httpWriteAdapter,
            .ctx = @ptrCast(self),
        };
    }
};

/// Re-export IoFns from http for type compatibility.
pub const IoFns = fx.http.IoFns;

/// Re-export BearSSL trust anchor type for callers.
pub const TrustAnchor = c.br_x509_trust_anchor;

// ── Trust anchor loading from PEM ────────────────────────────────────

/// DER certificate callback context for PEM decoding.
const PemDecodeState = struct {
    // Output: where decoded DER bytes go
    der_buf: []u8,
    der_len: usize,
    // Whether we're inside a CERTIFICATE object
    in_cert: bool,
    // Error flag
    err: bool,
};

fn pemDestCallback(dest_ctx: ?*anyopaque, src: ?*const anyopaque, len: usize) callconv(.c) void {
    const state: *PemDecodeState = @ptrCast(@alignCast(dest_ctx orelse return));
    const src_ptr: [*]const u8 = @ptrCast(src orelse return);
    if (state.err) return;
    if (state.der_len + len > state.der_buf.len) {
        state.err = true;
        return;
    }
    @memcpy(state.der_buf[state.der_len..][0..len], src_ptr[0..len]);
    state.der_len += len;
}

/// Load trust anchors from a PEM-encoded CA bundle.
///
/// pem_data:  PEM file contents (read from /etc/ssl/certs/ca-certificates.crt)
/// der_buf:   scratch for DER decoding (~32 KB should be enough per cert)
/// ta_buf:    storage for trust anchor DN + key data (grows as anchors are added)
/// anchors:   output array of trust anchor structs
///
/// Returns the number of anchors loaded, or null on failure.
pub fn loadTrustAnchors(
    pem_data: []const u8,
    der_buf: []u8,
    ta_buf: []u8,
    anchors: []c.br_x509_trust_anchor,
) ?usize {
    var pem_ctx: c.br_pem_decoder_context = undefined;
    var x509_ctx: c.br_x509_decoder_context = undefined;

    var state = PemDecodeState{
        .der_buf = der_buf,
        .der_len = 0,
        .in_cert = false,
        .err = false,
    };

    var ta_pos: usize = 0; // position in ta_buf
    var anchor_count: usize = 0;

    c.br_pem_decoder_init(&pem_ctx);

    var offset: usize = 0;
    while (offset < pem_data.len) {
        const pushed = c.br_pem_decoder_push(&pem_ctx, pem_data.ptr + offset, pem_data.len - offset);
        offset += pushed;

        const event = c.br_pem_decoder_event(&pem_ctx);
        switch (event) {
            0 => {
                // No event, but push returned 0 — we're stuck
                if (pushed == 0) break;
            },
            1 => { // BR_PEM_BEGIN_OBJ
                const name = c.br_pem_decoder_name(&pem_ctx);
                // Check if this is a certificate
                state.in_cert = cStrEql(name, "CERTIFICATE");
                state.der_len = 0;
                state.err = false;
                if (state.in_cert) {
                    c.br_pem_decoder_setdest(&pem_ctx, pemDestCallback, @ptrCast(&state));
                } else {
                    c.br_pem_decoder_setdest(&pem_ctx, null, null);
                }
            },
            2 => { // BR_PEM_END_OBJ
                if (state.in_cert and !state.err and state.der_len > 0) {
                    // Decode the DER certificate
                    if (decodeTrustAnchor(
                        &x509_ctx,
                        der_buf[0..state.der_len],
                        ta_buf[ta_pos..],
                        anchors[anchor_count..],
                    )) |used| {
                        ta_pos += used;
                        anchor_count += 1;
                    }
                }
                state.in_cert = false;
                if (anchor_count >= anchors.len) break;
            },
            3 => { // BR_PEM_ERROR
                // Skip invalid PEM objects, continue
                state.in_cert = false;
            },
            else => {},
        }
    }

    if (anchor_count == 0) return null;
    return anchor_count;
}

/// Decode a single DER certificate into a trust anchor.
/// Returns bytes used in ta_buf, or null on failure.
fn decodeTrustAnchor(
    x509_ctx: *c.br_x509_decoder_context,
    der_data: []const u8,
    ta_buf: []u8,
    anchors: []c.br_x509_trust_anchor,
) ?usize {
    if (anchors.len == 0) return null;

    c.br_x509_decoder_init(x509_ctx, null, null);
    c.br_x509_decoder_push(x509_ctx, der_data.ptr, der_data.len);
    const err = c.br_x509_decoder_last_error(x509_ctx);
    if (err != 0) return null;

    const pkey_ptr = c.br_x509_decoder_get_pkey(x509_ctx) orelse return null;
    const pkey = pkey_ptr.*;
    const is_ca = c.br_x509_decoder_isCA(x509_ctx);

    // Copy the key data into ta_buf
    var used: usize = 0;

    // Store the subject DN (from the decoder's internal hash_dn field)
    // BearSSL x509 decoder doesn't expose raw DN directly.
    // We need to re-parse the DER to get the subject DN offset/length.
    const dn_info = findSubjectDN(der_data) orelse return null;

    // Copy DN into ta_buf
    if (used + dn_info.len > ta_buf.len) return null;
    @memcpy(ta_buf[used..][0..dn_info.len], der_data[dn_info.offset..][0..dn_info.len]);
    const dn_offset = used;
    used += dn_info.len;

    // Copy public key data
    var ta: c.br_x509_trust_anchor = undefined;
    ta.dn.data = @ptrCast(ta_buf.ptr + dn_offset);
    ta.dn.len = dn_info.len;
    ta.flags = if (is_ca != 0) 1 else 0; // BR_X509_TA_CA = 1

    if (pkey.key_type == 1) { // BR_KEYTYPE_RSA
        const rsa = pkey.key.rsa;
        // Copy n
        if (used + rsa.nlen > ta_buf.len) return null;
        @memcpy(ta_buf[used..][0..rsa.nlen], @as([*]const u8, @ptrCast(rsa.n))[0..rsa.nlen]);
        ta.pkey.key.rsa.n = @ptrCast(ta_buf.ptr + used);
        ta.pkey.key.rsa.nlen = rsa.nlen;
        used += rsa.nlen;
        // Copy e
        if (used + rsa.elen > ta_buf.len) return null;
        @memcpy(ta_buf[used..][0..rsa.elen], @as([*]const u8, @ptrCast(rsa.e))[0..rsa.elen]);
        ta.pkey.key.rsa.e = @ptrCast(ta_buf.ptr + used);
        ta.pkey.key.rsa.elen = rsa.elen;
        used += rsa.elen;
        ta.pkey.key_type = 1;
    } else if (pkey.key_type == 2) { // BR_KEYTYPE_EC
        const ec = pkey.key.ec;
        // Copy q
        if (used + ec.qlen > ta_buf.len) return null;
        @memcpy(ta_buf[used..][0..ec.qlen], @as([*]const u8, @ptrCast(ec.q))[0..ec.qlen]);
        ta.pkey.key.ec.q = @ptrCast(ta_buf.ptr + used);
        ta.pkey.key.ec.qlen = ec.qlen;
        ta.pkey.key.ec.curve = ec.curve;
        used += ec.qlen;
        ta.pkey.key_type = 2;
    } else {
        return null;
    }

    anchors[0] = ta;
    return used;
}

/// ASN.1/DER parsing: find the Subject DN within a certificate.
const DnInfo = struct {
    offset: usize,
    len: usize,
};

fn findSubjectDN(der: []const u8) ?DnInfo {
    // X.509 certificate structure:
    // SEQUENCE (certificate)
    //   SEQUENCE (tbsCertificate)
    //     [0] version (optional)
    //     INTEGER (serialNumber)
    //     SEQUENCE (signature)
    //     SEQUENCE (issuer)
    //     SEQUENCE (validity)
    //     SEQUENCE (subject)  <-- we want this

    var pos: usize = 0;

    // Outer SEQUENCE
    const outer = parseTag(der, pos) orelse return null;
    if (outer.tag != 0x30) return null;
    pos = outer.content_start;

    // TBSCertificate SEQUENCE
    const tbs = parseTag(der, pos) orelse return null;
    if (tbs.tag != 0x30) return null;
    pos = tbs.content_start;

    // [0] version (optional, context-specific constructed)
    if (pos < der.len and der[pos] == 0xA0) {
        const ver = parseTag(der, pos) orelse return null;
        pos = ver.content_start + ver.content_len;
    }

    // serialNumber INTEGER
    const serial = parseTag(der, pos) orelse return null;
    pos = serial.content_start + serial.content_len;

    // signature SEQUENCE
    const sig = parseTag(der, pos) orelse return null;
    pos = sig.content_start + sig.content_len;

    // issuer SEQUENCE
    const issuer = parseTag(der, pos) orelse return null;
    pos = issuer.content_start + issuer.content_len;

    // validity SEQUENCE
    const validity = parseTag(der, pos) orelse return null;
    pos = validity.content_start + validity.content_len;

    // subject SEQUENCE — this is what we want (including tag + length)
    const subject = parseTag(der, pos) orelse return null;
    const subject_total = (subject.content_start - pos) + subject.content_len;
    return DnInfo{
        .offset = pos,
        .len = subject_total,
    };
}

const TagInfo = struct {
    tag: u8,
    content_start: usize,
    content_len: usize,
};

fn parseTag(der: []const u8, pos: usize) ?TagInfo {
    if (pos >= der.len) return null;
    const tag = der[pos];
    var p = pos + 1;
    if (p >= der.len) return null;

    var length: usize = 0;
    if (der[p] & 0x80 == 0) {
        // Short form
        length = der[p];
        p += 1;
    } else {
        // Long form
        const num_bytes = der[p] & 0x7F;
        p += 1;
        if (num_bytes > 4) return null; // too long
        var i: usize = 0;
        while (i < num_bytes) : (i += 1) {
            if (p >= der.len) return null;
            length = (length << 8) | der[p];
            p += 1;
        }
    }

    return TagInfo{
        .tag = tag,
        .content_start = p,
        .content_len = length,
    };
}

fn cStrEql(cs: [*c]const u8, s: []const u8) bool {
    const ptr = cs orelse return false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (ptr[i] == 0) return false;
        if (ptr[i] != s[i]) return false;
    }
    return ptr[i] == 0;
}
