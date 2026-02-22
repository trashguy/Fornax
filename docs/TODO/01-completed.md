# Completed Phases

| Phase | Description |
|-------|-------------|
| 1-6 | UEFI boot, GOP framebuffer, console, PMM, GDT, IDT |
| 7 | Kernel heap (bump allocator) + serial console (COM1) |
| 8 | Virtual memory / 4-level paging + higher-half kernel |
| 9 | IPC foundation (synchronous channels, 9P message tags) |
| 10 | Process model + user mode + SYSCALL/SYSRET + ELF loader |
| 11 | Per-process namespaces (mount tables, longest-prefix match) |
| 12 | Console file server (first userspace driver) |
| 13 | Fault supervisor (basic crash recovery + restart) |
| 14 | Container primitives + OCI import tool |
| 15 | PCI enumeration + virtio-net NIC driver |
| 16 | IP stack: Ethernet + ARP + IPv4 + UDP + ICMP |
| 17 | `spawn` syscall (create child process from userspace) |
| 18 | `exec` syscall (replace current process image) |
| 19 | `wait`/`exit` lifecycle (parent-child, reaping, orphan kill) |
| 20 | Initrd (FXINITRD flat namespace image, UEFI-loaded) |
| 21 | Init process (PID 1, kernel-backed /boot/, SMF-style wait) |
| 22 | Ramfs (in-memory filesystem server, userspace) |
| 23 | TTY / interactive console (keyboard input) |
| 24 | Shell (fsh — Fornax shell, builtins + spawn) |
| 100 | TCP (full connection lifecycle, `/net/tcp` file interface) |
| 101 | DNS resolver (`/net/dns` file server) |
| — | Pipes, core utilities (echo, cat, ls, rm, mkdir, wc), shell enhancements |
| 150 | Login / getty, users, groups, /etc/passwd, su |
| 200 | Kernel `/proc` file tree (process info, meminfo, kill via ctl) |
| 201 | `seek` + `getpid` syscalls |
| 203 | Text processing (grep, sed, awk, less) |
| 204 | Process & system management (ps, kill, du, top) |
| 205 | Shell enhancements (if/while/for, `&&`/`||`, test, `#` comments) |
| 206 | Permissions + wstat (chmod/chown/chgrp, uid/gid, `ls -l`) |
| 210 | ANSI console + fe editor (CSI state machine, vi-like editor) |
| 215 | Virtual consoles (4 VTs, Alt+F1-F4, per-VT state) |
| 300-305 | fxfs filesystem, GPT partitions, virtio-blk, pread/pwrite |
| 306-313 | fxfs feature-complete (B-tree splitting, multi-extent, rename, truncate, timestamps, multi-block bitmap, CRC32, virtual devices, dd) |
| 400-405 | xHCI USB (keyboard + mouse, PCI MMIO, boot protocol) |
| A-G | SMP (ticket spinlocks, per-CPU state, AP startup, run queues, work stealing, TLB shootdown) |
| H-K | Kernel threads (clone, futex, thread groups, POSIX pthread support) |
| 1000 | C/POSIX realms (native C via fornax.h, musl libc + syscall shim) |
| 1001a-d,l | Foundation libraries (crc32, sha256, deflate, tar, json, http) |
| 1001i | TCC cross-compiled as POSIX program |
| 1002 | Container system (fnx CLI, Containerfile, Linux compat, bridge + NAT) |
| 3A-3D | Userspace networking (netd, per-realm stacks, /dev/ether0, bridge server) |

## Milestones Reached

| # | Goal | Phases |
|---|------|--------|
| 1 | Hello world from Ring 3 | 7-10 |
| 2 | Hello world via IPC to console file server | 12 |
| 3 | Crash a file server, kernel restarts it | 13 |
| 4 | Run a container with namespace isolation | 14 |
| 5 | Ping reply from Fornax | 15-16 |
| 6 | Two Fornax instances exchange UDP | 16 |
| 7 | Userspace spawns a child process | 17 |
| 8 | Init process boots the system from userspace | 21 |
| 8.5 | Ramfs serves files, init creates/reads/writes via IPC | 22 |
| 9 | Interactive shell prompt | 24 |
| 10 | TCP connection to/from Fornax | 100 |
| 11 | Login prompt with user authentication | 150 |
| 12 | Multi-core boot with SMP scheduling | A-G |
| 13 | CoW filesystem with B-tree persistent storage | 300-313 |
| 14 | Container runs with Linux binary compat | 1002 |
| 15 | C program compiled and run on Fornax | 1000 |
| 16 | Userspace TCP/IP stack serves per-realm networking | 3A-3D |
