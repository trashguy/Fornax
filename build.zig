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

    const init_bin = b.addExecutable(.{
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
    init_bin.image_base = user_image_base;

    const fsh_bin = b.addExecutable(.{
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
    fsh_bin.image_base = user_image_base;

    const hello_bin = b.addExecutable(.{
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
    hello_bin.image_base = user_image_base;

    const tcptest_bin = b.addExecutable(.{
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
    tcptest_bin.image_base = user_image_base;

    const dnstest_bin = b.addExecutable(.{
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
    dnstest_bin.image_base = user_image_base;

    const ping_bin = b.addExecutable(.{
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
    ping_bin.image_base = user_image_base;

    const echo_bin = b.addExecutable(.{
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
    echo_bin.image_base = user_image_base;

    const cat_bin = b.addExecutable(.{
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
    cat_bin.image_base = user_image_base;

    const ls_bin = b.addExecutable(.{
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
    ls_bin.image_base = user_image_base;

    const rm_bin = b.addExecutable(.{
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
    rm_bin.image_base = user_image_base;

    const mkdir_bin = b.addExecutable(.{
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
    mkdir_bin.image_base = user_image_base;

    const wc_bin = b.addExecutable(.{
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
    wc_bin.image_base = user_image_base;

    const lsblk_bin = b.addExecutable(.{
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
    lsblk_bin.image_base = user_image_base;

    const df_bin = b.addExecutable(.{
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
    df_bin.image_base = user_image_base;

    const dmesg_bin = b.addExecutable(.{
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
    dmesg_bin.image_base = user_image_base;

    const head_bin = b.addExecutable(.{
        .name = "head",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/head/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    head_bin.image_base = user_image_base;

    const tail_bin = b.addExecutable(.{
        .name = "tail",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/tail/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    tail_bin.image_base = user_image_base;

    const tree_bin = b.addExecutable(.{
        .name = "tree",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/tree/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    tree_bin.image_base = user_image_base;

    const free_bin = b.addExecutable(.{
        .name = "free",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/free/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    free_bin.image_base = user_image_base;

    const shutdown_bin = b.addExecutable(.{
        .name = "shutdown",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/shutdown/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    shutdown_bin.image_base = user_image_base;

    const reboot_bin = b.addExecutable(.{
        .name = "reboot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/reboot/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    reboot_bin.image_base = user_image_base;

    const ps_bin = b.addExecutable(.{
        .name = "ps",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/ps/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    ps_bin.image_base = user_image_base;

    const kill_bin = b.addExecutable(.{
        .name = "kill",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/kill/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    kill_bin.image_base = user_image_base;

    const du_bin = b.addExecutable(.{
        .name = "du",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/du/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    du_bin.image_base = user_image_base;

    const top_bin = b.addExecutable(.{
        .name = "top",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/top/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    top_bin.image_base = user_image_base;

    const cp_bin = b.addExecutable(.{
        .name = "cp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/cp/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    cp_bin.image_base = user_image_base;

    const mv_bin = b.addExecutable(.{
        .name = "mv",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/mv/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    mv_bin.image_base = user_image_base;

const touch_bin = b.addExecutable(.{
        .name = "touch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/touch/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    touch_bin.image_base = user_image_base;

    const truncate_bin = b.addExecutable(.{
        .name = "truncate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/truncate/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    truncate_bin.image_base = user_image_base;

    const dd_bin = b.addExecutable(.{
        .name = "dd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/dd/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    dd_bin.image_base = user_image_base;

    const grep_bin = b.addExecutable(.{
        .name = "grep",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/grep/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    grep_bin.image_base = user_image_base;

    const sed_bin = b.addExecutable(.{
        .name = "sed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/sed/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    sed_bin.image_base = user_image_base;

    const awk_bin = b.addExecutable(.{
        .name = "awk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/awk/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    awk_bin.image_base = user_image_base;

    const less_bin = b.addExecutable(.{
        .name = "less",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/less/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    less_bin.image_base = user_image_base;

    const fe_bin = b.addExecutable(.{
        .name = "fe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/fe/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    fe_bin.image_base = user_image_base;

    const fxfs_bin = b.addExecutable(.{
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
    fxfs_bin.image_base = user_image_base;

    const partfs_bin = b.addExecutable(.{
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
    partfs_bin.image_base = user_image_base;

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

    const x86_bin = b.addExecutable(.{
        .name = "BOOTX64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = x86_64_target,
            .optimize = optimize,
        }),
    });

    x86_bin.root_module.addOptions("build_options", build_options);
    x86_bin.addAssemblyFile(b.path("src/arch/x86_64/entry.S"));

    const x86_install = b.addInstallArtifact(x86_bin, .{
        .dest_dir = .{ .override = .{ .custom = "esp/EFI/BOOT" } },
        .dest_sub_path = "BOOTX64.EFI",
    });

    // ── Initrd: boot-critical servers only ───────────────────────────
    const x86_initrd = addInitrdStep(b, mkinitrd, "esp/EFI/BOOT", &.{ init_bin, partfs_bin, fxfs_bin });
    x86_initrd.step.dependOn(&x86_install.step); // ensure ESP dir exists

    // ── Rootfs: install disk-bound programs to zig-out/rootfs/bin/ ──
    const disk_programs: []const *std.Build.Step.Compile = &.{
        fsh_bin,  echo_bin,    cat_bin,  ls_bin,
        rm_bin,   mkdir_bin,   wc_bin,   lsblk_bin,
        df_bin,   dmesg_bin,   head_bin, tail_bin, tree_bin, free_bin, ping_bin, hello_bin,
        tcptest_bin, dnstest_bin, shutdown_bin, reboot_bin,
        ps_bin, kill_bin, du_bin, top_bin,
        cp_bin, mv_bin, touch_bin, truncate_bin, dd_bin,
        grep_bin, sed_bin, awk_bin, less_bin,
        fe_bin,
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

    const aarch64_bin = b.addExecutable(.{
        .name = "BOOTAA64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = aarch64_target,
            .optimize = optimize,
        }),
    });

    aarch64_bin.root_module.addOptions("build_options", build_options);

    const aarch64_install = b.addInstallArtifact(aarch64_bin, .{
        .dest_dir = .{ .override = .{ .custom = "esp-aarch64/EFI/BOOT" } },
        .dest_sub_path = "BOOTAA64.EFI",
    });

    // aarch64 initrd: empty for now (no aarch64 userspace yet)
    const aarch64_initrd = addInitrdStep(b, mkinitrd, "esp-aarch64/EFI/BOOT", &.{});
    aarch64_initrd.step.dependOn(&aarch64_install.step);

    // ── riscv64 freestanding kernel ─────────────────────────────────
    // RISC-V boots via OpenSBI + direct kernel load (not UEFI PE/COFF,
    // which Zig's linker doesn't support for riscv64).
    const riscv64_freestanding = b.resolveTargetQuery(.{
        .cpu_arch = .riscv64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const rv_fornax_module = b.createModule(.{
        .root_source_file = b.path("lib/root.zig"),
        .target = riscv64_freestanding,
        .optimize = user_optimize,
    });

    const riscv64_bin = b.addExecutable(.{
        .name = "fornax-riscv64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = riscv64_freestanding,
            .optimize = optimize,
            .code_model = .medany, // PC-relative addressing for high addresses (0x80200000)
        }),
    });

    riscv64_bin.root_module.addOptions("build_options", build_options);
    riscv64_bin.addAssemblyFile(b.path("src/arch/riscv64/entry.S"));
    riscv64_bin.entry = .disabled; // _start is in entry.S
    riscv64_bin.setLinkerScript(b.path("src/arch/riscv64/kernel.ld"));

    const riscv64_install = b.addInstallArtifact(riscv64_bin, .{
        .dest_dir = .{ .override = .{ .custom = "esp-riscv64" } },
    });

    // riscv64 userspace programs
    const rv_user_programs = .{
        .{ "init", "cmd/init/main.zig" },
        .{ "fsh", "cmd/fsh/main.zig" },
        .{ "hello", "cmd/hello/main.zig" },
        .{ "echo", "cmd/echo/main.zig" },
        .{ "cat", "cmd/cat/main.zig" },
        .{ "ls", "cmd/ls/main.zig" },
        .{ "rm", "cmd/rm/main.zig" },
        .{ "mkdir", "cmd/mkdir/main.zig" },
        .{ "wc", "cmd/wc/main.zig" },
        .{ "lsblk", "cmd/lsblk/main.zig" },
        .{ "df", "cmd/df/main.zig" },
        .{ "dmesg", "cmd/dmesg/main.zig" },
        .{ "head", "cmd/head/main.zig" },
        .{ "tail", "cmd/tail/main.zig" },
        .{ "tree", "cmd/tree/main.zig" },
        .{ "free", "cmd/free/main.zig" },
        .{ "ping", "cmd/ping/main.zig" },
        .{ "tcptest", "cmd/tcptest/main.zig" },
        .{ "dnstest", "cmd/dnstest/main.zig" },
        .{ "shutdown", "cmd/shutdown/main.zig" },
        .{ "reboot", "cmd/reboot/main.zig" },
        .{ "ps", "cmd/ps/main.zig" },
        .{ "kill", "cmd/kill/main.zig" },
        .{ "du", "cmd/du/main.zig" },
        .{ "top", "cmd/top/main.zig" },
        .{ "cp", "cmd/cp/main.zig" },
        .{ "mv", "cmd/mv/main.zig" },
        .{ "touch", "cmd/touch/main.zig" },
        .{ "truncate", "cmd/truncate/main.zig" },
        .{ "dd", "cmd/dd/main.zig" },
        .{ "grep", "cmd/grep/main.zig" },
        .{ "sed", "cmd/sed/main.zig" },
        .{ "awk", "cmd/awk/main.zig" },
        .{ "less", "cmd/less/main.zig" },
        .{ "fe", "cmd/fe/main.zig" },
        .{ "fxfs", "srv/fxfs/main.zig" },
        .{ "partfs", "srv/partfs/main.zig" },
    };

    // Build riscv64 initrd programs (init, partfs, fxfs)
    var rv_initrd_bins: [3]*std.Build.Step.Compile = undefined;
    var rv_disk_bin_buf: [48]*std.Build.Step.Compile = undefined;
    var rv_disk_bin_count: usize = 0;

    inline for (rv_user_programs) |prog_info| {
        const rv_prog = b.addExecutable(.{
            .name = prog_info[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(prog_info[1]),
                .target = riscv64_freestanding,
                .optimize = user_optimize,
                .imports = &.{
                    .{ .name = "fornax", .module = rv_fornax_module },
                },
            }),
        });
        rv_prog.image_base = user_image_base;

        const name: []const u8 = prog_info[0];
        if (std.mem.eql(u8, name, "init")) {
            rv_initrd_bins[0] = rv_prog;
        } else if (std.mem.eql(u8, name, "partfs")) {
            rv_initrd_bins[1] = rv_prog;
        } else if (std.mem.eql(u8, name, "fxfs")) {
            rv_initrd_bins[2] = rv_prog;
        } else {
            rv_disk_bin_buf[rv_disk_bin_count] = rv_prog;
            rv_disk_bin_count += 1;
        }
    }

    const rv_initrd = addInitrdStep(b, mkinitrd, "esp-riscv64", &rv_initrd_bins);
    rv_initrd.step.dependOn(&riscv64_install.step);

    for (rv_disk_bin_buf[0..rv_disk_bin_count]) |prog| {
        const install = b.addInstallArtifact(prog, .{
            .dest_dir = .{ .override = .{ .custom = "rootfs-riscv64/bin" } },
        });
        rv_initrd.step.dependOn(&install.step);
    }

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

    const riscv64_step = b.step("riscv64", "Build riscv64 freestanding kernel");
    riscv64_step.dependOn(&riscv64_install.step);
    riscv64_step.dependOn(&rv_initrd.step);

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
