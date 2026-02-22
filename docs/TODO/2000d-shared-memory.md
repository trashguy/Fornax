# Phase G3: Shared Memory

## Status: Planning

## Summary

Plan 9-style named shared memory segments: one process creates a segment (allocates physical pages, gets a handle), another process attaches (maps the same physical pages into its address space). Refcounted physical page tracking ensures cleanup.

## Motivation

GPU command submission requires zero-copy data sharing between Mesa clients and the GPU server. IPC is synchronous 4KB copy-based — unsuitable for bulk transfers (vertex buffers, textures, command buffers). Shared memory lets clients write commands directly to buffers the GPU server can submit to hardware.

## Design

### Segment Lifecycle

```
1. Server: seg_create("gpu-buf-42", 16 * PAGE_SIZE) -> handle
   - Kernel allocates 16 physical pages
   - Maps them into server's address space
   - Returns handle (small integer) + virtual address

2. Server: passes handle to client via IPC reply

3. Client: seg_attach(handle) -> virtual address
   - Kernel maps same physical pages into client's address space
   - Increments refcount

4. Either: seg_detach(virtual_address)
   - Unmaps from caller's address space
   - Decrements refcount
   - When refcount reaches 0, physical pages freed
```

### Syscalls

```
SYS_SEG_CREATE  (40): (size: u64) -> { handle: u32, addr: u64 }
SYS_SEG_ATTACH  (41): (handle: u32) -> addr: u64
SYS_SEG_DETACH  (42): (addr: u64) -> error
```

Handles are kernel-global small integers (like pipe IDs).

### Kernel Data Structure

```zig
const Segment = struct {
    pages: [MAX_SEG_PAGES]?PhysAddr,  // physical page addresses
    page_count: u16,
    refcount: u16,                     // number of attached processes
    creator_pid: u16,
    lock: SpinLock,
};

var segments: [MAX_SEGMENTS]?Segment = .{null} ** MAX_SEGMENTS;
var segments_lock: SpinLock = .{};
```

Constants:
- `MAX_SEGMENTS`: 64 (system-wide)
- `MAX_SEG_PAGES`: 256 (1 MB max per segment — sufficient for command buffers; VRAM uses device mmap)

### Process Tracking

Each process tracks its attached segments for cleanup on exit:

```zig
// In Process struct
seg_attachments: [MAX_SEG_ATTACH]SegAttach = .{.{}} ** MAX_SEG_ATTACH,

const SegAttach = struct {
    seg_id: u16 = 0,
    virt_addr: u64 = 0,
    active: bool = false,
};

const MAX_SEG_ATTACH = 8;  // max segments per process
```

### Cleanup

- `sysExit`: detach all segments (decrement refcounts, free if zero)
- Segment with refcount 0: all physical pages returned to PMM

### Security

- Any process can attach to a segment if it knows the handle
- Handles are only distributed via IPC — the server controls access
- Future: per-segment permission bits if needed

## Files

- New: `src/segment.zig` (~200 lines)
- Modified: `src/syscall.zig` — new syscall handlers
- Modified: `src/process.zig` — seg_attachments field, cleanup in sysExit
- Modified: `lib/fornax.zig` — userspace wrappers

## Testing

- Process A creates segment, writes data; Process B attaches, reads same data
- Detach decrements refcount; final detach frees pages
- Process exit cleans up all attached segments
- `cat /proc/meminfo` reflects segment page usage

## Dependencies

None — standalone, though GPU server (Phase G5) is the primary consumer.

## Estimated Size

~250-300 lines total.
