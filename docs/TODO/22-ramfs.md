# Phase 22: Ramfs (In-Memory Filesystem Server)

## Goal

A userspace filesystem server that holds files in memory. This is the first
"real" filesystem — programs can create, read, write, and delete files
through the standard namespace/IPC mechanism.

## Decision Points (discuss before implementing)

- **Backed by initrd or independent?** Options:
  1. Ramfs starts empty, init populates it by copying from initrd
  2. Ramfs IS the initrd — it wraps the initrd data and serves it read-only,
     with a writable overlay for new files
  3. Two separate servers: initrd server (read-only) + ramfs (read-write),
     union-mounted
- **Directory support**: Do we need mkdir/readdir from the start, or just flat
  files?
- **9P protocol**: The IPC messages already use 9P-style tags. Should ramfs
  speak full 9P2000 internally? This would make it compatible with remote
  namespace import later (Phase 28).

## Interface

```
/              (ramfs mount point)
├── bin/
│   ├── init
│   ├── sh
│   └── hello
├── dev/
│   └── console → (mounted by console server)
├── etc/
│   └── init.conf
└── tmp/
```

## Verify

1. Ramfs serves files from memory
2. `open("/bin/hello")` → IPC to ramfs → returns ELF bytes
3. `write` to create new files in `/tmp`
4. `readdir` to list directory contents
