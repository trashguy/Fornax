const std = @import("std");
const ipc = @import("ipc");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

// ── IpcMessage.init ───────────────────────────────────────────────

test "init: tag is set correctly for R_OK" {
    const msg = ipc.IpcMessage.init(ipc.R_OK);
    try expectEqual(@as(u32, 0x80), msg.tag);
}

test "init: tag is set correctly for R_ERROR" {
    const msg = ipc.IpcMessage.init(ipc.R_ERROR);
    try expectEqual(@as(u32, 0x81), msg.tag);
}

test "init: data_len is zero" {
    const msg = ipc.IpcMessage.init(ipc.R_OK);
    try expectEqual(@as(u32, 0), msg.data_len);
}

test "init: data is zeroed" {
    const msg = ipc.IpcMessage.init(ipc.R_OK);
    try expectEqual(@as(u8, 0), msg.data[0]);
    try expectEqual(@as(u8, 0), msg.data[4095]);
}

// ── Assignment through pointer (fxfs workerLoop pattern) ──────────

test "pointer assignment: tag persists through resp.* = init()" {
    var wreply: ipc.IpcMessage = undefined;
    const resp: *ipc.IpcMessage = &wreply;
    resp.* = ipc.IpcMessage.init(ipc.R_OK);
    try expectEqual(@as(u32, 0x80), resp.tag);
    try expectEqual(@as(u32, 0), resp.data_len);
}

test "pointer assignment: tag persists after data_len write" {
    var wreply: ipc.IpcMessage = undefined;
    const resp: *ipc.IpcMessage = &wreply;
    resp.* = ipc.IpcMessage.init(ipc.R_OK);
    resp.data_len = 0x1000;
    try expectEqual(@as(u32, 0x80), resp.tag);
    try expectEqual(@as(u32, 0x1000), resp.data_len);
}

test "pointer assignment: tag persists after data write" {
    var wreply: ipc.IpcMessage = undefined;
    const resp: *ipc.IpcMessage = &wreply;
    resp.* = ipc.IpcMessage.init(ipc.R_OK);
    // Simulate readFileData writing into resp.data
    @memcpy(resp.data[0..4], &[_]u8{ 0x7F, 'E', 'L', 'F' });
    resp.data_len = 4;
    try expectEqual(@as(u32, 0x80), resp.tag);
    try expectEqual(@as(u32, 4), resp.data_len);
    try expectEqual(@as(u8, 0x7F), resp.data[0]);
}

// ── Simulated workerLoop pattern (wmsg + wreply on stack) ─────────

test "workerLoop pattern: adjacent structs on stack" {
    // Simulate the exact fxfs workerLoop stack layout
    var wmsg: ipc.IpcMessage = undefined;
    var wreply: ipc.IpcMessage = undefined;

    // Simulate ipc_recv delivery into wmsg
    wmsg.tag = ipc.T_READ;
    wmsg.data_len = 12;
    @memset(wmsg.data[0..12], 0);

    // Simulate handleRead
    const resp: *ipc.IpcMessage = &wreply;
    resp.* = ipc.IpcMessage.init(ipc.R_OK);
    @memcpy(resp.data[0..4], &[_]u8{ 0x7F, 'E', 'L', 'F' });
    resp.data_len = 0x1000;

    // Verify wreply is correct (what sysIpcReply would read)
    try expectEqual(@as(u32, 0x80), wreply.tag);
    try expectEqual(@as(u32, 0x1000), wreply.data_len);
    try expectEqual(@as(u8, 0x7F), wreply.data[0]);

    // Verify wmsg wasn't corrupted
    try expectEqual(@as(u32, ipc.T_READ), wmsg.tag);
}

test "workerLoop pattern: multiple iterations preserve tag" {
    var wmsg: ipc.IpcMessage = undefined;
    var wreply: ipc.IpcMessage = undefined;

    // Iteration 1: T_READ
    wmsg.tag = ipc.T_READ;
    wmsg.data_len = 12;
    wreply = ipc.IpcMessage.init(ipc.R_OK);
    @memcpy(wreply.data[0..4], &[_]u8{ 0x7F, 'E', 'L', 'F' });
    wreply.data_len = 0x1000;
    try expectEqual(@as(u32, 0x80), wreply.tag);

    // Iteration 2: T_CLOSE
    wmsg.tag = ipc.T_CLOSE;
    wmsg.data_len = 4;
    wreply = ipc.IpcMessage.init(ipc.R_OK);
    wreply.data_len = 0;
    try expectEqual(@as(u32, 0x80), wreply.tag);
    try expectEqual(@as(u32, 0), wreply.data_len);

    // Iteration 3: T_READ again
    wmsg.tag = ipc.T_READ;
    wmsg.data_len = 12;
    wreply = ipc.IpcMessage.init(ipc.R_OK);
    wreply.data_len = 0x1000;
    try expectEqual(@as(u32, 0x80), wreply.tag);
}

// ── Struct layout verification ────────────────────────────────────

test "extern struct layout: tag at offset 0, data_len at offset 4" {
    var msg = ipc.IpcMessage.init(ipc.R_OK);
    const base: [*]const u8 = @ptrCast(&msg);

    // tag (u32 LE) at offset 0
    try expectEqual(@as(u8, 0x80), base[0]);
    try expectEqual(@as(u8, 0x00), base[1]);
    try expectEqual(@as(u8, 0x00), base[2]);
    try expectEqual(@as(u8, 0x00), base[3]);

    // data_len (u32 LE) at offset 4
    try expectEqual(@as(u8, 0x00), base[4]);
    try expectEqual(@as(u8, 0x00), base[5]);
    try expectEqual(@as(u8, 0x00), base[6]);
    try expectEqual(@as(u8, 0x00), base[7]);
}

test "extern struct size: 4104 bytes" {
    try expectEqual(@as(usize, 4104), @sizeOf(ipc.IpcMessage));
}

test "extern struct field offsets" {
    try expectEqual(@as(usize, 0), @offsetOf(ipc.IpcMessage, "tag"));
    try expectEqual(@as(usize, 4), @offsetOf(ipc.IpcMessage, "data_len"));
    try expectEqual(@as(usize, 8), @offsetOf(ipc.IpcMessage, "data"));
}
