/// Error codes matching kernel's negative return values.
pub const Errno = enum(i32) {
    SUCCESS = 0,
    NOSYS = -1,
    NOENT = -2,
    IO = -5,
    BADF = -9,
    NOMEM = -12,
    FAULT = -14,
    INVAL = -22,
    MFILE = -24,
};

/// Return a human-readable name for a syscall return code.
pub fn name(code: i32) []const u8 {
    return switch (@as(Errno, @enumFromInt(code))) {
        .SUCCESS => "SUCCESS",
        .NOSYS => "ENOSYS",
        .NOENT => "ENOENT",
        .IO => "EIO",
        .BADF => "EBADF",
        .NOMEM => "ENOMEM",
        .FAULT => "EFAULT",
        .INVAL => "EINVAL",
        .MFILE => "EMFILE",
    };
}

/// Check if a syscall return value is an error.
pub fn isError(code: i32) bool {
    return code < 0;
}
