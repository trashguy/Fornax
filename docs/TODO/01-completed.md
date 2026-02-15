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
| 13 | Fault supervisor (VMS-style crash recovery) |
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
