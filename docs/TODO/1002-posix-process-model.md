# Phase 1002: POSIX Process Model — `rfork(RFPROC)` + Enhanced `wait()`

## Overview

Extend Fornax's `rfork()` syscall (SYS 11) with Plan 9-style process creation flags, enabling POSIX `fork()`/`exec()`/`waitpid()` in the shim layer. This unlocks GCC, GNU make, and the entire class of POSIX programs that spawn child processes.

The kernel stays Plan 9-pure: `rfork(flags)` is a single flexible primitive. POSIX `fork()` is just one configuration of it, translated entirely in `lib/posix/shim.c`.

## Plan 9 rfork Flags

```
RFPROC   (0x01)  — create a new process
RFFDG    (0x02)  — copy file descriptor table to child
RFCFDG   (0x04)  — child gets clean (empty) fd table
RFNAMEG  (0x08)  — new namespace group (already implemented)
RFMEM    (0x10)  — share memory with parent (thread-like)
RFNOWAIT (0x20)  — child won't be waited on (auto-reap)
```

Note: `RFNAMEG` moves from `0x01` to `0x08` to fit the full flag set. The POSIX `crt0.S` and shim use the constant from `lib/syscall.zig`, so only one place to update.

### Flag Combinations

```
rfork(RFPROC | RFFDG)             →  fork()    (new process, copy fds, copy memory)
rfork(RFPROC | RFFDG | RFMEM)    →  vfork()   (new process, share memory — cheap, child must exec())
rfork(RFPROC | RFCFDG)           →  daemon()  (new process, no inherited fds)
rfork(RFNAMEG)                   →  existing behavior (namespace isolation, no new process)
```

## Kernel Changes

### 1. Extend `sysRfork()` in `src/syscall.zig`

Currently handles only `RFNAMEG`. Extend to handle `RFPROC`:

```
sysRfork(flags):
  if flags & RFPROC:
    child = process.create()         // allocate slot, kernel stack
    if flags & RFMEM:
      child.pml4 = parent.pml4       // share address space (vfork)
    else:
      child.pml4 = deepCopyAddressSpace(parent.pml4)  // full copy

    // Copy or clean fd table
    if flags & RFFDG:
      copyFdTable(parent, child)     // copy fds + increment pipe/ipc refcounts
    else if flags & RFCFDG:
      child.fds = all null           // clean slate
    else:
      copyFdTable(parent, child)     // default: copy (Plan 9 convention)

    // Inherit process state
    child.user_rip = parent.user_rip
    child.user_rsp = parent.user_rsp
    child.user_rflags = parent.user_rflags
    child.brk = parent.brk
    child.mmap_next = parent.mmap_next
    child.fs_base = parent.fs_base
    child.uid = parent.uid
    child.gid = parent.gid
    child.vt = parent.vt
    child.parent_pid = parent.pid

    // Namespace
    if flags & RFNAMEG:
      child.ns = fresh namespace
    else:
      parent.getNs().cloneInto(&child.ns)

    // Return: parent gets child pid, child gets 0
    child.syscall_ret = 0            // child sees 0
    markReady(child)
    return child.pid                 // parent sees child pid

  if flags & RFNAMEG:
    // existing namespace isolation (no RFPROC = modify current process)
    ...
```

### 2. `deepCopyAddressSpace()` in `src/arch/x86_64/paging.zig`

New function that deep-copies the entire user half of the address space (PML4 entries 0-255). The kernel half (256-511) is shared as usual.

```
deepCopyAddressSpace(src_pml4) -> ?*PageTable:
  new_pml4 = createAddressSpace()     // already copies kernel half + identity map

  // Walk PML4 entries 1-255 (entry 0 already handled by createAddressSpace)
  for each PML4 entry 1..256:
    if src has PDPT:
      new_pdpt = alloc + copy
      for each PDPT entry:
        if src has PD:
          new_pd = alloc + copy
          for each PD entry:
            if 2MB huge page:
              // allocate 512 pages, copy content
              // or: just copy the PDE (shares physical page — read-only COW later)
              copy PDE as-is  // INITIAL: share physical pages
            if src has PT:
              new_pt = alloc + copy
              for each PT entry:
                if present:
                  alloc new page, copy 4KB content
                  update PTE to point to new page
```

**Initial implementation**: Full 4KB page copy (no COW). This is simple and correct. COW optimization can come later.

**Cost estimate**: A typical POSIX program uses ~200-800 KB of mapped pages (code + data + stack + heap). Deep copy allocates that much again. At 4KB per page, that's 50-200 page allocations + memcpy per fork. Acceptable for now.

### 3. Enhance `sysWait()` in `src/syscall.zig`

Current `sysWait()` already supports:
- Wait for specific pid or any child (`wait_pid` argument)
- Zombie reaping with `exit_status` return
- Blocking with `waiting_for_pid` field

What to add:
- **POSIX status encoding**: Exit status in bits 8-15, signal number in bits 0-7 (currently just raw exit code)
- **WNOHANG flag support**: Return 0 immediately if no zombie (bit 0 of flags argument)

New signature: `wait(pid, flags) -> status_or_pid`
- `pid > 0`: wait for specific child
- `pid == 0` or `pid == -1`: wait for any child
- Returns: `(child_pid << 32) | (exit_code << 8)` packed in u64
  - Upper 32 bits: reaped child's pid
  - Lower 32 bits: POSIX-style status word

### 4. `copyFdTable()` helper

Extract from `sysSpawn()`'s fd mapping loop into a reusable function:

```zig
fn copyFdTable(parent: *Process, child: *Process) void {
    const pipe_mod = @import("pipe.zig");
    const parent_fds = thread_group.getFdSlice(parent);
    for (0..MAX_FDS) |i| {
        if (parent_fds[i]) |fentry| {
            child.fds[i] = fentry;
            if (fentry.fd_type == .pipe) {
                if (fentry.pipe_is_read) pipe_mod.incrementReaders(fentry.pipe_id)
                else pipe_mod.incrementWriters(fentry.pipe_id);
            }
        }
    }
}
```

## POSIX Shim Changes (`lib/posix/shim.c`, behind `-Dposix=true`)

### Process lifecycle

```c
case LNX_FORK:       // 57
case LNX_VFORK:      // 58
    return __fx_raw1(FX_RFORK, RFPROC | RFFDG);

case LNX_EXECVE:     // 59
    // Translate execve(path, argv, envp) to Fornax exec
    // 1. Resolve path via /bin/ prefix if needed
    // 2. Marshal argv into Fornax wire format [argc:u32][total:u32][strings]
    // 3. Call FX_EXEC
    return __fx_execve(a1, a2, a3);

case LNX_WAIT4:      // 61
    // wait4(pid, &status, options, rusage)
    // Map to enhanced FX_WAIT(pid, flags)
    // Write POSIX status word to *status pointer
    return __fx_wait4(a1, a2, a3);
```

### Additional syscall translations

```c
case LNX_PIPE:       // 22
    // pipe(int pipefd[2])
    return __fx_pipe(a1);

case LNX_PIPE2:      // 293
    // pipe2(int pipefd[2], int flags) — ignore flags
    return __fx_pipe(a1);

case LNX_GETPPID:    // 110
    // Read parent pid — needs new kernel support or /proc/self/status parse
    return __fx_getppid();

case LNX_SETSID:     // 112
case LNX_SETPGID:    // 109
    return 0;  // no-op (no process groups yet)
```

### `__fx_execve()` implementation

```c
static long __fx_execve(long path_ptr, long argv_ptr, long envp_ptr) {
    const char *path = (const char *)path_ptr;
    size_t path_len = __strlen(path);

    // Build Fornax argv wire format from execve's char *argv[]
    char **argv = (char **)argv_ptr;
    // ... marshal into [argc:u32][total:u32][str0\0str1\0...]

    // Call FX_EXEC(path_ptr, path_len, argv_wire_ptr)
    return __fx_raw3(FX_EXEC, (long)path, path_len, (long)wire_buf);
}
```

### `__fx_pipe()` implementation

```c
static long __fx_pipe(long pipefd_ptr) {
    // Fornax pipe() writes [read_fd, write_fd] as two i32s
    // Linux pipe() writes [read_fd, write_fd] as two ints
    // Compatible layout — just pass through
    return __fx_raw1(FX_PIPE, pipefd_ptr);
}
```

### `__fx_wait4()` implementation

```c
static long __fx_wait4(long pid, long status_ptr, long options) {
    long flags = 0;
    if (options & 1) flags |= 1;  // WNOHANG

    long result = __fx_raw2(FX_WAIT, pid, flags);

    if (result > 0 && status_ptr) {
        // Extract POSIX status from packed result
        int *status = (int *)status_ptr;
        *status = (int)(result & 0xFFFFFFFF);  // lower 32 bits = status word
        return (long)(result >> 32);             // upper 32 bits = child pid
    }
    return result;
}
```

## Constant Updates

### `lib/syscall.zig` (userspace)

```zig
// rfork flags (Plan 9)
pub const RFPROC   = 0x01;  // create new process
pub const RFFDG    = 0x02;  // copy fd table
pub const RFCFDG   = 0x04;  // clean fd table
pub const RFNAMEG  = 0x08;  // new namespace group  (was 0x01)
pub const RFMEM    = 0x10;  // share memory
pub const RFNOWAIT = 0x20;  // auto-reap child
```

### `lib/posix/crt0.S`

```asm
.set RFNAMEG, 0x08    # was 0x01
```

### `lib/posix/shim.c`

```c
#define FX_RFORK    11
#define RFPROC      0x01
#define RFFDG       0x02
#define RFNAMEG     0x08
#define FX_PIPE     15
#define FX_EXEC     12
#define FX_WAIT     13
```

## Files Modified/Created

**Kernel (`src/`):**
- `src/syscall.zig` — extend `sysRfork()`, enhance `sysWait()`, add `copyFdTable()`
- `src/arch/x86_64/paging.zig` — add `deepCopyAddressSpace()`
- `src/arch/riscv64/paging.zig` — add `deepCopyAddressSpace()` (riscv64 equivalent)
- `src/process.zig` — export `copyFdTable()`, update RFNAMEG constant

**Userspace (`lib/`):**
- `lib/syscall.zig` — rfork flag constants (update RFNAMEG value)
- `lib/posix/shim.c` — add LNX_FORK, LNX_VFORK, LNX_EXECVE, LNX_WAIT4, LNX_PIPE, LNX_PIPE2, LNX_GETPPID
- `lib/posix/crt0.S` — update RFNAMEG constant

**No new files** — everything extends existing code.

## Implementation Order

| Step | Description | Effort |
|------|-------------|--------|
| 1 | Update rfork flag constants everywhere (RFNAMEG 0x01→0x08) | Small |
| 2 | `copyFdTable()` helper extracted from sysSpawn | Small |
| 3 | `deepCopyAddressSpace()` for x86_64 | Medium — the core work |
| 4 | `deepCopyAddressSpace()` for riscv64 | Medium |
| 5 | `sysRfork(RFPROC\|RFFDG)` kernel implementation | Medium |
| 6 | Enhanced `sysWait()` with POSIX status + WNOHANG | Small |
| 7 | POSIX shim: LNX_FORK, LNX_WAIT4, LNX_PIPE | Small |
| 8 | POSIX shim: LNX_EXECVE translation | Medium |
| 9 | Test: fork+exec+wait roundtrip in POSIX C program | Small |

Steps 1-2 are prerequisites. Step 3 is the bulk of the work. Steps 7-8 are behind `-Dposix=true`.

## Verification

1. **Native test**: Zig program calls `rfork(RFPROC | RFFDG)`, child writes to pipe, parent reads
2. **POSIX test**: C program does `fork()` → child `execve("/bin/echo", ...)` → parent `waitpid()`
3. **Multi-fork**: C program forks 4 children, each prints pid, parent waits for all
4. **Pipeline**: C program does `pipe()` + `fork()` + `dup2()` + `exec()` to build `ls | wc`
5. **GCC smoke test**: Cross-compile GCC, install via fay, compile `hello.c` on-device

## Future Optimizations (not in this phase)

- **Copy-on-Write (COW)**: Mark forked pages read-only, copy on page fault. Huge speedup for fork+exec pattern where most pages are never written.
- **`posix_spawn()` fast path**: For the common fork+exec case, skip the full address space copy entirely — allocate fresh and load ELF directly (like current `spawn()`).
- **RFENVG**: Per-process environment groups (Plan 9 style). Currently env is userspace-only (musl manages `environ`).

## Depends On

- Phase 1000 (POSIX realms) — complete
- Phases H-K (kernel threads / clone / futex) — complete
- Phase 1001 (fay package manager) — foundation libraries complete
