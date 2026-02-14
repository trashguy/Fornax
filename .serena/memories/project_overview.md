# Fornax Microkernel OS

## Purpose
Fornax is a microkernel operating system inspired by Plan 9 and L4, written in Zig. It targets x86_64 (primary) and aarch64 UEFI platforms.

## Tech Stack
- **Language:** Zig 0.15.2
- **Build:** `zig build x86_64` (or `aarch64`, or just `zig build` for both)
- **Run:** `make run` (QEMU x86_64)
- **Target:** Freestanding UEFI (PE format)

## Architecture
- `src/` — kernel code
  - `src/arch/x86_64/` — x86_64-specific (GDT, IDT, paging, syscall entry, PCI)
  - `src/arch/aarch64/` — aarch64 stub
  - `src/main.zig` — kernel entry point
  - `src/process.zig` — process management + scheduling
  - `src/syscall.zig` — syscall dispatch
  - `src/ipc.zig` — IPC channels
  - `src/namespace.zig` — Plan 9-style per-process namespaces
  - `src/supervisor.zig` — VMS-style fault supervisor
  - `src/container.zig` — container primitives
  - `src/elf.zig` — ELF loader
  - `src/pmm.zig` — physical memory manager
  - `src/heap.zig` — bump allocator
  - `src/console.zig` — framebuffer console
  - `src/serial.zig` — COM1 serial output
- `user/` — userspace programs
  - `user/fornax.zig` — syscall library
  - `user/hello.zig` — test program
  - `user/console_server.zig` — console file server
  - `user/oci_import.zig` — OCI import tool

## Key Design
- Plan 9-style namespaces and 9P IPC messages
- L4-style synchronous IPC with blocking rendezvous
- Cooperative scheduling (no preemption)
- User programs embedded as ELF in kernel binary
- `export var` globals for syscall entry/exit context

## Code Style
- No std library in kernel (freestanding)
- `serial.puts()` for debug, `console.puts()` for framebuffer output
- Arch-specific code behind `switch (@import("builtin").cpu.arch)` patterns
- `pub export var` for asm-accessible globals
