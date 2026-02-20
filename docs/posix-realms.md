# POSIX Realms

Fornax provides two tiers of C support. The kernel remains Plan 9-pure in both
cases — all POSIX translation happens in userspace.

## Tier 1: Native C

Freestanding C programs that call Fornax syscalls directly via `lib/c/fornax.h`.
No libc, no POSIX — same interface as Zig programs, just in C.

```c
#include "fornax.h"

int main(int argc, char **argv) {
    fx_write(1, "Hello from C!\n", 14);
    return 0;
}
```

**How it works:**

- `fornax.h` provides inline-asm syscall wrappers (`fx_open`, `fx_write`, etc.)
  that encode the Fornax Plan 9 syscall ABI directly (RAX=nr, RDI/RSI/RDX/R10/R8)
- `lib/c/crt0.S` is the entry point: clears frame pointer, loads argc/argv from
  `ARGV_BASE` (0x7FFF_FFEF_F000), aligns RSP, calls `main`, then `SYS_EXIT`
- No libc, no translation layer — the program speaks kernel-native

**Build:** `zig build x86_64 -Dposix=true` (the `-Dposix` flag enables all C targets)

## Tier 2: POSIX C (Realms)

Standard C programs linked against musl libc, using `<stdio.h>`, `<stdlib.h>`,
etc. These run inside a **POSIX realm** — an isolated namespace boundary created
at process startup.

```c
#include <stdio.h>

int main(int argc, char **argv) {
    printf("Hello POSIX!\n");
    return 0;
}
```

This program uses `printf`, which goes through musl's stdio buffering, TLS for
errno, `mmap` for malloc, and multiple syscalls. All of that works transparently
because of the translation shim.

## Architecture

```
  Standard C program
     (stdio.h, etc.)
          |
      musl libc
   (statically linked)
          |
  syscall_arch.h override
   (__syscallN → __fornax_syscall)
          |
      shim.c
   (Linux nr → Fornax nr
    + semantic translation)
          |
    raw SYSCALL instruction
   (Fornax Plan 9 ABI)
          |
    Fornax kernel
```

The key insight: musl thinks it's talking to a Linux kernel. It emits Linux
syscall numbers (e.g., `write = 1`, `mmap = 9`, `arch_prctl = 158`). The shim
intercepts these *before* they reach the kernel and translates both the syscall
number and the calling convention to Fornax's Plan 9 interface.

### Component Walkthrough

**`lib/posix/overlay/syscall_arch.h`** — The interception point. This file
replaces musl's built-in `arch/x86_64/syscall_arch.h`. Instead of emitting
raw `SYSCALL` instructions, every `__syscallN` macro routes through
`__fornax_syscall()`:

```c
long __fornax_syscall(long n, long a, long b, long c, long d, long e, long f);

static __inline long __syscall3(long n, long a, long b, long c)
{
    return __fornax_syscall(n, a, b, c, 0, 0, 0);
}
// ... __syscall0 through __syscall6
```

**`lib/posix/shim.c`** (~580 lines) — The translation engine. Receives Linux
syscall numbers and translates to Fornax:

| Linux syscall | Fornax translation |
|---|---|
| `write(1)` | `FX_WRITE(3)` — direct, same semantics |
| `read(0)` | `FX_READ(2)` — direct |
| `open(2)` | `FX_OPEN(0)` with `__strlen(path)` for path_len |
| `close(3)` | `FX_CLOSE(4)` — direct |
| `stat(4)` | `FX_OPEN` + `FX_STAT` + `FX_CLOSE`, struct translation |
| `mmap(9)` | `FX_MMAP(32)` — anonymous only |
| `brk(12)` | `FX_BRK(16)` — direct |
| `arch_prctl(158)` | `FX_ARCH_PRCTL(36)` — TLS setup |
| `readv(19)` | Loop of `FX_READ` over iovecs (musl `fread` uses this) |
| `writev(20)` | Loop of `FX_WRITE` over iovecs |
| `exit_group(231)` | `FX_EXIT(14)` |

Some translations are non-trivial:
- **Path syscalls**: Fornax takes `(path_ptr, path_len)` pairs; Linux uses
  null-terminated strings. The shim calls `__strlen()` to compute the length.
- **stat**: Linux stat is 144 bytes with different field layout. The shim opens
  the file, calls Fornax's 32-byte stat, translates fields, then closes.
- **open flags**: `O_CREAT` routes to `FX_CREATE`, `O_TRUNC` does open + truncate.
- **Unsupported**: `fork`, `signal`, `socket` return `-ENOSYS`. Signals are
  stubbed as no-ops.

**`lib/posix/crt0.S`** — The realm entry point and musl bootstrap. Does three
things:

1. **Isolates the namespace** via `rfork(RFNAMEG)` — the Plan 9 way of saying
   "give this process its own mount table". This is the realm boundary.
2. **Builds a Linux-style stack** from Fornax's memory layout. Fornax stores
   argc/argv at `ARGV_BASE` and auxiliary vector at `AUXV_BASE`. crt0 pushes
   these onto the stack in the format musl expects:
   `[argc][argv0]...[argvN][NULL][envp_NULL][auxv...][AT_NULL]`
3. **Calls `__libc_start_main`** which initializes musl (TLS, stdio, atexit)
   and then calls `main()`.

### The Auxiliary Vector

musl needs an ELF auxiliary vector (auxv) to initialize Thread-Local Storage
(TLS). Without TLS, even `errno` doesn't work. The kernel writes the auxv into
the process's memory at `AUXV_BASE` (one page below `ARGV_BASE`) during spawn:

```
AT_PHDR   (3)  → in-memory address of ELF program headers
AT_PHNUM  (5)  → number of program headers
AT_PHENT  (4)  → size of each program header entry (56)
AT_ENTRY  (9)  → program entry point
AT_PAGESZ (6)  → 4096
AT_NULL   (0)  → terminator
```

musl's `__init_tls` reads `AT_PHDR`/`AT_PHNUM` to find the `PT_TLS` segment,
allocates TLS memory via `mmap`, and sets the thread pointer via
`arch_prctl(ARCH_SET_FS)`. The kernel saves/restores `FS_BASE` on every context
switch so TLS survives scheduling.

## Hello World: End-to-End Trace

Here's exactly what happens when you type `hello-posix` in the Fornax shell:

### 1. Shell spawns the process

fsh reads the ELF binary from `/bin/hello-posix`, calls `fx.spawn()`. The kernel
loads the ELF at `image_base = 0x40000000`, writes argv to `ARGV_BASE`, writes
auxv to `AUXV_BASE`, and sets the entry point to `_start` in crt0.S.

### 2. crt0.S runs (lib/posix/crt0.S)

```
_start:
    rfork(RFNAMEG)          → isolate namespace (realm boundary)
    load argc from ARGV_BASE
    push auxv onto stack    → AT_PHDR, AT_PHNUM, AT_PAGESZ, ...
    push envp NULL
    push argv pointers
    push argc
    call __libc_start_main(main, argc, argv, 0, 0, 0)
```

### 3. musl initializes

`__libc_start_main` does:
- `__init_tls`: reads auxv → finds PT_TLS → `mmap` allocates TLS block →
  `arch_prctl(ARCH_SET_FS)` sets the thread pointer

  *Syscall trace:*
  ```
  mmap(NULL, 4096, PROT_READ|PROT_WRITE, MAP_ANON|MAP_PRIVATE)
    → shim → FX_MMAP → kernel allocates page, maps at 0x4000_0000_0000
  arch_prctl(ARCH_SET_FS, 0x4000CB88)
    → shim → FX_ARCH_PRCTL → kernel sets FS_BASE MSR
  ```

- `__init_libc`: sets up stdio (stdin/stdout/stderr)
- `__libc_start_init`: calls `_init()` (our stub, no-op)
- Calls `main(argc, argv, envp)`

### 4. printf("Hello POSIX!\n")

`printf` → musl's `vfprintf` → formats the string → `__stdio_write` →
`writev(1, [{buf, 13}], 1)`:

```
Linux writev(1, iov, 1)
  → shim: LNX_WRITEV (20)
  → loop over iovecs: FX_WRITE(1, "Hello POSIX!\n", 13)
  → kernel: sysWrite(fd=1, buf, len=13)
  → console driver outputs to VGA + serial
```

The 13 bytes appear on screen: `Hello POSIX!`

### 5. return 0 → exit

`main` returns 0 → `__libc_start_main` calls `exit(0)` → `__stdio_exit`
flushes all FILE buffers → `exit_group(0)`:

```
Linux exit_group(0)
  → shim: LNX_EXIT_GROUP (231)
  → FX_EXIT(0)
  → kernel: sysExit(0), process terminated
```

Shell receives exit status 0, prints the next prompt.

### Complete Syscall Trace

```
rfork(RFNAMEG)              crt0.S       namespace isolation
mmap(4096)                  __init_tls   TLS allocation
arch_prctl(SET_FS, addr)    __init_tls   thread pointer setup
mmap(4096)                  stdio init   stdout buffer
writev(1, "Hello POSIX!")   printf       actual output
exit_group(0)               exit         process termination
```

Six syscalls total. Every one goes through the shim. The kernel never sees a
Linux syscall number.

## Build System

All POSIX/C support is gated behind `-Dposix=true`:

```
zig build x86_64 -Dposix=true     # or: make run-posix
```

Without `-Dposix`, no C code is compiled, no musl is fetched, and the kernel
binary is identical. Zero overhead when disabled.

### musl as a Lazy Dependency

musl is declared in `build.zig.zon` as a lazy dependency:

```zig
.musl = .{
    .url = "https://musl.libc.org/releases/musl-1.2.5.tar.gz",
    .hash = "...",
    .lazy = true,
},
```

It's only fetched on first `-Dposix=true` build, then cached in `~/.cache/zig/`.
Not vendored in the repo.

### How POSIX Programs Are Built

```
hello-posix.c
    + lib/posix/crt0.S              (realm entry + musl bootstrap)
    + libfornax-posix.a             (musl sources + shim.c)
    + -fno-sanitize=all             (disable LLVM CFI)
    + image_base = 0x40000000       (standard Fornax user address)
    → ELF binary at zig-out/rootfs/bin/hello-posix
```

The overlay directory (`lib/posix/overlay/`) is included with highest priority
so its `syscall_arch.h` shadows musl's built-in version, redirecting all syscalls
through the shim.

## File Map

```
lib/c/fornax.h                     Native C syscall header (Tier 1)
lib/c/crt0.S                       Native C entry point (Tier 1)
lib/posix/shim.c                   Linux → Fornax syscall translation
lib/posix/crt0.S                   POSIX realm entry + musl bootstrap
lib/posix/overlay/syscall_arch.h   Redirects musl __syscall → shim
lib/posix/overlay/bits/alltypes.h  Fornax type overrides
lib/posix/overlay/bits/syscall.h   Generated syscall number stubs
cmd/hello-c/main.c                 Native C test program
cmd/hello-posix/main.c             POSIX test (printf)
cmd/cat-posix/main.c               POSIX test (fopen/fread/fwrite)
cmd/malloc-test/main.c             POSIX test (malloc/free/realloc)
src/syscall.zig                    Kernel: mmap/munmap/dup/dup2/arch_prctl
src/process.zig                    Kernel: mmap_next, fs_base fields
```

## Design Decisions

**Why not PT_INTERP?** The original plan used ELF PT_INTERP to load a
`posix-realm` loader. This was abandoned because Zig's lld doesn't emit
PT_INTERP for freestanding targets. Instead, realm isolation happens in crt0
via `rfork(RFNAMEG)` — simpler and equally effective.

**Why a shim instead of porting musl to Fornax natively?** musl is designed
around Linux syscalls. Porting it natively would mean modifying hundreds of
musl source files. The shim approach means zero changes to musl sources — all
translation happens in one ~580-line C file, and musl is used unmodified from
upstream.

**Why `-fno-sanitize=all`?** Zig's ReleaseSafe mode enables LLVM CFI
(Control Flow Integrity) for C code. musl calls `main` with signature
`int(*)(int, char**, char**)` (3 args including envp), but programs typically
declare `int main(int, char**)` (2 args). The CFI type hash mismatch causes
a `ud1l` trap. Disabling sanitizers for the musl/POSIX build avoids this.

**Why static linking only?** Fornax has no dynamic linker. All musl code is
compiled into `libfornax-posix.a` and linked statically into each POSIX binary.
This is consistent with Fornax's native Zig programs which are also statically
linked.
