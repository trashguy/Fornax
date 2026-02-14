# Phase 1000: Language Support (C, C++, Go)

## Goal

Enable programs written in C, C++, and Go to run on Fornax — natively where
practical, in POSIX realms where not.

## Terminology: POSIX Realms vs Containers

These are two different things and should not be conflated.

**POSIX realm** — a process with POSIX shims mounted. Created automatically
by `posix-realm` when you exec a POSIX binary. Same lifetime as the process.
No image, no quotas, no management. This is just Plan 9 namespace customization
— every process can have its own mount table, and posix-realm sets one up
with musl/libposix/POSIX /dev. It's no more "special" than any process that
mounts different file servers.

**Container** — a managed, isolated environment with its own rootfs image,
resource quotas, lifecycle (create/start/stop/destroy), and potentially its
own init process. This is the Docker analog. Created explicitly by a container
manager. Persists independently of individual processes.

| | POSIX realm | Container |
|---|---|---|
| Created by | posix-realm (automatic via PT_INTERP) | Container manager (explicit) |
| Lifetime | Same as the process | Independent, survives restarts |
| Rootfs | Shares host's, with POSIX shims overlaid | Own rootfs from an image |
| Quotas | Inherits parent's | Own limits (memory, CPU, channels) |
| Has init | No, just one process | Can have its own PID 1 |
| Networking | Shares host /net | Can have isolated /net |
| Use case | `gcc main.c`, `python script.py` | Running nginx, postgres |
| Analogy | Setting LD_PRELOAD | Docker container |

## Approach

The kernel stays Plan 9-pure. Language support is layered on top:

### Level 1: Freestanding C (minimal effort)
- `zig cc` already works as a cross-compiler
- Write `lib/fornax.h` — C header wrapping Fornax syscall numbers
- No libc, programs call Fornax syscalls directly
- Enough for simple C utilities

### Level 2: Minimal libc
- Small libc (~2-3K lines) mapping to Fornax syscalls
- printf, malloc/free (via brk), string functions, file I/O
- `crt0.S` startup stub (_start → main → exit)
- Enough for real C programs without POSIX compat

### Level 3: musl port (full POSIX C)
- Port musl libc to Fornax — the `libposix` shim layer
- Main work: `syscall_arch.h` (~50 lines) + semantic translation
  (socket → open /net/tcp/clone, signals → notes, etc.)
- Once musl works, any standard C program compiles for Fornax
- This is the foundation for both POSIX realms and containers

### Level 4: C++ standard library
- libc++ (LLVM) or libstdc++ (GCC) on top of musl
- libunwind for exceptions, libc++abi for RTTI
- Static linking only (no dynamic linker needed initially)
- Mostly a build system exercise once musl works

### Level 5: Go
- **POSIX realm**: Go binaries compiled with GOOS=linux run with
  posix-realm via the musl/libposix shim. Needs threads, mmap, futex, epoll.
- **Containers**: Go daemons (web servers, etc.) run in full containers with
  their own rootfs and resource quotas.
- **Native (future)**: Fork GOOS=plan9 runtime backend — closest match since
  Fornax shares Plan 9's file-based /net, rfork, notes instead of signals.
- **TinyGo**: Smaller runtime, LLVM-based, easier to port natively. Feasible
  once Level 2 libc exists.
- **WASM**: Compile Go → WASM → run in wasm3/iwasm on Fornax. Sidesteps the
  runtime porting problem entirely.

## Dependencies

- Level 1: just needs working userspace (Phase 17+)
- Level 2: needs brk syscall or simple allocator
- Level 3: needs threads, mmap, signal-like mechanism (notes)
- Level 4: needs Level 3
- Level 5: needs Level 3 + posix-realm (POSIX realm) or containers

## Seamless Execution via ELF Interpreter

POSIX programs should be transparent to the user. Typing `gcc main.c && ./a.out`
at the Fornax shell should just work — no prefix, no manual setup.

### Chosen approach: PT_INTERP (ELF interpreter)

The ELF spec defines `PT_INTERP` — a header that tells the kernel "load this
program first, and let it load me." Linux uses this for its dynamic linker
(`/lib/ld-linux.so`). Fornax uses the same mechanism for POSIX realm setup.

**How it works:**

```
Native ELF:     no PT_INTERP
                → kernel loads and runs it directly

POSIX ELF:      PT_INTERP = /lib/posix-realm
                → kernel loads posix-realm (a native Fornax program)
                → posix-realm:
                    1. rfork(RFNAMEG)           new namespace (the realm)
                    2. mount musl, /dev, /proc   POSIX environment
                    3. load the real ELF binary
                    4. jump to entry point
                → on exit, realm is cleaned up
```

**Why this is clean:**

- **Detection is in the ELF itself.** The binary says "I need posix-realm"
  via PT_INTERP. No path conventions, no heuristics, no magic.
- **The kernel stays dumb.** It only needs PT_INTERP support — a standard ELF
  feature. No POSIX logic in the kernel.
- **All setup is in userspace.** `posix-realm` (native Fornax, in `cmd/`) is
  the single place where POSIX realm setup lives.
- **The shell knows nothing.** It calls exec("/bin/gcc"), kernel sees PT_INTERP,
  posix-realm handles the rest.
- **Union mount works naturally.** Native and POSIX binaries coexist in `/bin`.
- **Build-time, not runtime.** `-dynamic-linker /lib/posix-realm` set once
  when compiling POSIX programs.

### User Experience

```
fornax% ls              # native, no PT_INTERP → runs directly
fornax% gcc main.c      # PT_INTERP=/lib/posix-realm → POSIX realm
fornax% ./a.out         # PT_INTERP=/lib/posix-realm → POSIX realm
fornax% cat output.txt  # native → runs directly
```

Interactive/CLI POSIX programs run in **ephemeral realms** — created on exec,
destroyed on exit. Inherits cwd and stdio. Feels like a native command.

Long-running POSIX daemons run in **containers** — own rootfs, quotas, lifecycle,
managed by init or a container service.

### Kernel requirement

The ELF loader (`src/elf.zig`) needs to check for `PT_INTERP`. If present,
load the interpreter ELF instead and pass the original binary's path/fd to it.
Small addition to the existing loader — ~20-30 lines.

## Design Principle

Heavyweight runtimes (Go, Node, Python) belong in POSIX realms (for CLI use)
or containers (for daemons). Native Fornax programs should be Zig or
freestanding C — small, clean, speaking the kernel's native interface. The
realm boundary should be invisible to the user for interactive use.
