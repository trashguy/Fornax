# AArch64 Memory Gotchas

Hard-won lessons from debugging aarch64-specific memory corruption.
These do not affect x86_64 (single CR3 page table, strong memory ordering).

---

## 1. TTBR0/TTBR1 Split and VA Aliasing

AArch64 uses two page table base registers:
- **TTBR1**: higher-half (`0xFFFF_8000_0000_0000+`), never changes — kernel space.
- **TTBR0**: lower-half (`0x0000_...`), changes on every context switch — user space.

After `scheduleNext()` switches TTBR0, any lower-half VA that was identity-mapped
to a physical page now maps to the new process's user pages instead.

### Rule: All kernel pointers must go through `paging.physPtr()`

`paging.physPtr()` adds `KERNEL_VIRT_BASE` once paging is initialized, returning
a TTBR1 higher-half pointer that survives context switches.

**Wrong:**
```zig
const ptr: [*]u8 = @ptrFromInt(pmm.allocPage());
```

**Right:**
```zig
const ptr: [*]u8 = paging.physPtr(pmm.allocPage());
```

This applies to: DMA descriptor rings, command tables, shared buffers — anything
the kernel accesses after a potential context switch.

x86_64 and riscv64 use a single page table register (CR3/SATP) where the kernel
higher-half is always present in every process's page table, so this bug class
doesn't manifest there.

---

## 2. Cache Coherency for DMA (dc cvac / dc ivac)

AArch64 has a weakly-ordered memory model. CPU caches are not automatically
coherent with device DMA on QEMU TCG (softmmu TLB). After writing to a DMA
buffer, you must clean the cache line to Point of Coherency (PoC):

```zig
if (comptime @import("builtin").cpu.arch == .aarch64) {
    asm volatile ("dc cvac, %[addr]" : : [addr] "r" (va));
    asm volatile ("dsb sy" ::: .{ .memory = true });
}
```

- **dc cvac**: Clean by VA to PoC — pushes dirty cache line to main memory.
- **dc ivac**: Invalidate by VA to PoC — discards cached copy so next read fetches from memory.
- **dsb sy**: Data synchronization barrier — ensures the clean/invalidate completes.

### When to use:
- **CPU writes, device reads** (e.g. descriptor ring, SQ entry): `dc cvac` after write.
- **Device writes, CPU reads** (e.g. completion queue, used ring): `dc ivac` before read.

### Where this matters:
- Virtio descriptor table writes (`addBuffer`, `addBufferChain3`, `recycleDesc`)
- Virtio available ring index updates
- NVMe submission queue entries
- AHCI command headers and PRDT entries

---

## 3. Memory Barriers Before Doorbells

On weakly-ordered architectures (aarch64, riscv64), a memory barrier is required
between writing a command/descriptor to RAM and writing the doorbell/notification
MMIO register. Without it, the device may see stale data.

```zig
// Write command to memory
dest.* = cmd.*;

// Barrier ensures writes are visible before doorbell
if (comptime @import("builtin").cpu.arch == .aarch64) {
    asm volatile ("dsb sy" ::: .{ .memory = true });
} else if (comptime @import("builtin").cpu.arch == .riscv64) {
    asm volatile ("fence rw, rw" ::: .{ .memory = true });
}

// Now ring the doorbell
mmioWrite32(doorbell_addr, value);
```

x86_64 has strong ordering (stores are visible in program order to MMIO), so this
is less critical there, but `mfence` is still used in virtio for correctness.

---

## 4. Volatile Access for Device-Visible Structures

Descriptor table fields, available ring indices, and used ring entries must be
accessed through `*volatile` pointers. Without volatile, the Zig/LLVM compiler
may:
- Reorder writes past the doorbell
- Elide writes it considers redundant
- Merge multiple writes into one

```zig
// Wrong: compiler may optimize away
vq.desc[idx].len = len;

// Right: volatile prevents optimization
const desc: *volatile VirtqDesc = @ptrCast(&vq.desc[idx]);
desc.len = len;
```

---

## 5. Zig 0.15 / LLVM AArch64 Stack-Slot Reuse

The LLVM aarch64 backend in Zig 0.15 has a bug where it reuses stack slots of
live variables for large `= undefined` array initialization (which memsets to
0xAA). This clobbers other live locals that share overlapping stack slots.

### Symptoms:
- Local arrays contain 0xAA bytes that were never written
- Variables change value "spontaneously" between uses
- Only manifests on aarch64, not x86_64 or riscv64

### Trigger conditions:
- Function has 2+ large arrays (`[4096]u8` or similar) as locals
- Arrays initialized with `= undefined`
- Arrays are live simultaneously (overlapping lifetimes)

### Fix: Move large arrays to BSS globals

```zig
// Wrong: two large stack arrays, LLVM may overlap their slots
fn process() void {
    var buf_a: [4096]u8 = undefined;
    var buf_b: [4096]u8 = undefined;
    // ... use both ...
}

// Right: BSS globals avoid stack-slot reuse
var buf_a: [4096]u8 linksection(".bss") = undefined;
var buf_b: [4096]u8 linksection(".bss") = undefined;
fn process() void {
    // ... use both ...
}
```

### Known affected locations (fixed):
- `cmd/fnx/main.zig:cmdPull()` — layer_digests, handles, etc. moved to BSS

### Audit checklist:
- `srv/fxfs/main.zig:btreeInsert()` — 3x `[4096]u8` arrays (12KB)
- `cmd/awk/main.zig:awkFd()` — 2x `[4096]u8` arrays (8KB)
- Any function with multiple large `= undefined` locals on aarch64
