const std = @import("std");
const Target = std.Target;

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const cluster = b.option(bool, "cluster", "Enable clustering support (gossip discovery, remote namespaces, scheduler)") orelse false;

    // Userspace always uses ReleaseSafe: keeps bounds/overflow checks while
    // producing small stack frames. Debug mode overflows the 256 KB user stack.
    const user_optimize: std.builtin.OptimizeMode = .ReleaseSafe;

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

    // ── Host tool: mkfxfs ──────────────────────────────────────────
    const mkfxfs = b.addExecutable(.{
        .name = "mkfxfs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mkfxfs.zig"),
            .target = b.graph.host,
        }),
    });

    // ── Host tool: mkgpt ───────────────────────────────────────────
    const mkgpt = b.addExecutable(.{
        .name = "mkgpt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mkgpt.zig"),
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
        .root_source_file = b.path("lib/root.zig"),
        .target = x86_64_freestanding,
        .optimize = user_optimize,
    });

    // All userspace programs are linked at 1 GB (0x40000000) to avoid
    // overlapping the kernel's identity-mapped code region (PDPT[0], <1 GB).
    // User code lands in PDPT[1]'s separately deep-copied PD table,
    // so mapPage() can't corrupt kernel code entries.
    const user_image_base: u64 = 0x40000000;

    const init_exe = b.addExecutable(.{
        .name = "init",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/init/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    init_exe.image_base = user_image_base;

    const fsh_exe = b.addExecutable(.{
        .name = "fsh",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/fsh/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    fsh_exe.image_base = user_image_base;

    const hello_exe = b.addExecutable(.{
        .name = "hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/hello/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    hello_exe.image_base = user_image_base;

    const tcptest_exe = b.addExecutable(.{
        .name = "tcptest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/tcptest/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    tcptest_exe.image_base = user_image_base;

    const dnstest_exe = b.addExecutable(.{
        .name = "dnstest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/dnstest/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    dnstest_exe.image_base = user_image_base;

    const ping_exe = b.addExecutable(.{
        .name = "ping",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/ping/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    ping_exe.image_base = user_image_base;

    const echo_exe = b.addExecutable(.{
        .name = "echo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/echo/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    echo_exe.image_base = user_image_base;

    const cat_exe = b.addExecutable(.{
        .name = "cat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/cat/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    cat_exe.image_base = user_image_base;

    const ls_exe = b.addExecutable(.{
        .name = "ls",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/ls/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    ls_exe.image_base = user_image_base;

    const rm_exe = b.addExecutable(.{
        .name = "rm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/rm/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    rm_exe.image_base = user_image_base;

    const mkdir_exe = b.addExecutable(.{
        .name = "mkdir",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/mkdir/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    mkdir_exe.image_base = user_image_base;

    const wc_exe = b.addExecutable(.{
        .name = "wc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/wc/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    wc_exe.image_base = user_image_base;

    const lsblk_exe = b.addExecutable(.{
        .name = "lsblk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/lsblk/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    lsblk_exe.image_base = user_image_base;

    const df_exe = b.addExecutable(.{
        .name = "df",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/df/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    df_exe.image_base = user_image_base;

    const dmesg_exe = b.addExecutable(.{
        .name = "dmesg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/dmesg/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    dmesg_exe.image_base = user_image_base;

    const fxfs_exe = b.addExecutable(.{
        .name = "fxfs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("srv/fxfs/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    fxfs_exe.image_base = user_image_base;

    const partfs_exe = b.addExecutable(.{
        .name = "partfs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("srv/partfs/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    partfs_exe.image_base = user_image_base;

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

    // ── Initrd: boot-critical servers only ───────────────────────────
    const x86_initrd = addInitrdStep(b, mkinitrd, "esp/EFI/BOOT", &.{ init_exe, partfs_exe, fxfs_exe });
    x86_initrd.step.dependOn(&x86_install.step); // ensure ESP dir exists

    // ── Rootfs: install disk-bound programs to zig-out/rootfs/bin/ ──
    const disk_programs: []const *std.Build.Step.Compile = &.{
        fsh_exe,  echo_exe,    cat_exe,  ls_exe,
        rm_exe,   mkdir_exe,   wc_exe,   lsblk_exe,
        df_exe,   dmesg_exe,   ping_exe, hello_exe,
        tcptest_exe, dnstest_exe,
    };
    for (disk_programs) |prog| {
        const install = b.addInstallArtifact(prog, .{
            .dest_dir = .{ .override = .{ .custom = "rootfs/bin" } },
        });
        x86_initrd.step.dependOn(&install.step);
    }

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
    const mkfxfs_install = b.addInstallArtifact(mkfxfs, .{});
    const mkfxfs_step = b.step("mkfxfs", "Build mkfxfs disk formatter");
    mkfxfs_step.dependOn(&mkfxfs_install.step);

    const mkgpt_install = b.addInstallArtifact(mkgpt, .{});
    const mkgpt_step = b.step("mkgpt", "Build mkgpt partition tool");
    mkgpt_step.dependOn(&mkgpt_install.step);

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
