const std = @import("std");
const Target = std.Target;

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const cluster = b.option(bool, "cluster", "Enable clustering support (gossip discovery, remote namespaces, scheduler)") orelse false;

    // ── Build options (passed to kernel as @import("build_options")) ──
    const build_options = b.addOptions();
    build_options.addOption(bool, "cluster", cluster);

    // ── User-space binaries (freestanding x86_64) ────────────────────
    const user_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_sub = Target.x86.featureSet(&.{
            .x87,
            .sse,
            .sse2,
            .avx,
            .avx2,
        }),
        .cpu_features_add = Target.x86.featureSet(&.{
            .soft_float,
        }),
    });

    const user_hello = b.addExecutable(.{
        .name = "hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/hello.zig"),
            .target = user_target,
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "fornax", .module = b.createModule(.{
                    .root_source_file = b.path("user/fornax.zig"),
                    .target = user_target,
                    .optimize = .ReleaseSmall,
                }) },
            },
        }),
    });
    user_hello.entry = .{ .symbol_name = "_start" };

    // Shared fornax module for user programs
    const fornax_mod = b.createModule(.{
        .root_source_file = b.path("user/fornax.zig"),
        .target = user_target,
        .optimize = .ReleaseSmall,
    });

    const user_console = b.addExecutable(.{
        .name = "console_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/console_server.zig"),
            .target = user_target,
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_mod },
            },
        }),
    });
    user_console.entry = .{ .symbol_name = "_start" };

    const user_oci = b.addExecutable(.{
        .name = "oci_import",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/oci_import.zig"),
            .target = user_target,
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_mod },
            },
        }),
    });
    user_oci.entry = .{ .symbol_name = "_start" };

    // ── x86_64 UEFI target ──────────────────────────────────────────
    const x86_64_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
        .abi = .msvc,
        .cpu_features_sub = Target.x86.featureSet(&.{
            .x87,
            .sse,
            .sse2,
            .avx,
            .avx2,
        }),
        .cpu_features_add = Target.x86.featureSet(&.{
            .soft_float,
        }),
    });

    const x86_exe = b.addExecutable(.{
        .name = "BOOTX64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = x86_64_target,
            .optimize = optimize,
        }),
    });

    // Build options
    x86_exe.root_module.addOptions("build_options", build_options);

    // Embed user binaries into the kernel
    x86_exe.root_module.addAnonymousImport("user_hello_elf", .{
        .root_source_file = user_hello.getEmittedBin(),
    });
    x86_exe.root_module.addAnonymousImport("user_console_elf", .{
        .root_source_file = user_console.getEmittedBin(),
    });
    x86_exe.root_module.addAnonymousImport("user_oci_elf", .{
        .root_source_file = user_oci.getEmittedBin(),
    });

    // Add hand-written assembly entry points (syscall, ISR stubs, resume)
    x86_exe.addAssemblyFile(b.path("src/arch/x86_64/entry.S"));

    const x86_install = b.addInstallArtifact(x86_exe, .{
        .dest_dir = .{ .override = .{ .custom = "esp/EFI/BOOT" } },
        .dest_sub_path = "BOOTX64.EFI",
    });

    // ── aarch64 UEFI target ─────────────────────────────────────────
    const aarch64_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .uefi,
        .abi = .msvc,
    });

    const aarch64_exe = b.addExecutable(.{
        .name = "BOOTAA64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = aarch64_target,
            .optimize = optimize,
        }),
    });

    aarch64_exe.root_module.addOptions("build_options", build_options);

    const aarch64_install = b.addInstallArtifact(aarch64_exe, .{
        .dest_dir = .{ .override = .{ .custom = "esp-aarch64/EFI/BOOT" } },
        .dest_sub_path = "BOOTAA64.EFI",
    });

    // ── Named steps ─────────────────────────────────────────────────
    const x86_step = b.step("x86_64", "Build x86_64 UEFI kernel");
    x86_step.dependOn(&x86_install.step);

    const aarch64_step = b.step("aarch64", "Build aarch64 UEFI kernel");
    aarch64_step.dependOn(&aarch64_install.step);

    // Default: build both
    b.getInstallStep().dependOn(&x86_install.step);
    b.getInstallStep().dependOn(&aarch64_install.step);
}
