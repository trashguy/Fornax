# Contributing to Fornax

## Prerequisites

- [Zig 0.15.x](https://ziglang.org/download/)
- [QEMU](https://www.qemu.org/) with OVMF firmware
- GNU Make

## Building and Running

```sh
make run          # build and boot x86_64, single core
make run-smp      # 4 cores
make run-riscv64  # riscv64 on QEMU virt
```

This builds everything (kernel + userspace + disk image) and launches QEMU.

## Submitting Changes

1. Fork the repo and create a branch from `master`
2. Make your changes
3. Test by booting with `make run` (and `make run-smp` if touching kernel code)
4. Open a pull request against `master`

Keep PRs focused — one feature or fix per PR.

## Code Style

- Run `zig fmt` before committing
- Follow existing patterns in the codebase
- Kernel code is in `src/`, userspace library in `lib/`, commands in `cmd/`, servers in `srv/`
- New devices and servers should expose Plan 9-style ctl files (see `docs/ctl.md`)

## Architecture Overview

Fornax is a microkernel. The kernel handles memory, scheduling, IPC, and namespaces.
Everything else — filesystems, networking, drivers — runs as userspace file servers.

Before diving in, read the [architecture docs](docs/architecture.md) to understand
how the pieces fit together.

## Areas for Contribution

Check the [open issues](https://github.com/trashguy/Fornax/issues) or look at
the [roadmap](docs/TODO/00-overview.md) for planned work. If you want to tackle
something not listed, open an issue first so we can discuss the approach.

## Questions

Open an issue. There are no stupid questions about a hobby OS.
