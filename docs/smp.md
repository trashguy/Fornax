# Fornax SMP Design

Symmetric multiprocessing support for x86_64, targeting up to 128 logical CPUs. The design uses per-core run queues with work stealing, fine-grained spinlocks, and IPI-based cross-core wakeup. There is no big kernel lock. The kernel detects cores dynamically via ACPI MADT at boot — no configuration required. Hyperthreaded/SMT threads are treated as independent logical CPUs.

## Architecture Overview

```
                     Shared Memory
    ┌─────────────────────────────────────────────┐
    │  processes[64]   pipes[32]   channels[256]  │
    │  page_bitmap     ipc state   kernel heap    │
    │     (spinlocked per-resource)               │
    └──────┬──────────────┬───────────────┬───────┘
           │              │               │
    ┌──────┴──────┐ ┌─────┴─────┐  ┌──────┴──────┐
    │   Core 0    │ │   Core 1  │  │   Core N    │
    │  ┌────────┐ │ │ ┌────────┐│  │ ┌────────┐  │
    │  │PerCpu  │ │ │ │PerCpu  ││  │ │PerCpu  │  │
    │  │RunQueue│ │ │ │RunQueue││  │ │RunQueue│  │
    │  │AsmState│ │ │ │AsmState││  │ │AsmState│  │
    │  └────────┘ │ │ └────────┘│  │ └────────┘  │
    │  GS_BASE ───┘ │ GS_BASE──┘  │ GS_BASE ──┘ │
    └───────────────┘└─────────────┘└─────────────┘
           │              │               │
           └──────── LAPIC IPIs ──────────┘
           (0xFE=schedule, 0xFD=TLB shootdown)
```

Each core has private state accessed via the GS segment register (x86_64) or hardcoded core 0 (riscv64, single-core for now). Shared kernel data structures are protected by per-resource spinlocks. Cross-core communication uses LAPIC inter-processor interrupts.

## Boot Sequence

### BSP (Bootstrap Processor) — Core 0

1. UEFI boot hands control to `main.zig`
2. PMM, heap, serial, console initialized (single-threaded, no locks needed yet)
3. `percpu.init()` — sets `cores_online = 1`, programs GS_BASE and KERNEL_GS_BASE MSRs to point at `asm_states[0]`
4. `arch.init()` — GDT, IDT, paging
5. `apic.init(rsdp)`:
   - Parses ACPI RSDP → XSDT → MADT to discover LAPIC IDs and core count
   - Initializes the BSP's Local APIC (enables, sets spurious vector 0xFF)
   - Calls `startAps()` to boot secondary cores

### AP (Application Processor) Startup

The AP boot sequence uses a real-mode trampoline at physical address 0x8000:

```
Physical 0x8000:
  ┌──────────────────────────────────────────────┐
  │ 16-bit real mode (0x00-0x42)                 │
  │   cli, zero segments, lgdt, enable PAE+LME   │
  │   load CR3, enable paging, far jmp to 64-bit │
  ├──────────────────────────────────────────────┤
  │ 64-bit long mode (0x50-0x72)                 │
  │   load data segments, set stack, call entry  │
  ├──────────────────────────────────────────────┤
  │ Temporary GDT (0x80-0x9D)                    │
  ├──────────────────────────────────────────────┤
  │ Data area (0xC0)                             │
  │   CR3 value, stack top, entry point          │
  └──────────────────────────────────────────────┘
```

For each AP:

1. BSP allocates a 16 KB kernel stack via PMM
2. BSP copies trampoline code to 0x8000, patches data area with the AP's CR3, stack, and entry point
3. BSP sends INIT-SIPI-SIPI to the target LAPIC ID
4. AP wakes in 16-bit real mode at 0x8000, transitions to 64-bit long mode
5. AP's `apEntry()` loads BSP's GDT/IDT, enables its LAPIC, sets GS_BASE/KERNEL_GS_BASE MSRs
6. AP increments `cores_online` atomically and enters the idle loop in `scheduleNext()`

APs are started sequentially with a synchronization flag (`ap_boot_done`) to avoid trampoline conflicts.

## Per-CPU State

Two structures per core:

### AsmState (extern struct, 40 bytes)

Accessed from `entry.S` via `%gs:offset` after `swapgs`. Fixed offsets for assembly code:

| Offset | Field | Purpose |
|--------|-------|---------|
| gs:0 | `kernel_stack_top` | Set by `switchTo()`, loaded by SYSCALL entry |
| gs:8 | `saved_user_rsp` | User RSP saved on SYSCALL entry |
| gs:16 | `saved_user_rip` | User RIP (from RCX on SYSCALL) |
| gs:24 | `saved_user_rflags` | User RFLAGS (from R11 on SYSCALL) |
| gs:32 | `saved_kernel_rsp` | Kernel RSP for resume after blocking |

GS_BASE points to `asm_states[core_id]`. On SYSCALL entry, `swapgs` loads GS_BASE from KERNEL_GS_BASE; on SYSRET, `swapgs` restores it. Both MSRs are set to the same value per core, so `swapgs` is effectively idempotent.

### PerCpu (Zig struct)

Higher-level per-core state:

| Field | Type | Purpose |
|-------|------|---------|
| `core_id` | u8 | Logical core ID (0 = BSP) |
| `current` | ?*anyopaque | Currently running process (cast via `process.getCurrent()`) |
| `run_queue` | RunQueue | 64-slot circular buffer of ready process indices |
| `idle_ticks` | u64 | Idle tick counter for load monitoring |
| `ipi_pending` | u8 | Bitmap of pending IPI types |
| `tlb_flush_pending` | bool | Set by TLB shootdown sender, cleared by IPI handler |

Accessed via `percpu.get()` which reads GS_BASE MSR to determine core ID.

## Run Queues

Each core has a 64-entry circular run queue storing process table indices (not PIDs).

```zig
pub const RunQueue = struct {
    entries: [64]u16,   // process table indices
    head: u32,          // consumer position
    tail: u32,          // producer position
    len: u32,           // current count
    lock: SpinLock,     // only used by work stealing
};
```

- **push/pop** — used by the owning core; no lock needed (single producer/consumer)
- **stealHalf** — used by idle cores to steal from busy cores; acquires victim's lock

Process table indices are computed from pointers: `(@intFromPtr(proc) - @intFromPtr(&processes[0])) / @sizeOf(Process)`. This avoids the PID-to-index mismatch (PIDs start at 1, array indices at 0).

## Scheduling

### markReady — The Universal Wakeup

Every wakeup in the kernel goes through `process.markReady(proc)`:

```zig
pub fn markReady(proc: *Process) void {
    proc.state = .ready;
    percpu_array[proc.assigned_core].run_queue.push(procIndex(proc));
    if (cores_online > 1 and proc.assigned_core != getCoreId()) {
        apic.sendIpi(lapic_ids[proc.assigned_core], IPI_SCHEDULE);
    }
}
```

This is called from 16 sites across 9 files:
- `pipe.zig` (4 sites) — reader/writer wake on data/space/close
- `syscall.zig` (4 sites) — IPC server/client wake, parent wake on waitpid/exit
- `timer.zig` (1 site) — sleep expiry
- `keyboard.zig` (1 site) — VT input ready
- `xhci.zig` (1 site) — USB mouse event
- `net/tcp.zig`, `net/dns.zig`, `net/icmp.zig` (3 sites) — network data ready

The pattern: set state, push to target core's run queue, IPI if remote. The IPI wakes the target from `hlt`, and the scheduler loop picks up the new work.

### scheduleNext — Per-Core Scheduler

Each core runs its own `scheduleNext()` loop:

```
scheduleNext():
  1. Re-enqueue current process if still running
  2. Pop from local run queue → switchTo
  3. If empty: try work stealing from other cores
  4. If still empty: check if any processes alive
     - BSP: poll network
     - All: sti + hlt (sleep until interrupt)
     - Non-BSP with no work: idle loop
  5. If no processes alive (BSP only): halt system
```

### Process Assignment

New processes are assigned to cores via `leastLoadedCore()`, which picks the online core with the shortest run queue. Kernel-spawned processes (partfs, fxfs, init) are pinned to core 0. This provides natural IPC locality — filesystem servers and their early clients share a core.

### Work Stealing

When a core's run queue is empty, it tries to steal half of another core's entries:

```
idle core:
  for each other core (round-robin from core+1):
    victim.lock.lock()
    steal = victim.len / 2
    move 'steal' entries from victim.head to self.tail
    victim.lock.unlock()
    update assigned_core for stolen processes
    break if stolen > 0
```

Work stealing uses the run queue's spinlock. Only the steal path acquires the lock — local push/pop are lockless. Stolen processes get their `assigned_core` updated so future `markReady()` calls target the new core.

## Locking

Fornax uses ticket spinlocks (FIFO fairness). The lock/unlock path:

```zig
pub fn lock(self: *SpinLock) void {
    const ticket = @atomicRmw(u32, &self.next, .Add, 1, .monotonic);
    while (@atomicLoad(u32, &self.serving, .acquire) != ticket) {
        cpu.spinHint();  // PAUSE on x86_64
    }
}

pub fn unlock(self: *SpinLock) void {
    @atomicStore(u32, &self.serving, self.serving +% 1, .release);
}
```

### Lock Inventory

| Resource | Lock | Granularity | Held During |
|----------|------|-------------|-------------|
| PMM bitmap | `pmm_lock` | Global | allocPage, freePage |
| Process table | `table_lock` | Global | slot allocation in create() |
| next_pid | atomic | N/A | @atomicRmw in create() |
| Pipe state | `pipe.lock` | Per-pipe (32 locks) | read, write, close, refcount |
| IPC channels | `channel.lock` | Per-channel (256 locks) | send, recv, reply, create, close |
| Run queues | `run_queue.lock` | Per-core (8 locks) | work stealing only |

### Lock Ordering

To prevent deadlock, locks are acquired in this order:

```
table_lock → pmm_lock → pipe.lock / channel.lock → run_queue.lock
```

No code path acquires these in reverse order. In practice, most paths only touch one lock at a time. The main multi-lock scenario is `create()` which acquires `table_lock` (briefly, to claim a slot), then later `pmm_lock` (via allocPage for address space and kernel stack).

### Early Boot Safety

The spinlock debug path calls `percpu.getCoreId()` which reads the GS_BASE MSR. Before `percpu.init()` sets GS_BASE (during heap/PMM init), this would crash. A guard checks `cores_online == 0` and returns core 0 for early boot.

## Inter-Processor Interrupts

Three IPI vectors via LAPIC:

| Vector | Name | Purpose |
|--------|------|---------|
| 0xFD (253) | TLB shootdown | Remote core flushes TLB (reloads CR3) |
| 0xFE (254) | Schedule | Wakes remote core from `hlt` to check run queue |
| 0xFF (255) | Spurious | APIC spurious vector, no action |

IPI dispatch is in the exception handler (`interrupts.zig`). Vectors 253-255 are checked first (before IRQ dispatch) and acknowledged via LAPIC EOI (not PIC EOI).

The schedule IPI doesn't need explicit handling — the `hlt` instruction in the idle loop returns on any interrupt, and the scheduler loop re-checks the run queue.

## TLB Shootdown

When a process's page tables are freed (`freeUserMemory`), stale TLB entries may exist on cores that previously ran the process.

Each process tracks a `cores_ran_on: u128` bitmap. When `switchTo()` runs a process on a core, it sets the corresponding bit. On page table teardown:

```
tlbShootdown(proc):
  for each bit set in proc.cores_ran_on:
    if (this core): reload CR3 locally
    else:
      set percpu[core].tlb_flush_pending = true
      send IPI 0xFD to that core's LAPIC
```

The IPI handler on the remote core:
```
vector 253 handler:
  if (tlb_flush_pending):
    mov cr3, rax; mov rax, cr3  // full TLB flush
    tlb_flush_pending = false
```

After the shootdown, `cores_ran_on` is cleared.

This is a conservative approach (full TLB flush, not targeted `invlpg`). It's sufficient because page table teardown is infrequent (process exit only). A targeted approach would be needed for fine-grained page-level operations like `munmap`.

## Memory Layout

### Per-Core Memory Overhead

| Structure | Per-Core | Total (128 cores) |
|-----------|----------|-------------------|
| AsmState | 40 bytes | 5 KB |
| PerCpu | ~520 bytes | ~65 KB |
| Kernel stack | 16 KB | 2 MB (only for booted cores) |
| TSS (x86_64) | 104 bytes | 13 KB |

MAX_CORES is set to 128 (`src/percpu.zig`). Static arrays (AsmState, PerCpu) live in BSS (~70 KB total) — zero cost in the binary since BSS is zero-initialized. Kernel stacks are allocated from PMM only for cores that actually boot, so on a 4-core machine only 64 KB of stack memory is used. AP trampoline uses physical 0x8000 (512 bytes, temporary).

### GS_BASE Setup

On x86_64, each core's GS_BASE and KERNEL_GS_BASE MSRs point to its `asm_states[core_id]` entry. The BSP sets this during `percpu.init()`. APs set it during `apEntry()`. Both MSRs are set to the same value, making `swapgs` effectively a no-op (kernel and user GS_BASE are the same).

## RISC-V Considerations

RISC-V SMP support is not yet implemented (single-core only). The design provisions for it:

- `getCoreId()` returns 0 on riscv64
- `markReady()` IPI path is gated on `cpu.arch == .x86_64`
- `tlbShootdown()` is a no-op on non-x86_64
- RISC-V will use SBI HSM `hart_start` instead of INIT-SIPI-SIPI
- Per-hart state via the TP (thread pointer) register instead of GS_BASE
- TLB flush via `sfence.vma` + SBI remote fence

## Observability

- `cat /proc/N/status` — shows `core N` field (assigned core)
- `ps` — CORE column in output
- Boot log shows MADT discovery and per-core online messages:
  ```
  MADT: LAPIC at 0xFEE00000
  MADT: Core 0 LAPIC ID=0
  MADT: Core 1 LAPIC ID=1
  SMP: Core 1 online (LAPIC 1)
  ```

## Testing

```sh
make run          # single core (default QEMU)
make run-smp      # 4 cores (-smp 4)

# Custom core count:
./scripts/run-x86_64.sh -smp 8
```

The kernel automatically detects core count from ACPI MADT and adapts. With `-smp 1`, APs are never started and all SMP code is effectively dead (IPI paths gated on `cores_online > 1`).
