# Phase 22: Ramfs (In-Memory Filesystem Server) — DONE

## Goal

A userspace filesystem server that holds files in memory. This is the first
"real" filesystem — programs can create, read, write, and delete files
through the standard namespace/IPC mechanism.

## Decisions Made

- **Backed by initrd or independent?** Independent. Ramfs starts empty and
  runs as a standalone userspace server (PID 1). Init communicates with it
  via IPC to create/read/write files.
- **Directory support**: Flat namespace from the start. Paths like `/tmp/hello.txt`
  are supported via the namespace mount mechanism.
- **9P protocol**: Uses the existing 9P-style IPC message tags (open, read,
  write, create). Not full 9P2000 yet — can be extended for remote namespace
  import in Phase 201.

## Implementation

- `srv/ramfs/main.zig` — userspace ramfs server
  - Registers as a namespace server, listens on IPC channel
  - Handles `create`, `open`, `read`, `write` operations
  - Stores file data in memory
- `cmd/init/main.zig` — init process tests ramfs
  - Creates `/tmp/hello.txt`, writes data, reads it back
- `tools/mkinitrd.zig` — packs ramfs + init into FXINITRD image
- `src/initrd.zig` — kernel-side initrd parser, mounts files to `/boot/`
- `build.zig` — builds ramfs and init as userspace ELFs, packs into initrd

## Boot Sequence

```
Kernel boots → parses initrd → mounts /boot/ramfs, /boot/init
  → spawns ramfs (PID 1) → spawns init (PID 2)
  → init creates /tmp/hello.txt via IPC to ramfs
  → init writes "hello fornax!" → reads it back → verifies → exits
```

## Verified

1. Ramfs serves files from memory — **pass**
2. `create("/tmp/hello.txt")` → IPC to ramfs → returns fd — **pass**
3. `write` to create new files — **pass** (14 bytes written)
4. `read` returns correct data — **pass** (28 bytes read back: "hello fornax!")
5. Init exits cleanly with status 0 — **pass**
