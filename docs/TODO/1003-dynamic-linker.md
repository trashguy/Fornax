# Phase 1003: Dynamic Linker Support (ET_DYN / PIE)

## Problem

Fornax's ELF loader (`src/elf.zig`) only accepts `ET_EXEC` (statically linked, non-PIE) binaries. All standard Linux distribution binaries (Alpine, Debian, etc.) are dynamically linked (`ET_DYN`) and require a runtime linker (`ld-musl-x86_64.so.1` or `ld-linux-x86-64.so.2`).

This means `fnx run` cannot execute any unmodified Linux container image — they all fail with "ELF load failed" because `e_type != ET_EXEC`.

## Current Behavior

```
src/elf.zig:104:  if (header.e_type != ET_EXEC) return error.NotExecutable;
```

The loader detects `PT_INTERP` and stores the interpreter path in `result.interp_path`, but never acts on it. The spawn path catches the error and aborts.

## Required Changes

### 1. ELF loader: accept ET_DYN
- `src/elf.zig`: Allow `e_type == ET_DYN` (value 3) in addition to `ET_EXEC`
- For ET_DYN, apply a base address offset (e.g. 0x40000000) to all segment vaddrs since they're position-independent (start at 0)
- Handle `PT_GNU_RELRO`, `PT_GNU_STACK` program headers

### 2. Dynamic linker execution
- When `PT_INTERP` is present, load the interpreter ELF as well (it's usually a static ET_DYN at a fixed base)
- Set entry point to the interpreter's entry, not the main binary's
- Pass auxiliary vector (auxv) on the stack: `AT_PHDR`, `AT_PHENT`, `AT_PHNUM`, `AT_ENTRY`, `AT_BASE`, `AT_PAGESZ`
- The interpreter (musl's `ld.so` or glibc's `ld-linux.so`) handles relocations and jumps to the real entry

### 3. Process setup for dynamic linking
- `src/process.zig` / `src/syscall/proc_setup.zig`: Build initial stack with auxv entries
- Ensure the process address space has room for both the main binary and the interpreter
- The interpreter needs to be loaded from the container rootfs (e.g. `/lib/ld-musl-x86_64.so.1`)

### 4. Syscall support
- `mmap` with `MAP_FIXED` — the dynamic linker uses this to map shared libraries
- `mprotect` — to set page permissions after mapping
- `brk` — for heap allocation
- These may already be partially implemented in linux_compat; verify and extend

## Testing

- Run Alpine's dynamically-linked `/bin/busybox` in a container
- Run Alpine's `/usr/bin/iperf3` (dynamically linked against musl + libcrypto)
- Run Debian-based container images (glibc dynamic linker)

## Depends On

- Phase 1002 (containers) — done
- Phase 1000 (POSIX realms / linux_compat) — done

## Notes

- musl's dynamic linker is simpler than glibc's — start with musl/Alpine
- The auxiliary vector is the key interface between kernel and dynamic linker
- PIE (Position-Independent Executable) binaries are ET_DYN with an entry point — same loading path as shared libraries but with a main()
- Most modern Linux distros default to PIE, so this is essential for broad compatibility
