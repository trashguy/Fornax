# Code Cleanup

## Split Large Modules

The kernel has two files that have grown unwieldy:

### 1. `src/syscall.zig` (~4400 lines)
Currently contains all syscall handlers in a single massive switch statement.

**Recommendation:** Split by category:
- `src/syscall/fs.zig` - open, read, write, stat, seek, etc.
- `src/syscall/proc.zig` - fork, exec, wait, exit, getpid
- `src/syscall/mem.zig` - brk, mmap, munmap
- `src/syscall/net.zig` - socket, connect, listen
- `src/syscall.zig` - dispatcher/registry

### 2. `src/process.zig` (~1300 lines)
Contains process/thread management.

**Recommendation:** Consider splitting if it contains multiple distinct concerns (e.g., process creation vs scheduling vs lifecycle).

### Guidelines for Zig file sizes
- ~500 lines: Clean, easy to navigate
- ~1000 lines: Manageable
- ~1500+: Consider splitting

Zig's stdlib uses large files, but that's not a model to emulate for a codebase that needs long-term maintenance.

## Documentation

### Inline (Zig docs)
Use `///` doc comments on public functions and types. Generate via `zig docs`.

### Architecture Overview (Markdown)
Zig docs answer "what does this function do" but can't explain "how the pieces fit together."

Suggested docs:
- `docs/architecture.md` - overall kernel design
- `docs/ipc.md` - message passing protocol
- `docs/syscall-abi.md` - syscall interface
- `docs/namespaces.md` - mount/namespace semantics

### When to document
If you find yourself writing a comment thread to explain something, that's a signal it should be in the docs.

## Tracing and Debugging

Post-mortem crash analysis is limited with just panic output. Consider adding a lightweight in-memory trace buffer that captures:
- Last N events (syscalls, interrupts, context switches)
- Timestamp for each event
- Wrap-around ring buffer in a dedicated section

This helps debug issues that are hard to reproduce. Keep it minimal to avoid performance impact.

## fxfs Bugs

### Critical

1. **LRU Cache is broken** (`srv/fxfs/main.zig:178-193`)
   The `use_count` only increments but never decrements. Frequently accessed blocks have HIGHER counts and are LESS likely to be evicted — the opposite of LRU.

2. **Cache not invalidated on writes** (`srv/fxfs/main.zig:921-927`)
   `writeBlock` writes directly to disk but doesn't invalidate the cache. Subsequent reads return stale cached data.

3. **Append path creates file holes** (`srv/fxfs/main.zig:2186-2303`)
   When writing past EOF, `appendBlocks` creates extents without filling the gap — files have uninitialized blocks in hole regions.

4. **Truncate to zero doesn't commit** (`srv/fxfs/main.zig:2686`)
   `freeAllExtents` is called but no `commitTransaction()` — crash before next operation leaves inconsistent state.

5. **Bitmap not flushed on write failure in appendBlocks** (`srv/fxfs/main.zig:2019-2027`)
   If block allocation fails, allocated blocks are freed but bitmap was already marked — leaks blocks.

6. **No locking between fs_lock and handle_lock**
   `getHandle`/`allocHandle` don't acquire `fs_lock`, but they access shared state. Multiple workers can race.

### Design Issues

7. **Single-leaf tree root update bypasses transaction** (`srv/fxfs/main.zig:1449`)
   In `leafInsert` for single-leaf trees, `sb_tree_root = new_block` is set without going through CoW path — crash could leave uncommitted root.

8. **handleCreate has partial transaction state** (`srv/fxfs/main.zig:1972-1996`)
   Inode insert → dir_entry insert → commit. If crash after step 1 or 2 but before commit, orphaned inodes or dangling dir entries.

## SMP Bugs

### Critical

1. **APs never call scheduleNext()** (`src/arch/x86_64/apic.zig:378-383`)
   The AP idle loop is:
   ```zig
   while (true) {
       asm volatile ("sti");
       asm volatile ("hlt");
       asm volatile ("cli");
   }
   ```
   When `markReady()` sends `IPI_SCHEDULE` to a remote core, the AP wakes from `hlt` but then just loops back to `sti`/`hlt` — it **never** calls `scheduleNext()`. Scheduled processes are never executed.

   Fix: APs should call `scheduleNext()` after waking from `hlt`, or the IPI handler should invoke it.

### Documentation

2. **Docs incorrectly claim push/pop are lockless** (`docs/smp.md:123`)
   Docs say "push/pop — used by the owning core; no lock needed" but `percpu.zig:65-82` shows both acquire the lock. Lockless would be buggy here; fix the docs.

3. **Docs claim "no big kernel lock"**
   The fxfs server uses a single coarse-grained `fs_lock` protecting all filesystem state. Worth mentioning in docs.

## netd / Networking Multithreading

### Critical

1. **Blocking I/O while holding net_lock** (`srv/netd/main.zig:103-131`)
   `sendIpPacket()` can block on ARP lookup failure (sends ARP request and waits) and `fx.write()` while holding `net_lock`. This stalls the entire server.

2. **Timer thread holds net_lock too long** (`srv/netd/main.zig:1069-1082`)
   All IPC workers are blocked during the 55ms tick while `tcp_stack.tick()`, `dns_resolver.checkRetry()`, and `icmp_handler.checkTimeouts()` run.

3. **No locking on handle table** (`srv/netd/main.zig:64-87`)
   `allocHandle`, `freeHandle`, `getHandle` access the shared `handles` array without synchronization. Multiple IPC workers can race.

4. **Global IP config updated without lock** (`srv/netd/main.zig:867-876`)
   `our_ip`, `subnet_mask`, `gateway_ip` are written without holding `net_lock`. RX thread reads these globals while processing frames — inconsistent routing.

### Medium

5. **RX thread holds net_lock during slow operations** (`srv/netd/main.zig:1020-1055`)
   TCP/ICMP packet handling inside critical section blocks all IPC workers.

6. **ARP/ICMP replies sent while holding net_lock** (`srv/netd/main.zig:1023-1042`)
   `fx.write()` to ether device (blocking) inside the lock.

7. **Blocking poll without net_lock (TOCTOU)** (`srv/netd/main.zig:341-360`)
   Check for data, release lock, sleep — another worker could consume the data in between. Works by accident but is fragile.

## POSIX Realms / posix-realm

### Critical

1. **rfork failure not checked** (`lib/posix/crt0.S:21`)
   After `syscall` (rfork), code unconditionally jumps to program entry. If rfork fails, execution continues with undefined results.

2. **getdents64 not implemented** (`lib/posix/shim.c:740-741`)
   Returns `ENOSYS`. Directory listing (`ls`) won't work.

3. **No chdir support**
   Programs using `chdir()` will fail. `__cwd` is never updated, so `getcwd()` always returns "/".

### Medium

4. **exec buffer only 4MB** (`lib/posix/shim.c:353`)
   Larger ELF binaries cannot be executed.

5. **Signal handlers are stubs** (`lib/posix/shim.c:659-661`)
   Returns success but does nothing. Programs expecting signals silently fail.

6. **Clock returns uptime, not wall time** (`lib/posix/shim.c:686`)
   `clock_gettime` returns uptime, not real time.

7. **FD leak in stat error path** (`lib/posix/shim.c:484-489`)
   If `fstat` fails after opening, the fd is not closed.

8. **getrandom fallback insecure** (`lib/posix/shim.c:732`)
   Falls back to filling buffer with `0x42` — not random at all.

### Documentation

9. **Docs claim fork returns ENOSYS but it's implemented** (`docs/posix-realms.md:116`)
   `shim.c:618-620` implements fork via rfork.

10. **Docs don't mention getdents64 is missing**
    `ls` won't work but not documented.
