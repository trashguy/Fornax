# Phase G4: IRQ Forwarding to Userspace

## Status: Planning

## Summary

Allow userspace processes to receive hardware interrupts via a file descriptor interface. A process opens `/dev/irq/N` (or receives an IRQ fd from the kernel), then `read()` blocks until the next interrupt arrives. `write()` acknowledges/masks the interrupt.

## Motivation

In a microkernel, device drivers run in userspace. The GPU server needs to know when the GPU completes a command (MSI-X interrupt). The kernel handles the actual interrupt (EOI, minimal bookkeeping) but must notify the userspace driver.

## Design

### File Descriptor Interface

```
FdType.dev_irq — new fd type

read(irq_fd, buf, len):
  - Blocks until an interrupt fires on this vector
  - Returns 4 bytes: interrupt count since last read
  - Uses existing PendingOp pattern (like pipe_read, net_read)

write(irq_fd, buf, len):
  - "mask" — mask the interrupt (stop delivery)
  - "unmask" — unmask the interrupt (resume delivery)
  - "ack" — explicit acknowledge (if needed beyond auto-EOI)
```

### Kernel IRQ State

```zig
const IrqForward = struct {
    vector: u8,            // LAPIC vector number
    waiter_pid: ?u16,      // process blocked on read()
    pending_count: u32,    // interrupts since last read
    masked: bool,
    lock: SpinLock,
};

var irq_forwards: [MAX_IRQ_FORWARDS]?IrqForward = .{null} ** MAX_IRQ_FORWARDS;
const MAX_IRQ_FORWARDS = 32;
```

### Interrupt Flow

```
1. Hardware fires MSI-X → LAPIC delivers vector N
2. Kernel ISR (entry.S → interrupts.zig):
   a. Look up irq_forwards[N]
   b. Increment pending_count
   c. If waiter_pid set: markReady(waiter_pid)
   d. Send EOI to LAPIC
3. Userspace driver wakes from read():
   a. Returns pending_count, resets to 0
   b. Driver processes completed work
```

### Allocation

GPU server (or any privileged driver) requests an IRQ fd:
- Option A: Open `/dev/irq/N` where N is the MSI-X vector (requires knowing vector)
- Option B: Kernel allocates vector + configures MSI-X, returns fd (preferred — keeps vector management in kernel)

Preferred approach (Option B):
```
SYS_IRQ_ALLOC (43): (pci_bus, pci_slot, pci_func, msix_entry) -> fd
```
Kernel allocates a LAPIC vector, programs the MSI-X table entry, creates the fd. Restricted to uid 0.

### Process Tracking

Add to FdEntry:
```zig
irq_forward_id: u8 = 0,  // index into irq_forwards[]
```

Cleanup on fd close / process exit: mask the interrupt, free the forward slot.

## Files

- Modified: `src/arch/x86_64/interrupts.zig` — IRQ forward dispatch in vector handlers
- Modified: `src/syscall.zig` — SYS_IRQ_ALLOC, read/write handlers for dev_irq
- Modified: `src/process.zig` — FdEntry.irq_forward_id, FdType.dev_irq
- Modified: `lib/fornax.zig` — userspace wrapper

## Testing

- Register MSI-X IRQ forward for a virtio device
- Userspace process blocks on read(), trigger device operation, verify wake + count
- Mask/unmask via write(), verify interrupt delivery stops/resumes
- Process exit cleans up IRQ forward

## Dependencies

- Phase G1 (IOAPIC + MSI-X — need MSI-X configuration)

## Estimated Size

~200-250 lines total.
