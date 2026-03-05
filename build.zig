const std = @import("std");
const Target = std.Target;

/// musl source files needed for basic stdio/stdlib/string functionality.
/// Shared across all architectures' POSIX builds.
const musl_sources: []const []const u8 = &.{
    // -- internal --
    "src/internal/libc.c",
    "src/internal/syscall_ret.c",
    "src/internal/intscan.c",
    "src/internal/floatscan.c",
    "src/internal/shgetc.c",
    // -- errno --
    "src/errno/__errno_location.c",
    "src/errno/strerror.c",
    // -- string --
    "src/string/memcpy.c",
    "src/string/memset.c",
    "src/string/memmove.c",
    "src/string/memchr.c",
    "src/string/memcmp.c",
    "src/string/memrchr.c",
    "src/string/strlen.c",
    "src/string/strnlen.c",
    "src/string/strcmp.c",
    "src/string/strncmp.c",
    "src/string/strcpy.c",
    "src/string/strncpy.c",
    "src/string/stpcpy.c",
    "src/string/stpncpy.c",
    "src/string/strchrnul.c",
    "src/string/strchr.c",
    "src/string/strrchr.c",
    "src/string/strstr.c",
    "src/string/strdup.c",
    "src/string/strndup.c",
    "src/string/strcat.c",
    "src/string/strncat.c",
    "src/string/strspn.c",
    "src/string/strcspn.c",
    "src/string/strtok.c",
    "src/string/strtok_r.c",
    "src/string/strerror_r.c",
    "src/string/bcopy.c",
    "src/string/bzero.c",
    "src/string/strlcpy.c",
    "src/string/strlcat.c",
    "src/string/wcschr.c",
    "src/string/wcslen.c",
    "src/string/wmemchr.c",
    "src/string/wmemcpy.c",
    "src/string/wmemset.c",
    "src/string/wcsncmp.c",
    "src/string/wmemcmp.c",
    // -- stdio --
    "src/stdio/printf.c",
    "src/stdio/fprintf.c",
    "src/stdio/vfprintf.c",
    "src/stdio/snprintf.c",
    "src/stdio/vsnprintf.c",
    "src/stdio/sprintf.c",
    "src/stdio/vsprintf.c",
    "src/stdio/sscanf.c",
    "src/stdio/vsscanf.c",
    "src/stdio/scanf.c",
    "src/stdio/vscanf.c",
    "src/stdio/fscanf.c",
    "src/stdio/vfscanf.c",
    "src/stdio/fwrite.c",
    "src/stdio/fread.c",
    "src/stdio/fopen.c",
    "src/stdio/fclose.c",
    "src/stdio/fflush.c",
    "src/stdio/fseek.c",
    "src/stdio/ftell.c",
    "src/stdio/rewind.c",
    "src/stdio/feof.c",
    "src/stdio/ferror.c",
    "src/stdio/clearerr.c",
    "src/stdio/fileno.c",
    "src/stdio/fputc.c",
    "src/stdio/fputs.c",
    "src/stdio/puts.c",
    "src/stdio/putchar.c",
    "src/stdio/fgetc.c",
    "src/stdio/fgets.c",
    "src/stdio/getc.c",
    "src/stdio/ungetc.c",
    "src/stdio/perror.c",
    "src/stdio/stderr.c",
    "src/stdio/stdout.c",
    "src/stdio/stdin.c",
    "src/stdio/__stdio_write.c",
    "src/stdio/__stdio_read.c",
    "src/stdio/__stdio_seek.c",
    "src/stdio/__stdio_close.c",
    "src/stdio/__stdout_write.c",
    "src/stdio/__towrite.c",
    "src/stdio/__toread.c",
    "src/stdio/__overflow.c",
    "src/stdio/__uflow.c",
    "src/stdio/__fdopen.c",
    "src/stdio/ofl.c",
    "src/stdio/ofl_add.c",
    "src/stdio/__lockfile.c",
    "src/stdio/__fmodeflags.c",
    "src/stdio/__stdio_exit.c",
    // -- stdlib --
    "src/stdlib/abs.c",
    "src/stdlib/atoi.c",
    "src/stdlib/atol.c",
    "src/stdlib/atoll.c",
    "src/stdlib/strtol.c",
    "src/stdlib/strtod.c",
    "src/stdlib/qsort.c",
    "src/stdlib/bsearch.c",
    // -- ctype --
    "src/ctype/__ctype_get_mb_cur_max.c",
    "src/ctype/isalnum.c",
    "src/ctype/isalpha.c",
    "src/ctype/isascii.c",
    "src/ctype/isblank.c",
    "src/ctype/iscntrl.c",
    "src/ctype/isdigit.c",
    "src/ctype/isgraph.c",
    "src/ctype/islower.c",
    "src/ctype/isprint.c",
    "src/ctype/ispunct.c",
    "src/ctype/isspace.c",
    "src/ctype/isupper.c",
    "src/ctype/isxdigit.c",
    "src/ctype/tolower.c",
    "src/ctype/toupper.c",
    "src/ctype/iswalpha.c",
    "src/ctype/iswdigit.c",
    "src/ctype/iswspace.c",
    "src/ctype/iswprint.c",
    "src/ctype/iswcntrl.c",
    "src/ctype/iswupper.c",
    "src/ctype/iswlower.c",
    "src/ctype/iswblank.c",
    "src/ctype/iswpunct.c",
    "src/ctype/iswgraph.c",
    "src/ctype/iswxdigit.c",
    "src/ctype/iswctype.c",
    "src/ctype/wctrans.c",
    "src/ctype/towctrans.c",
    "src/ctype/wcwidth.c",
    "src/ctype/wcswidth.c",
    // -- locale --
    "src/locale/langinfo.c",
    "src/locale/__lctrans.c",
    "src/locale/c_locale.c",
    "src/locale/localeconv.c",
    "src/locale/uselocale.c",
    "src/locale/setlocale.c",
    "src/locale/iconv.c",
    // -- multibyte --
    "src/multibyte/mbrtowc.c",
    "src/multibyte/wcrtomb.c",
    "src/multibyte/wctomb.c",
    "src/multibyte/mbtowc.c",
    "src/multibyte/mbsinit.c",
    "src/multibyte/mbsrtowcs.c",
    "src/multibyte/mbsnrtowcs.c",
    "src/multibyte/wcsrtombs.c",
    "src/multibyte/wcsnrtombs.c",
    "src/multibyte/internal.c",
    // -- exit --
    "src/exit/exit.c",
    "src/exit/_Exit.c",
    "src/exit/atexit.c",
    // -- process (simple wrappers only, fork/waitpid provided by process_stubs.c) --
    "src/process/execve.c",
    "src/unistd/getppid.c",
    "src/unistd/pipe.c",
    // -- env --
    "src/env/__libc_start_main.c",
    "src/env/__init_tls.c",
    "src/env/__stack_chk_fail.c",
    // -- math (needed by printf for float formatting) --
    "src/math/frexp.c",
    "src/math/frexpl.c",
    "src/math/copysignl.c",
    "src/math/fabs.c",
    "src/math/fabsl.c",
    "src/math/scalbn.c",
    "src/math/scalbnl.c",
    "src/math/__fpclassify.c",
    "src/math/__fpclassifyl.c",
    "src/math/__signbit.c",
    "src/math/__signbitl.c",
    "src/math/fmod.c",
    "src/math/fmodl.c",
    "src/math/log10.c",
    "src/math/log2.c",
    "src/math/ceil.c",
    "src/math/floor.c",
    "src/math/round.c",
    // -- malloc --
    "src/malloc/mallocng/malloc.c",
    "src/malloc/mallocng/free.c",
    "src/malloc/mallocng/realloc.c",
    "src/malloc/mallocng/aligned_alloc.c",
    "src/malloc/mallocng/donate.c",
    "src/malloc/calloc.c",
    "src/malloc/lite_malloc.c",
    "src/malloc/free.c",
    "src/malloc/realloc.c",
    "src/malloc/replaced.c",
    // -- stat --
    "src/stat/fstat.c",
    "src/stat/stat.c",
    "src/stat/fstatat.c",
    "src/stat/lstat.c",
    // -- unistd --
    "src/unistd/lseek.c",
    "src/unistd/read.c",
    "src/unistd/write.c",
    "src/unistd/close.c",
    "src/unistd/getpid.c",
    "src/unistd/getcwd.c",
    "src/unistd/access.c",
    "src/unistd/dup.c",
    "src/unistd/dup2.c",
    "src/unistd/readlink.c",
    "src/unistd/readlinkat.c",
    "src/unistd/isatty.c",
    "src/unistd/sleep.c",
    "src/unistd/usleep.c",
    // -- fcntl --
    "src/fcntl/open.c",
    "src/fcntl/openat.c",
    "src/fcntl/creat.c",
    "src/fcntl/fcntl.c",
    // -- dirent --
    "src/dirent/opendir.c",
    "src/dirent/closedir.c",
    "src/dirent/readdir.c",
    // -- time --
    "src/time/clock_gettime.c",
    "src/time/time.c",
    "src/time/gettimeofday.c",
    "src/time/localtime.c",
    "src/time/localtime_r.c",
    "src/time/gmtime.c",
    "src/time/gmtime_r.c",
    "src/time/mktime.c",
    "src/time/__secs_to_tm.c",
    "src/time/__tm_to_secs.c",
    "src/time/__year_to_secs.c",
    "src/time/__month_to_secs.c",
    "src/time/__tz.c",
    "src/time/strftime.c",
    "src/time/clock.c",
    // -- misc --
    "src/misc/basename.c",
    "src/misc/dirname.c",
    // -- mman --
    "src/mman/mmap.c",
    "src/mman/munmap.c",
    "src/mman/mprotect.c",
    "src/mman/madvise.c",
    // -- signal stubs --
    "src/signal/sigaction.c",
    "src/signal/sigprocmask.c",
    // -- prng --
    "src/prng/__rand48_step.c",
    "src/prng/rand.c",
    "src/prng/rand_r.c",
};

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const cluster = b.option(bool, "cluster", "Enable clustering support (gossip discovery, remote namespaces, scheduler)") orelse false;
    const posix = b.option(bool, "posix", "Enable C/POSIX realm support") orelse false;
    const containers = b.option(bool, "containers", "Enable container support (fnx CLI, Linux compat, bridge)") orelse false;
    const test_packages = b.option(bool, "test-packages", "Build test packages (xxd) for integration tests") orelse false;
    const user_strip = b.option(bool, "strip", "Strip debug info from userspace binaries") orelse
        (optimize != .Debug); // strip by default on release builds

    // Userspace always uses ReleaseSafe: keeps bounds/overflow checks while
    // producing small stack frames. Debug mode overflows the 256 KB user stack.
    const user_optimize: std.builtin.OptimizeMode = .ReleaseSafe;

    // ── Build options (passed to kernel as @import("build_options")) ──
    const build_options = b.addOptions();
    build_options.addOption(bool, "cluster", cluster);
    build_options.addOption(bool, "posix", posix);
    build_options.addOption(bool, "containers", containers);

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

    // ── Host tool: fay-build ─────────────────────────────────────
    const fay_build = b.addExecutable(.{
        .name = "fay-build",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fay-build.zig"),
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    dd_bin.image_base = user_image_base;

    const chmod_bin = b.addExecutable(.{
        .name = "chmod",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/chmod/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .strip = if (user_strip) true else null,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    chmod_bin.image_base = user_image_base;

    const chown_bin = b.addExecutable(.{
        .name = "chown",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/chown/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .strip = if (user_strip) true else null,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    chown_bin.image_base = user_image_base;

    const chgrp_bin = b.addExecutable(.{
        .name = "chgrp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/chgrp/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .strip = if (user_strip) true else null,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    chgrp_bin.image_base = user_image_base;

    const ip_bin = b.addExecutable(.{
        .name = "ip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/ip/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .strip = if (user_strip) true else null,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    ip_bin.image_base = user_image_base;

    const grep_bin = b.addExecutable(.{
        .name = "grep",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/grep/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    fe_bin.image_base = user_image_base;

    const lspci_bin = b.addExecutable(.{
        .name = "lspci",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/lspci/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .strip = if (user_strip) true else null,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    lspci_bin.image_base = user_image_base;

    const lsusb_bin = b.addExecutable(.{
        .name = "lsusb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/lsusb/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .strip = if (user_strip) true else null,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    lsusb_bin.image_base = user_image_base;

    const lscpu_bin = b.addExecutable(.{
        .name = "lscpu",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/lscpu/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .strip = if (user_strip) true else null,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    lscpu_bin.image_base = user_image_base;

    const login_bin = b.addExecutable(.{
        .name = "login",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/login/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .strip = if (user_strip) true else null,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    login_bin.image_base = user_image_base;

    const id_bin = b.addExecutable(.{
        .name = "id",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/id/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .strip = if (user_strip) true else null,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    id_bin.image_base = user_image_base;

    const whoami_bin = b.addExecutable(.{
        .name = "whoami",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/whoami/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .strip = if (user_strip) true else null,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    whoami_bin.image_base = user_image_base;

    const adduser_bin = b.addExecutable(.{
        .name = "adduser",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/adduser/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .strip = if (user_strip) true else null,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    adduser_bin.image_base = user_image_base;

    const su_bin = b.addExecutable(.{
        .name = "su",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/su/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .strip = if (user_strip) true else null,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    su_bin.image_base = user_image_base;

    const unzip_bin = b.addExecutable(.{
        .name = "unzip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/unzip/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .strip = if (user_strip) true else null,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    unzip_bin.image_base = user_image_base;

    const tar_bin = b.addExecutable(.{
        .name = "tar",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/tar/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .strip = if (user_strip) true else null,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    tar_bin.image_base = user_image_base;

    // fay_bin defined after TLS section so it can conditionally import TLS
    var fay_bin: *std.Build.Step.Compile = undefined;

    const fxfs_bin = b.addExecutable(.{
        .name = "fxfs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("srv/fxfs/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .strip = if (user_strip) true else null,
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
            .strip = if (user_strip) true else null,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    partfs_bin.image_base = user_image_base;

    const netd_bin = b.addExecutable(.{
        .name = "netd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("srv/netd/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .strip = if (user_strip) true else null,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    netd_bin.image_base = user_image_base;

    const crond_bin = b.addExecutable(.{
        .name = "crond",
        .root_module = b.createModule(.{
            .root_source_file = b.path("srv/crond/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .strip = if (user_strip) true else null,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    crond_bin.image_base = user_image_base;

    const gpud_bin = b.addExecutable(.{
        .name = "gpud",
        .root_module = b.createModule(.{
            .root_source_file = b.path("srv/gpud/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .strip = if (user_strip) true else null,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    gpud_bin.image_base = user_image_base;

    // cntrd, linuxd, fnx, bridge: now in fornax-sys/fnx external package.
    // Build with -Dcontainers=true only affects kernel comptime gating.
    // Install container binaries via: fay install fornax-sys

    const crontab_bin = b.addExecutable(.{
        .name = "crontab",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/crontab/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .strip = if (user_strip) true else null,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    crontab_bin.image_base = user_image_base;

    const date_bin = b.addExecutable(.{
        .name = "date",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/date/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .strip = if (user_strip) true else null,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    date_bin.image_base = user_image_base;

    const uptime_bin = b.addExecutable(.{
        .name = "uptime",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/uptime/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .strip = if (user_strip) true else null,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    uptime_bin.image_base = user_image_base;

    const ktrace_bin = b.addExecutable(.{
        .name = "ktrace",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/ktrace/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .strip = if (user_strip) true else null,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    ktrace_bin.image_base = user_image_base;

    const smp_test_bin = b.addExecutable(.{
        .name = "smp-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/smp-test/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .strip = if (user_strip) true else null,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    smp_test_bin.image_base = user_image_base;

    const iperf_bin = b.addExecutable(.{
        .name = "iperf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("../fornax-tools/iperf/main.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .strip = if (user_strip) true else null,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        }),
    });
    iperf_bin.image_base = user_image_base;

    // ── TLS support (BearSSL, x86_64 only) ────────────────────────────
    // BearSSL compiled as static library, linked into TLS-capable programs.
    var bearssl_lib: ?*std.Build.Step.Compile = null;
    var tls_module: ?*std.Build.Module = null;
    if (b.lazyDependency("bearssl", .{})) |bearssl_dep| {
        const lib = b.addLibrary(.{
            .linkage = .static,
            .name = "bearssl",
            .root_module = b.createModule(.{
                .target = x86_64_freestanding,
                .optimize = user_optimize,
            }),
        });

        const bearssl_flags: []const []const u8 = &.{
            "-std=c99",
            "-ffreestanding",
            "-nostdinc",
            "-fno-sanitize=all",
            "-DBR_LE_UNALIGNED=0",
            "-DBR_USE_URANDOM=0",
            "-DBR_USE_WIN32_RAND=0",
            "-DBR_64=1",
            "-DBR_RDRAND=0",
            b.fmt("-I{s}", .{bearssl_dep.path("inc").getPath(b)}),
            b.fmt("-I{s}", .{bearssl_dep.path("src").getPath(b)}),
            b.fmt("-I{s}", .{b.path("lib/tls/include").getPath(b)}),
        };

        // Add BearSSL source files by walking subdirectories
        addBearsslSources(b, lib, bearssl_dep, bearssl_flags);

        // Add Fornax stubs (strlen for freestanding)
        lib.addCSourceFile(.{
            .file = b.path("lib/tls/stubs.c"),
            .flags = bearssl_flags,
        });

        bearssl_lib = lib;

        // Create TLS module (separate from fornax, uses @cImport for bearssl.h)
        const tmod = b.createModule(.{
            .root_source_file = b.path("lib/tls.zig"),
            .target = x86_64_freestanding,
            .optimize = user_optimize,
            .imports = &.{
                .{ .name = "fornax", .module = fornax_module },
            },
        });
        tmod.addIncludePath(bearssl_dep.path("inc"));
        tmod.addIncludePath(bearssl_dep.path("src"));
        tmod.addIncludePath(b.path("lib/tls/include"));
        tls_module = tmod;
    }

    // ── fay package manager (conditionally TLS-capable) ──────────────
    {
        var fay_imports: [2]std.Build.Module.Import = .{
            .{ .name = "fornax", .module = fornax_module },
            undefined,
        };
        var fay_import_count: usize = 1;
        if (tls_module) |tmod| {
            fay_imports[fay_import_count] = .{ .name = "tls", .module = tmod };
            fay_import_count += 1;
        }

        fay_bin = b.addExecutable(.{
            .name = "fay",
            .root_module = b.createModule(.{
                .root_source_file = b.path("cmd/fay/main.zig"),
                .target = x86_64_freestanding,
                .optimize = user_optimize,
                .strip = if (user_strip) true else null,
                .imports = fay_imports[0..fay_import_count],
            }),
        });
        fay_bin.image_base = user_image_base;
        if (bearssl_lib) |bssl| fay_bin.root_module.linkLibrary(bssl);
    }

    // ── curl HTTP client (conditionally TLS-capable) ──────────────
    var curl_bin: *std.Build.Step.Compile = undefined;
    {
        const curl_options = b.addOptions();
        curl_options.addOption(bool, "has_tls", tls_module != null);

        var curl_imports: [4]std.Build.Module.Import = .{
            .{ .name = "fornax", .module = fornax_module },
            .{ .name = "curl_options", .module = curl_options.createModule() },
            undefined,
            undefined,
        };
        var curl_import_count: usize = 2;
        if (tls_module) |tmod| {
            curl_imports[curl_import_count] = .{ .name = "tls", .module = tmod };
            curl_import_count += 1;
        }

        curl_bin = b.addExecutable(.{
            .name = "curl",
            .root_module = b.createModule(.{
                .root_source_file = b.path("cmd/curl/main.zig"),
                .target = x86_64_freestanding,
                .optimize = user_optimize,
                .strip = if (user_strip) true else null,
                .imports = curl_imports[0..curl_import_count],
            }),
        });
        curl_bin.image_base = user_image_base;
        if (bearssl_lib) |bssl| curl_bin.root_module.linkLibrary(bssl);
    }

    // Container programs (fnx, cntrd, linuxd, bridge) now live in
    // fornax-sys/fnx external package. Install via: fay install fornax-sys

    // ── POSIX realm support (gated behind -Dposix=true) ─────────────
    // POSIX realm isolation is handled by lib/posix/crt0.S (rfork(RFNAMEG))
    // which runs before musl's __libc_start_main. No separate loader needed.
    var hello_c_bin: ?*std.Build.Step.Compile = null;
    var posix_disk_programs: [4]?*std.Build.Step.Compile = .{ null, null, null, null };
    var tcc_bin: ?*std.Build.Step.Compile = null;
    var xxd_test_bin: ?*std.Build.Step.Compile = null;

    if (posix) {

        // hello-c: freestanding C test program (no musl, no PT_INTERP)
        const hc_bin = b.addExecutable(.{
            .name = "hello-c",
            .root_module = b.createModule(.{
                .target = x86_64_freestanding,
                .optimize = user_optimize,
                .strip = if (user_strip) true else null,
            }),
        });
        hc_bin.addCSourceFile(.{ .file = b.path("cmd/hello-c/main.c"), .flags = &.{ "-ffreestanding", "-nostdlib", "-nostdinc" } });
        hc_bin.addAssemblyFile(b.path("lib/c/crt0-x86_64.S"));
        hc_bin.addIncludePath(b.path("lib/c"));
        hc_bin.image_base = user_image_base;
        hello_c_bin = hc_bin;

        // POSIX programs use the same freestanding target as native programs.
        // Realm isolation is handled by crt0.S (rfork), not PT_INTERP.

        // POSIX C programs using musl libc (requires musl lazy dependency)
        if (b.lazyDependency("musl", .{})) |musl_dep| {
            // Build include path flags as -I strings (must be -I, not -isystem,
            // for correct musl header resolution on freestanding targets)
            const c_flags = &[_][]const u8{
                "-std=c99",
                "-ffreestanding",
                "-nostdinc",
                "-fno-sanitize=all",
                "-D_XOPEN_SOURCE=700",
                "-D_FORNAX",
                "-DSINGLE_THREADED",
                "-Wno-bitwise-op-parentheses",
                "-Wno-shift-op-parentheses",
                "-Wno-ignored-attributes",
                "-Wno-string-plus-int",
                "-Wno-dangling-else",
                "-Wno-parentheses",
                "-Wno-logical-op-parentheses",
                b.fmt("-I{s}", .{b.path("lib/posix/overlay").getPath(b)}),
                b.fmt("-I{s}", .{musl_dep.path("arch/x86_64").getPath(b)}),
                b.fmt("-I{s}", .{musl_dep.path("arch/generic").getPath(b)}),
                b.fmt("-I{s}", .{musl_dep.path("src/include").getPath(b)}),
                b.fmt("-I{s}", .{musl_dep.path("src/internal").getPath(b)}),
                b.fmt("-I{s}", .{musl_dep.path("include").getPath(b)}),
            };

            // Helper to create a POSIX program linked with musl
            const posix_programs: []const struct { name: []const u8, src: []const u8 } = &.{
                .{ .name = "hello-posix", .src = "cmd/hello-posix/main.c" },
                .{ .name = "cat-posix", .src = "cmd/cat-posix/main.c" },
                .{ .name = "malloc-test", .src = "cmd/malloc-test/main.c" },
                .{ .name = "thread-test", .src = "cmd/thread-test/main.c" },
                .{ .name = "pthread-mutex", .src = "cmd/pthread-mutex/main.c" },
                .{ .name = "fork-test", .src = "cmd/fork-test/main.c" },
            };

            for (posix_programs, 0..) |prog, idx| {
                const exe = b.addExecutable(.{
                    .name = prog.name,
                    .root_module = b.createModule(.{
                        .target = x86_64_freestanding,
                        .optimize = user_optimize,
                        .strip = if (user_strip) true else null,
                    }),
                });

                // Add POSIX crt0 (includes rfork for namespace isolation)
                exe.addAssemblyFile(b.path("lib/posix/crt0-x86_64.S"));

                // Add the shim (Linux → Fornax translation)
                exe.addCSourceFile(.{
                    .file = b.path("lib/posix/shim.c"),
                    .flags = c_flags,
                });
                exe.addCSourceFile(.{
                    .file = b.path("lib/posix/process_stubs.c"),
                    .flags = c_flags,
                });

                // Add the program's source
                exe.addCSourceFile(.{
                    .file = b.path(prog.src),
                    .flags = c_flags,
                });

                // Add musl source files individually (addCSourceFiles with .root
                // doesn't propagate .flags — a Zig build system bug)
                for (musl_sources) |src| {
                    exe.addCSourceFile(.{
                        .file = musl_dep.path(src),
                        .flags = c_flags,
                    });
                }

                exe.image_base = user_image_base;

                if (idx < posix_disk_programs.len) {
                    posix_disk_programs[idx] = exe;
                }
            }

            // ── TCC: Tiny C Compiler (built with POSIX) ─────────────
            if (b.lazyDependency("tcc", .{})) |tcc_dep| {
                const tcc_exe = b.addExecutable(.{
                    .name = "tcc",
                    .root_module = b.createModule(.{
                        .target = x86_64_freestanding,
                        .optimize = user_optimize,
                        .strip = if (user_strip) true else null,
                    }),
                });

                tcc_exe.addAssemblyFile(b.path("lib/posix/crt0-x86_64.S"));
                tcc_exe.addCSourceFile(.{
                    .file = b.path("lib/posix/shim.c"),
                    .flags = c_flags,
                });
                tcc_exe.addCSourceFile(.{
                    .file = b.path("lib/posix/process_stubs.c"),
                    .flags = c_flags,
                });

                // TCC-specific flags: uses musl public includes only (not
                // src/include or src/internal which define 'weak' macro
                // that conflicts with tcc's struct member .weak)
                const tcc_flags = &[_][]const u8{
                    "-std=c99",
                    "-ffreestanding",
                    "-nostdinc",
                    "-fno-sanitize=all",
                    "-D_XOPEN_SOURCE=700",
                    "-D_FORNAX",
                    "-DONE_SOURCE=1",
                    "-DTCC_TARGET_X86_64",
                    "-DCONFIG_TCC_STATIC",
                    "-DCONFIG_TCCDIR=\"/lib/tcc\"",
                    "-DCONFIG_TCC_SYSINCLUDEPATHS=\"{B}/include\"",
                    "-DCONFIG_TCC_LIBPATHS=\"{B}\"",
                    "-DCONFIG_TCC_CRTPREFIX=\"{B}\"",
                    "-DCONFIG_TCC_ELFINTERP=\"\"",
                    "-DCONFIG_SYSROOT=\"\"",
                    "-DCONFIG_USR_INCLUDE=\"\"",
                    "-DCONFIG_LDDIR=\"lib\"",
                    "-DTCC_VERSION=\"0.9.28rc\"",
                    "-DCONFIG_TCC_CROSSPREFIX=\"\"",
                    "-DCONFIG_TCC_PREDEFS=0",
                    "-Wno-unused-function",
                    "-Wno-unused-variable",
                    "-Wno-sign-compare",
                    "-Wno-implicit-function-declaration",
                    "-Wno-int-conversion",
                    "-Wno-incompatible-pointer-types",
                    "-Wno-bitwise-op-parentheses",
                    "-Wno-shift-op-parentheses",
                    "-Wno-parentheses",
                    "-Wno-string-plus-int",
                    b.fmt("-I{s}", .{b.path("lib/tcc").getPath(b)}),
                    b.fmt("-I{s}", .{tcc_dep.path("").getPath(b)}),
                    b.fmt("-I{s}", .{b.path("lib/posix/overlay").getPath(b)}),
                    b.fmt("-I{s}", .{musl_dep.path("arch/x86_64").getPath(b)}),
                    b.fmt("-I{s}", .{musl_dep.path("arch/generic").getPath(b)}),
                    b.fmt("-I{s}", .{musl_dep.path("include").getPath(b)}),
                };

                tcc_exe.addCSourceFile(.{
                    .file = tcc_dep.path("tcc.c"),
                    .flags = tcc_flags,
                });

                // Musl sources (same as other POSIX programs)
                for (musl_sources) |src| {
                    tcc_exe.addCSourceFile(.{
                        .file = musl_dep.path(src),
                        .flags = c_flags,
                    });
                }

                // Fornax stubs for functions TCC references but Fornax
                // doesn't support (sem_*, signal, tccrun, etc.)
                tcc_exe.addCSourceFile(.{
                    .file = b.path("lib/tcc/fornax_stubs.c"),
                    .flags = c_flags,
                });

                // Additional musl sources needed by tcc
                const tcc_extra_musl: []const []const u8 = &.{
                    "src/env/getenv.c",
                    "src/misc/realpath.c",
                    "src/unistd/unlink.c",
                    "src/unistd/rmdir.c",
                    "src/string/strpbrk.c",
                    "src/stdio/remove.c",
                    "src/stdlib/qsort_nr.c",
                    "src/math/ldexpl.c",
                };
                for (tcc_extra_musl) |src| {
                    tcc_exe.addCSourceFile(.{
                        .file = musl_dep.path(src),
                        .flags = c_flags,
                    });
                }

                // setjmp/longjmp assembly (tcc uses setjmp for error recovery)
                tcc_exe.addAssemblyFile(musl_dep.path("src/setjmp/x86_64/setjmp.s"));
                tcc_exe.addAssemblyFile(musl_dep.path("src/setjmp/x86_64/longjmp.s"));

                tcc_exe.image_base = user_image_base;
                tcc_bin = tcc_exe;
            }

            // ── Test packages (gated behind -Dtest-packages=true) ──
            if (test_packages) {
                const xxd_exe = b.addExecutable(.{
                    .name = "xxd",
                    .root_module = b.createModule(.{
                        .target = x86_64_freestanding,
                        .optimize = user_optimize,
                        .strip = if (user_strip) true else null,
                    }),
                });
                xxd_exe.addAssemblyFile(b.path("lib/posix/crt0-x86_64.S"));
                xxd_exe.addCSourceFile(.{ .file = b.path("lib/posix/shim.c"), .flags = c_flags });
                xxd_exe.addCSourceFile(.{ .file = b.path("lib/posix/process_stubs.c"), .flags = c_flags });
                xxd_exe.addCSourceFile(.{ .file = b.path("../fornax-ports/posix/xxd/xxd.c"), .flags = c_flags });
                for (musl_sources) |src| {
                    xxd_exe.addCSourceFile(.{ .file = musl_dep.path(src), .flags = c_flags });
                }
                xxd_exe.image_base = user_image_base;
                xxd_test_bin = xxd_exe;
            }
        }
    }

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
    // Container servers (cntrd, linuxd) are now in fornax-sys/fnx external package.
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
        chmod_bin, chown_bin, chgrp_bin, ip_bin,
        grep_bin, sed_bin, awk_bin, less_bin,
        fe_bin, lspci_bin, lsusb_bin, lscpu_bin,
        login_bin, id_bin, whoami_bin, adduser_bin, su_bin,
        unzip_bin,
        tar_bin,
        fay_bin,
        curl_bin,
        netd_bin,
        crond_bin,
        gpud_bin,
        crontab_bin,
        date_bin,
        uptime_bin,
        ktrace_bin,
        smp_test_bin,
        iperf_bin,
    };
    for (disk_programs) |prog| {
        const install = b.addInstallArtifact(prog, .{
            .dest_dir = .{ .override = .{ .custom = "rootfs/bin" } },
        });
        x86_initrd.step.dependOn(&install.step);
    }

    // Install POSIX programs to rootfs (if enabled)
    if (hello_c_bin) |hc_bin| {
        const install = b.addInstallArtifact(hc_bin, .{
            .dest_dir = .{ .override = .{ .custom = "rootfs/bin" } },
        });
        x86_initrd.step.dependOn(&install.step);
    }
    for (&posix_disk_programs) |maybe_bin| {
        if (maybe_bin) |px_bin| {
            const install = b.addInstallArtifact(px_bin, .{
                .dest_dir = .{ .override = .{ .custom = "rootfs/bin" } },
            });
            x86_initrd.step.dependOn(&install.step);
        }
    }

    // Install TCC binary, headers, and licenses to rootfs (if enabled)
    if (tcc_bin) |tcc_exe| {
        const tcc_install = b.addInstallArtifact(tcc_exe, .{
            .dest_dir = .{ .override = .{ .custom = "rootfs/bin" } },
        });
        x86_initrd.step.dependOn(&tcc_install.step);

        // Install tcc runtime headers to /lib/tcc/include/
        if (b.lazyDependency("tcc", .{})) |tcc_dep| {
            const tcc_headers: []const []const u8 = &.{
                "include/float.h",
                "include/stdalign.h",
                "include/stdarg.h",
                "include/stdatomic.h",
                "include/stdbool.h",
                "include/stddef.h",
                "include/stdnoreturn.h",
                "include/tccdefs.h",
                "include/tgmath.h",
                "include/varargs.h",
            };
            for (tcc_headers) |hdr| {
                const hdr_install = b.addInstallFile(tcc_dep.path(hdr), b.fmt("rootfs/lib/tcc/{s}", .{hdr}));
                x86_initrd.step.dependOn(&hdr_install.step);
            }
        }

        // Install fornax.h for native Fornax syscall access
        const fornax_h_install = b.addInstallFile(b.path("lib/c/fornax.h"), "rootfs/lib/tcc/include/fornax.h");
        x86_initrd.step.dependOn(&fornax_h_install.step);

        // Install license files
        const tcc_lic = b.addInstallFile(b.path("LICENSES/tcc"), "rootfs/lib/legal/tcc/COPYING");
        x86_initrd.step.dependOn(&tcc_lic.step);
        const musl_lic = b.addInstallFile(b.path("LICENSES/musl"), "rootfs/lib/legal/musl/COPYING");
        x86_initrd.step.dependOn(&musl_lic.step);
    }

    // Install /etc/net.conf to rootfs
    const net_conf_install = b.addInstallFile(b.path("etc/net.conf"), "rootfs/etc/net.conf");
    x86_initrd.step.dependOn(&net_conf_install.step);

    // Install test packages (if enabled)
    if (xxd_test_bin) |xxd_exe| {
        const xxd_install = b.addInstallArtifact(xxd_exe, .{
            .dest_dir = .{ .override = .{ .custom = "test-packages" } },
        });
        x86_initrd.step.dependOn(&xxd_install.step);
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
    aarch64_bin.addAssemblyFile(b.path("src/arch/aarch64/entry.S"));

    const aarch64_install = b.addInstallArtifact(aarch64_bin, .{
        .dest_dir = .{ .override = .{ .custom = "esp-aarch64/EFI/BOOT" } },
        .dest_sub_path = "BOOTAA64.EFI",
    });

    // aarch64 userspace (UEFI target, same as x86_64)
    const aarch64_freestanding = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const aa64_fornax_module = b.createModule(.{
        .root_source_file = b.path("lib/root.zig"),
        .target = aarch64_freestanding,
        .optimize = user_optimize,
    });

    const aa64_user_programs = .{
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
        .{ "chmod", "cmd/chmod/main.zig" },
        .{ "chown", "cmd/chown/main.zig" },
        .{ "chgrp", "cmd/chgrp/main.zig" },
        .{ "ip", "cmd/ip/main.zig" },
        .{ "grep", "cmd/grep/main.zig" },
        .{ "sed", "cmd/sed/main.zig" },
        .{ "awk", "cmd/awk/main.zig" },
        .{ "less", "cmd/less/main.zig" },
        .{ "fe", "cmd/fe/main.zig" },
        .{ "lspci", "cmd/lspci/main.zig" },
        .{ "lsusb", "cmd/lsusb/main.zig" },
        .{ "lscpu", "cmd/lscpu/main.zig" },
        .{ "login", "cmd/login/main.zig" },
        .{ "id", "cmd/id/main.zig" },
        .{ "whoami", "cmd/whoami/main.zig" },
        .{ "adduser", "cmd/adduser/main.zig" },
        .{ "su", "cmd/su/main.zig" },
        .{ "unzip", "cmd/unzip/main.zig" },
        .{ "tar", "cmd/tar/main.zig" },
        .{ "fay", "cmd/fay/main.zig" },
        .{ "fxfs", "srv/fxfs/main.zig" },
        .{ "partfs", "srv/partfs/main.zig" },
        .{ "ktrace", "cmd/ktrace/main.zig" },
        .{ "smp-test", "cmd/smp-test/main.zig" },
        .{ "netd", "srv/netd/main.zig" },
        .{ "crond", "srv/crond/main.zig" },
        .{ "gpud", "srv/gpud/main.zig" },
        .{ "crontab", "cmd/crontab/main.zig" },
        .{ "date", "cmd/date/main.zig" },
        .{ "uptime", "cmd/uptime/main.zig" },
        .{ "iperf", "../fornax-tools/iperf/main.zig" },
    };

    var aa64_initrd_bins: [3]*std.Build.Step.Compile = undefined;
    var aa64_disk_bin_buf: [64]*std.Build.Step.Compile = undefined;
    var aa64_disk_bin_count: usize = 0;

    inline for (aa64_user_programs) |prog_info| {
        const aa64_prog = b.addExecutable(.{
            .name = prog_info[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(prog_info[1]),
                .target = aarch64_freestanding,
                .optimize = user_optimize,
                .strip = if (user_strip) true else null,
                .imports = &.{
                    .{ .name = "fornax", .module = aa64_fornax_module },
                },
            }),
        });
        aa64_prog.image_base = user_image_base;

        const name: []const u8 = prog_info[0];
        if (std.mem.eql(u8, name, "init")) {
            aa64_initrd_bins[0] = aa64_prog;
        } else if (std.mem.eql(u8, name, "partfs")) {
            aa64_initrd_bins[1] = aa64_prog;
        } else if (std.mem.eql(u8, name, "fxfs")) {
            aa64_initrd_bins[2] = aa64_prog;
        } else {
            aa64_disk_bin_buf[aa64_disk_bin_count] = aa64_prog;
            aa64_disk_bin_count += 1;
        }
    }

    const aarch64_initrd = addInitrdStep(b, mkinitrd, "esp-aarch64/EFI/BOOT", &aa64_initrd_bins);
    aarch64_initrd.step.dependOn(&aarch64_install.step);

    for (aa64_disk_bin_buf[0..aa64_disk_bin_count]) |prog| {
        const install = b.addInstallArtifact(prog, .{
            .dest_dir = .{ .override = .{ .custom = "rootfs-aarch64/bin" } },
        });
        aarch64_initrd.step.dependOn(&install.step);
    }

    // aarch64 POSIX programs (gated behind -Dposix=true)
    if (posix) {
        // hello-c: freestanding C test program (no musl)
        const aa64_hc = b.addExecutable(.{
            .name = "hello-c",
            .root_module = b.createModule(.{
                .target = aarch64_freestanding,
                .optimize = user_optimize,
                .strip = if (user_strip) true else null,
            }),
        });
        aa64_hc.addCSourceFile(.{ .file = b.path("cmd/hello-c/main.c"), .flags = &.{ "-ffreestanding", "-nostdlib", "-nostdinc" } });
        aa64_hc.addAssemblyFile(b.path("lib/c/crt0-aarch64.S"));
        aa64_hc.addIncludePath(b.path("lib/c"));
        aa64_hc.image_base = user_image_base;
        const aa64_hc_install = b.addInstallArtifact(aa64_hc, .{
            .dest_dir = .{ .override = .{ .custom = "rootfs-aarch64/bin" } },
        });
        aarch64_initrd.step.dependOn(&aa64_hc_install.step);

        if (b.lazyDependency("musl", .{})) |musl_dep_aa64| {
            const aa64_c_flags = &[_][]const u8{
                "-std=c99",
                "-ffreestanding",
                "-nostdinc",
                "-fno-sanitize=all",
                "-D_XOPEN_SOURCE=700",
                "-D_FORNAX",
                "-DSINGLE_THREADED",
                "-Wno-bitwise-op-parentheses",
                "-Wno-shift-op-parentheses",
                "-Wno-ignored-attributes",
                "-Wno-string-plus-int",
                "-Wno-dangling-else",
                "-Wno-parentheses",
                "-Wno-logical-op-parentheses",
                b.fmt("-I{s}", .{b.path("lib/posix/overlay").getPath(b)}),
                b.fmt("-I{s}", .{musl_dep_aa64.path("arch/aarch64").getPath(b)}),
                b.fmt("-I{s}", .{musl_dep_aa64.path("arch/generic").getPath(b)}),
                b.fmt("-I{s}", .{musl_dep_aa64.path("src/include").getPath(b)}),
                b.fmt("-I{s}", .{musl_dep_aa64.path("src/internal").getPath(b)}),
                b.fmt("-I{s}", .{musl_dep_aa64.path("include").getPath(b)}),
            };

            const aa64_posix_programs: []const struct { name: []const u8, src: []const u8 } = &.{
                .{ .name = "hello-posix", .src = "cmd/hello-posix/main.c" },
                .{ .name = "cat-posix", .src = "cmd/cat-posix/main.c" },
                .{ .name = "malloc-test", .src = "cmd/malloc-test/main.c" },
                .{ .name = "fork-test", .src = "cmd/fork-test/main.c" },
            };

            for (aa64_posix_programs) |prog| {
                const aa64_px = b.addExecutable(.{
                    .name = prog.name,
                    .root_module = b.createModule(.{
                        .target = aarch64_freestanding,
                        .optimize = user_optimize,
                        .strip = if (user_strip) true else null,
                    }),
                });
                aa64_px.addAssemblyFile(b.path("lib/posix/crt0-aarch64.S"));
                aa64_px.addCSourceFile(.{ .file = b.path("lib/posix/shim.c"), .flags = aa64_c_flags });
                aa64_px.addCSourceFile(.{ .file = b.path("lib/posix/process_stubs.c"), .flags = aa64_c_flags });
                aa64_px.addCSourceFile(.{ .file = b.path(prog.src), .flags = aa64_c_flags });
                for (musl_sources) |src| {
                    aa64_px.addCSourceFile(.{ .file = musl_dep_aa64.path(src), .flags = aa64_c_flags });
                }
                aa64_px.image_base = user_image_base;
                const aa64_px_install = b.addInstallArtifact(aa64_px, .{
                    .dest_dir = .{ .override = .{ .custom = "rootfs-aarch64/bin" } },
                });
                aarch64_initrd.step.dependOn(&aa64_px_install.step);
            }
        }
    }

    // Container programs (fnx, cntrd, linuxd, bridge) now in fornax-sys/fnx external package.

    // Install /etc/net.conf to aarch64 rootfs
    const aa64_net_conf = b.addInstallFile(b.path("etc/net.conf"), "rootfs-aarch64/etc/net.conf");
    aarch64_initrd.step.dependOn(&aa64_net_conf.step);

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
        .{ "chmod", "cmd/chmod/main.zig" },
        .{ "chown", "cmd/chown/main.zig" },
        .{ "chgrp", "cmd/chgrp/main.zig" },
        .{ "ip", "cmd/ip/main.zig" },
        .{ "grep", "cmd/grep/main.zig" },
        .{ "sed", "cmd/sed/main.zig" },
        .{ "awk", "cmd/awk/main.zig" },
        .{ "less", "cmd/less/main.zig" },
        .{ "fe", "cmd/fe/main.zig" },
        .{ "lspci", "cmd/lspci/main.zig" },
        .{ "lsusb", "cmd/lsusb/main.zig" },
        .{ "lscpu", "cmd/lscpu/main.zig" },
        .{ "login", "cmd/login/main.zig" },
        .{ "id", "cmd/id/main.zig" },
        .{ "whoami", "cmd/whoami/main.zig" },
        .{ "adduser", "cmd/adduser/main.zig" },
        .{ "su", "cmd/su/main.zig" },
        .{ "unzip", "cmd/unzip/main.zig" },
        .{ "tar", "cmd/tar/main.zig" },
        .{ "fay", "cmd/fay/main.zig" },
        .{ "fxfs", "srv/fxfs/main.zig" },
        .{ "partfs", "srv/partfs/main.zig" },
        .{ "ktrace", "cmd/ktrace/main.zig" },
        .{ "smp-test", "cmd/smp-test/main.zig" },
        .{ "netd", "srv/netd/main.zig" },
        .{ "crond", "srv/crond/main.zig" },
        .{ "gpud", "srv/gpud/main.zig" },
        .{ "crontab", "cmd/crontab/main.zig" },
        .{ "date", "cmd/date/main.zig" },
        .{ "uptime", "cmd/uptime/main.zig" },
        .{ "iperf", "../fornax-tools/iperf/main.zig" },
    };

    // Build riscv64 initrd programs (init, partfs, fxfs)
    var rv_initrd_bins: [3]*std.Build.Step.Compile = undefined;
    var rv_disk_bin_buf: [64]*std.Build.Step.Compile = undefined;
    var rv_disk_bin_count: usize = 0;

    inline for (rv_user_programs) |prog_info| {
        const rv_prog = b.addExecutable(.{
            .name = prog_info[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(prog_info[1]),
                .target = riscv64_freestanding,
                .optimize = user_optimize,
                .strip = if (user_strip) true else null,
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

    // riscv64 POSIX programs (gated behind -Dposix=true)
    if (posix) {
        // hello-c: freestanding C test program (no musl)
        const rv_hc = b.addExecutable(.{
            .name = "hello-c",
            .root_module = b.createModule(.{
                .target = riscv64_freestanding,
                .optimize = user_optimize,
                .strip = if (user_strip) true else null,
            }),
        });
        rv_hc.addCSourceFile(.{ .file = b.path("cmd/hello-c/main.c"), .flags = &.{ "-ffreestanding", "-nostdlib", "-nostdinc" } });
        rv_hc.addAssemblyFile(b.path("lib/c/crt0-riscv64.S"));
        rv_hc.addIncludePath(b.path("lib/c"));
        rv_hc.image_base = user_image_base;
        const rv_hc_install = b.addInstallArtifact(rv_hc, .{
            .dest_dir = .{ .override = .{ .custom = "rootfs-riscv64/bin" } },
        });
        rv_initrd.step.dependOn(&rv_hc_install.step);

        if (b.lazyDependency("musl", .{})) |musl_dep_rv| {
            const rv_c_flags = &[_][]const u8{
                "-std=c99",
                "-ffreestanding",
                "-nostdinc",
                "-fno-sanitize=all",
                "-D_XOPEN_SOURCE=700",
                "-D_FORNAX",
                "-DSINGLE_THREADED",
                "-Wno-bitwise-op-parentheses",
                "-Wno-shift-op-parentheses",
                "-Wno-ignored-attributes",
                "-Wno-string-plus-int",
                "-Wno-dangling-else",
                "-Wno-parentheses",
                "-Wno-logical-op-parentheses",
                b.fmt("-I{s}", .{b.path("lib/posix/overlay").getPath(b)}),
                b.fmt("-I{s}", .{musl_dep_rv.path("arch/riscv64").getPath(b)}),
                b.fmt("-I{s}", .{musl_dep_rv.path("arch/generic").getPath(b)}),
                b.fmt("-I{s}", .{musl_dep_rv.path("src/include").getPath(b)}),
                b.fmt("-I{s}", .{musl_dep_rv.path("src/internal").getPath(b)}),
                b.fmt("-I{s}", .{musl_dep_rv.path("include").getPath(b)}),
            };

            const rv_posix_programs: []const struct { name: []const u8, src: []const u8 } = &.{
                .{ .name = "hello-posix", .src = "cmd/hello-posix/main.c" },
                .{ .name = "cat-posix", .src = "cmd/cat-posix/main.c" },
                .{ .name = "malloc-test", .src = "cmd/malloc-test/main.c" },
                .{ .name = "fork-test", .src = "cmd/fork-test/main.c" },
            };

            for (rv_posix_programs) |prog| {
                const rv_px = b.addExecutable(.{
                    .name = prog.name,
                    .root_module = b.createModule(.{
                        .target = riscv64_freestanding,
                        .optimize = user_optimize,
                        .strip = if (user_strip) true else null,
                    }),
                });
                rv_px.addAssemblyFile(b.path("lib/posix/crt0-riscv64.S"));
                rv_px.addCSourceFile(.{ .file = b.path("lib/posix/shim.c"), .flags = rv_c_flags });
                rv_px.addCSourceFile(.{ .file = b.path("lib/posix/process_stubs.c"), .flags = rv_c_flags });
                rv_px.addCSourceFile(.{ .file = b.path(prog.src), .flags = rv_c_flags });
                for (musl_sources) |src| {
                    rv_px.addCSourceFile(.{ .file = musl_dep_rv.path(src), .flags = rv_c_flags });
                }
                rv_px.image_base = user_image_base;
                const rv_px_install = b.addInstallArtifact(rv_px, .{
                    .dest_dir = .{ .override = .{ .custom = "rootfs-riscv64/bin" } },
                });
                rv_initrd.step.dependOn(&rv_px_install.step);
            }
        }
    }

    // Container programs (fnx, cntrd, linuxd, bridge) now in fornax-sys/fnx external package.

    // Install /etc/net.conf to riscv64 rootfs
    const rv_net_conf = b.addInstallFile(b.path("etc/net.conf"), "rootfs-riscv64/etc/net.conf");
    rv_initrd.step.dependOn(&rv_net_conf.step);

    // ── Named steps ─────────────────────────────────────────────────
    const mkfxfs_install = b.addInstallArtifact(mkfxfs, .{});
    const mkfxfs_step = b.step("mkfxfs", "Build mkfxfs disk formatter");
    mkfxfs_step.dependOn(&mkfxfs_install.step);

    const mkgpt_install = b.addInstallArtifact(mkgpt, .{});
    const mkgpt_step = b.step("mkgpt", "Build mkgpt partition tool");
    mkgpt_step.dependOn(&mkgpt_install.step);

    const fay_build_install = b.addInstallArtifact(fay_build, .{});
    const fay_build_step = b.step("fay-build", "Build fay-build package builder");
    fay_build_step.dependOn(&fay_build_install.step);

    const x86_step = b.step("x86_64", "Build x86_64 UEFI kernel");
    x86_step.dependOn(&x86_install.step);
    x86_step.dependOn(&x86_initrd.step);

    const aarch64_step = b.step("aarch64", "Build aarch64 UEFI kernel + userspace");
    aarch64_step.dependOn(&aarch64_install.step);
    aarch64_step.dependOn(&aarch64_initrd.step);

    const riscv64_step = b.step("riscv64", "Build riscv64 freestanding kernel");
    riscv64_step.dependOn(&riscv64_install.step);
    riscv64_step.dependOn(&rv_initrd.step);

    // ── Unit tests (host-targeted, no OS dependencies) ──────────────
    const test_step = b.step("test", "Run unit tests");

    const host = b.graph.host;
    const test_opt: std.builtin.OptimizeMode = .Debug;

    // Library modules (host-targeted for testing)
    const mod_fmt = b.createModule(.{ .root_source_file = b.path("lib/fmt.zig"), .target = host, .optimize = test_opt });
    const mod_str = b.createModule(.{ .root_source_file = b.path("lib/str.zig"), .target = host, .optimize = test_opt });
    const mod_path = b.createModule(.{ .root_source_file = b.path("lib/path.zig"), .target = host, .optimize = test_opt });
    const mod_crc32 = b.createModule(.{ .root_source_file = b.path("lib/crc32.zig"), .target = host, .optimize = test_opt });
    const mod_sha256 = b.createModule(.{ .root_source_file = b.path("lib/sha256.zig"), .target = host, .optimize = test_opt });
    const mod_json = b.createModule(.{ .root_source_file = b.path("lib/json.zig"), .target = host, .optimize = test_opt });
    const mod_time = b.createModule(.{ .root_source_file = b.path("lib/time.zig"), .target = host, .optimize = test_opt });
    const mod_ipc = b.createModule(.{ .root_source_file = b.path("lib/ipc.zig"), .target = host, .optimize = test_opt });
    const mod_ethernet = b.createModule(.{ .root_source_file = b.path("lib/net/ethernet.zig"), .target = host, .optimize = test_opt });
    const mod_ipv4 = b.createModule(.{ .root_source_file = b.path("lib/net/ipv4.zig"), .target = host, .optimize = test_opt });
    // arp/tcp/dns/icmp use relative @import("ethernet.zig") and @import("ipv4.zig")
    // — remap those to the shared modules so files don't belong to multiple modules.
    const mod_arp = b.createModule(.{
        .root_source_file = b.path("lib/net/arp.zig"),
        .target = host,
        .optimize = test_opt,
        .imports = &.{
            .{ .name = "ethernet.zig", .module = mod_ethernet },
            .{ .name = "ipv4.zig", .module = mod_ipv4 },
        },
    });
    const mod_tcp = b.createModule(.{
        .root_source_file = b.path("lib/net/tcp.zig"),
        .target = host,
        .optimize = test_opt,
        .imports = &.{
            .{ .name = "ipv4.zig", .module = mod_ipv4 },
        },
    });
    const mod_dns = b.createModule(.{
        .root_source_file = b.path("lib/net/dns.zig"),
        .target = host,
        .optimize = test_opt,
        .imports = &.{
            .{ .name = "ipv4.zig", .module = mod_ipv4 },
        },
    });
    const mod_icmp = b.createModule(.{
        .root_source_file = b.path("lib/net/icmp.zig"),
        .target = host,
        .optimize = test_opt,
        .imports = &.{
            .{ .name = "ipv4.zig", .module = mod_ipv4 },
        },
    });

    const tests = b.addTest(.{
        .name = "fornax-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/root.zig"),
            .target = host,
            .optimize = test_opt,
            .imports = &.{
                .{ .name = "fmt", .module = mod_fmt },
                .{ .name = "str", .module = mod_str },
                .{ .name = "path", .module = mod_path },
                .{ .name = "crc32", .module = mod_crc32 },
                .{ .name = "sha256", .module = mod_sha256 },
                .{ .name = "json", .module = mod_json },
                .{ .name = "ethernet", .module = mod_ethernet },
                .{ .name = "ipv4", .module = mod_ipv4 },
                .{ .name = "arp", .module = mod_arp },
                .{ .name = "tcp", .module = mod_tcp },
                .{ .name = "dns", .module = mod_dns },
                .{ .name = "icmp", .module = mod_icmp },
                .{ .name = "time", .module = mod_time },
                .{ .name = "ipc", .module = mod_ipc },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

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

/// Walk BearSSL src/ subdirectories and add all .c files to the compile step.
fn addBearsslSources(
    b: *std.Build,
    lib: *std.Build.Step.Compile,
    bearssl_dep: *std.Build.Dependency,
    flags: []const []const u8,
) void {
    const subdirs: []const []const u8 = &.{
        "src/aead",     "src/codec", "src/ec",  "src/hash",
        "src/int",      "src/kdf",   "src/mac", "src/rand",
        "src/rsa",      "src/ssl",   "src/symcipher",
        "src/x509",
    };
    for (subdirs) |subdir| {
        const abs_path = bearssl_dep.path(subdir).getPath(b);
        var dir = std.fs.cwd().openDir(abs_path, .{ .iterate = true }) catch continue;
        defer dir.close();
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .file and endsWith(entry.name, ".c")) {
                lib.addCSourceFile(.{
                    .file = bearssl_dep.path(b.fmt("{s}/{s}", .{ subdir, entry.name })),
                    .flags = flags,
                });
            }
        }
    }
    // Top-level settings.c
    lib.addCSourceFile(.{
        .file = bearssl_dep.path("src/settings.c"),
        .flags = flags,
    });
}

fn endsWith(s: []const u8, suffix: []const u8) bool {
    if (s.len < suffix.len) return false;
    return std.mem.eql(u8, s[s.len - suffix.len ..], suffix);
}
