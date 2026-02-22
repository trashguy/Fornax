# Phase G1: IOAPIC + MSI-X

## Status: Planning

## Summary

Implement IOAPIC driver for routing PCI interrupts, MSI-X table configuration, dynamic LAPIC vector allocation, and legacy INTx disable when MSI-X is active.

## Motivation

GPU and other high-performance devices require MSI-X for efficient interrupt delivery. The current kernel uses only legacy 8259 PIC (16 IRQs). IOAPIC support is also needed as a foundation — MSI-X bypasses IOAPIC but IOAPIC is required for non-MSI devices and is the standard PCI interrupt routing mechanism.

## Current State

- MADT parsing in `apic.zig` discovers IOAPIC base address but ignores it
- `MADT_IO_APIC` constant exists but is not handled in `parseMadt()`
- LAPIC is initialized for SMP IPIs (vectors 253-255)
- 8259 PIC handles IRQs 0-15

## Implementation

### IOAPIC Driver (`src/arch/x86_64/ioapic.zig`)

New file:
- Map IOAPIC MMIO base (from MADT) into higher-half
- Read/write IOAPIC registers via indirect register access (IOREGSEL + IOWIN)
- `init()`: read IOAPIC version register, determine max redirection entries
- `routeIrq(gsi, vector, dest_apic_id, trigger, polarity)`: program redirection table entry
- `maskIrq(gsi)` / `unmaskIrq(gsi)`: set/clear mask bit in redirection entry
- Handle MADT interrupt source override entries (ISA IRQ remapping)

### Dynamic Vector Allocation

Add to `apic.zig` or new `vectors.zig`:
- Allocate LAPIC vectors from range 32-239 (0-31 reserved for exceptions, 240+ for IPIs)
- `allocVector() -> u8` — returns next free vector
- `freeVector(vec)` — returns vector to pool
- Track vector-to-handler mapping for dispatch in `interrupts.zig`

### MSI-X Configuration

Add to `pci.zig`:
- `enableMsix(dev, table_bar_virt, vector, dest_apic_id)`:
  1. Map MSI-X table BAR if not already mapped
  2. Write message address (0xFEE00000 | dest_apic_id << 12)
  3. Write message data (vector)
  4. Clear mask bit in MSI-X table entry
  5. Set enable bit in MSI-X message control register
  6. Disable legacy INTx in PCI command register (bit 10)
- Support multiple table entries (one per interrupt source)

### Integration with Interrupt Dispatch

Modify `interrupts.zig`:
- Registered MSI-X vectors dispatch to handler function pointers
- Handler sends EOI to LAPIC (not PIC)
- Generic handler table: `vector_handlers[256]: ?*const fn() void`

## Files

- New: `src/arch/x86_64/ioapic.zig` (~200 lines)
- Modified: `src/arch/x86_64/apic.zig` — vector allocation, MADT IOAPIC handling
- Modified: `src/arch/x86_64/pci.zig` — MSI-X enable/disable
- Modified: `src/arch/x86_64/interrupts.zig` — generic vector dispatch

## Testing

- Register MSI-X handler on a virtio device, trigger interrupt, verify vector delivery
- IOAPIC routes keyboard IRQ (GSI 1) correctly (replaces PIC routing)
- Dynamic vector allocation doesn't conflict with existing IPI vectors (253-255)

## Dependencies

- Phase G0 (PCI capabilities list — needed to find MSI-X capability)

## Estimated Size

~400-500 lines total across all files.
