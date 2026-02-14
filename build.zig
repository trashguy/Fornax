const std = @import("std");
const Target = std.Target;

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const cluster = b.option(bool, "cluster", "Enable clustering support (gossip discovery, remote namespaces, scheduler)") orelse false;

    // ── Build options (passed to kernel as @import("build_options")) ──
    const build_options = b.addOptions();
    build_options.addOption(bool, "cluster", cluster);

    // ── Host tool: mkinitrd ───────────────────────────────────────────
    const mkinitrd = b.addExecutable(.{
        .name = "mkinitrd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mkinitrd.zig"),
            .target = b.graph.host,
        }),
    });

    // ── Userspace freestanding x86_64 target ─────────────────────────
    // No float feature restrictions — userspace runs with full CPU features.
    // The kernel disables SSE/AVX to avoid managing FPU state in ring 0,
    // but userspace programs run in ring 3 and can use hardware floats.
    const x86_64_freestanding = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    // ── Userspace programs ───────────────────────────────────────────
    const fornax_module = b.createModule(.{
        .root_source_file = b.path("lib/fornax.zig"),
        .target = x86_64_freestanding,
        .optimize = optimize,
    });

    const init_exe = b.addExecutable(.{
        .name = "init",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/init/main.zig"),
            .target = x86_64_freestanding,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });

    const ramfs_exe = b.addExecutable(.{
        .name = "ramfs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("srv/ramfs/main.zig"),
            .target = x86_64_freestanding,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });

    // ── x86_64 UEFI kernel ──────────────────────────────────────────
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

    x86_exe.root_module.addOptions("build_options", build_options);
    x86_exe.addAssemblyFile(b.path("src/arch/x86_64/entry.S"));

    const x86_install = b.addInstallArtifact(x86_exe, .{
        .dest_dir = .{ .override = .{ .custom = "esp/EFI/BOOT" } },
        .dest_sub_path = "BOOTX64.EFI",
    });

    // ── Initrd: pack userspace programs into INITRD image ────────────
    const x86_initrd = addInitrdStep(b, mkinitrd, "esp/EFI/BOOT", &.{ ramfs_exe, init_exe });
    x86_initrd.step.dependOn(&x86_install.step); // ensure ESP dir exists

    // ── aarch64 UEFI kernel ─────────────────────────────────────────
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

    // aarch64 initrd: empty for now (no aarch64 userspace yet)
    const aarch64_initrd = addInitrdStep(b, mkinitrd, "esp-aarch64/EFI/BOOT", &.{});
    aarch64_initrd.step.dependOn(&aarch64_install.step);

    // ── Named steps ─────────────────────────────────────────────────
    const x86_step = b.step("x86_64", "Build x86_64 UEFI kernel");
    x86_step.dependOn(&x86_install.step);
    x86_step.dependOn(&x86_initrd.step);

    const aarch64_step = b.step("aarch64", "Build aarch64 UEFI kernel");
    aarch64_step.dependOn(&aarch64_install.step);
    aarch64_step.dependOn(&aarch64_initrd.step);

    // Default: build both
    b.getInstallStep().dependOn(&x86_install.step);
    b.getInstallStep().dependOn(&x86_initrd.step);
    b.getInstallStep().dependOn(&aarch64_install.step);
    b.getInstallStep().dependOn(&aarch64_initrd.step);
}

/// Add a build step that packs userspace programs into an INITRD image.
fn addInitrdStep(
    b: *std.Build,
    mkinitrd: *std.Build.Step.Compile,
    esp_subdir: []const u8,
    programs: []const *std.Build.Step.Compile,
) *std.Build.Step.InstallFile {
    const run = b.addRunArtifact(mkinitrd);
    const output = run.addOutputFileArg("INITRD");

    // Add each compiled program as an input to mkinitrd
    for (programs) |prog| {
        run.addFileArg(prog.getEmittedBin());
    }

    // Also add any files from sysroot/ (for manual additions)
    if (std.fs.cwd().openDir("sysroot", .{ .iterate = true })) |dir_val| {
        var dir = dir_val;
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .file) {
                run.addFileArg(b.path(b.fmt("sysroot/{s}", .{entry.name})));
            }
        }
        dir.close();
    } else |_| {}

    return b.addInstallFileWithDir(output, .{ .custom = esp_subdir }, "INITRD");
}
