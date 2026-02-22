# Phase G0: PCI Enhancement

## Status: Planning

## Summary

Extend PCI subsystem with BAR size probing, multi-bus enumeration, multi-function device scan, and PCI capabilities list traversal (including MSI-X capability parsing).

## Motivation

Current PCI code (`src/arch/x86_64/pci.zig`) only scans bus 0 single-function devices, cannot determine BAR sizes, and has no capabilities list support. GPU drivers require all of these: BAR sizes for MMIO/VRAM mapping, multi-bus for devices behind PCI bridges, and capabilities for MSI-X interrupt delivery.

## Current State

- `configRead(bus, slot, func, offset)` / `configWrite()` — working
- 64-bit BAR detection — working
- `enableBusMastering()` — working
- Bus 0 only, no multi-function scan, no capabilities

## Implementation

### BAR Size Probing

Determine the size of each BAR by writing all-ones and reading back:

```
1. Save original BAR value
2. Write 0xFFFFFFFF to BAR
3. Read back — set bits indicate size (invert + add 1 for size in bytes)
4. Restore original BAR value
5. For 64-bit BARs, probe upper 32 bits too
```

Add `probeBarSize(bus, slot, func, bar_index) -> u64` to pci.zig.

### Multi-Bus Enumeration

Follow PCI bridge secondary bus numbers:
- Check header type (offset 0x0E): bit 0 = bridge
- For bridges: read secondary bus number (offset 0x19)
- Recursively enumerate secondary bus
- Depth limit of 8 to prevent infinite loops

### Multi-Function Device Scan

- Check header type bit 7 on function 0
- If set, scan functions 0-7
- Otherwise, only function 0 exists

### PCI Capabilities List

Walk the capabilities linked list:
- Check status register bit 4 (capabilities list present)
- Read capabilities pointer at offset 0x34
- Walk linked list: each entry has `cap_id` (1 byte) + `next_ptr` (1 byte)
- Return capability offset for a given cap ID

Add `findCapability(bus, slot, func, cap_id) -> ?u8` to pci.zig.

### MSI-X Capability Parsing

Cap ID 0x11. Structure at capability offset:
- +0x00: Cap ID (0x11) + Next
- +0x02: Message Control (table size, function mask, enable)
- +0x04: Table Offset/BIR (BAR indicator register for MSI-X table)
- +0x08: PBA Offset/BIR (pending bit array location)

Add `MsixCapability` struct and `parseMsixCap(bus, slot, func, cap_offset) -> MsixCapability`.

### Helper Function

Add `findByClass(class, subclass, prog_if) -> ?PciDevice` that scans all buses/slots/functions matching a class code. Used by GPU server to find display controllers (class 0x03).

## Files Modified

- `src/arch/x86_64/pci.zig` — all changes

## Testing

- `lspci` output shows BAR sizes for each device
- Multi-bus devices visible (if present in QEMU config)
- Capability lists shown in verbose `lspci` output
- MSI-X table size reported for devices that support it (e.g., virtio)

## Dependencies

None — standalone enhancement.

## Estimated Size

~200-300 lines added to pci.zig.
