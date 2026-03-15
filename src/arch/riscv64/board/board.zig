/// Board configuration selector for RISC-V 64-bit.
///
/// Selects board-specific constants at comptime based on the -Dboard build option.
/// Defaults to qemu_virt when no board is specified.
const build_options = @import("build_options");

pub const active = switch (build_options.board) {
    .qemu_virt => @import("qemu_virt.zig"),
    .milkv_mars => @import("milkv_mars.zig"),
};
