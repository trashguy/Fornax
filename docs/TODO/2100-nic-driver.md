# Phase 2100: RTL8125 NIC Driver (r8169) for fornax-nics

## Status: Planning

## Summary

Userspace RTL8125B 2.5GbE NIC driver, served via the existing `/dev/ether0` interface. Requires shared kernel device-driver primitives (2000a PCI enhancement, 2000c device-backed mmap), plus two new additions (DMA alloc, PCI config userspace access) and an ether "driver mode" that reverses data flow so a userspace NIC driver can sit below netd.

## Motivation

Host NIC is Realtek RTL8125B (PCI `10ec:8125`, rev 05). Linux uses `r8169`. The `fornax-nics` repo has an `r8169/` stub with `10EC:8125` in DEVICE_IDS. Drivers are userspace servers installed via `fay install r8169`, serving raw Ethernet frames at `/dev/etherN`.

The kernel's existing virtio-net provides networking in QEMU. A real hardware NIC driver validates the microkernel device-driver model on real hardware and proves the device-driver primitives work end-to-end.

## Shared Infrastructure: 2000-Series Primitives Enable NICs

The 2000a-e phases are general-purpose microkernel device-driver primitives, not GPU-specific:

| Phase | Primitive | NIC needs | GPU needs |
|-------|-----------|-----------|-----------|
| 2000a | PCI enhancement (BAR probe, capabilities) | BAR size, config access | Same |
| 2000b | IOAPIC + MSI-X | Future (interrupt-driven RX) | MSI-X for GPU completion |
| 2000c | Device-backed mmap (`mmap_device`) | Map RTL8125 MMIO BAR | Map GPU VRAM/MMIO |
| 2000d | Shared memory segments | Not needed for NIC | Zero-copy command buffers |
| 2000e | IRQ forwarding to userspace | Future (interrupt-driven RX) | GPU completion notification |

**Minimum viable NIC driver needs 2000a + 2000c + two additions (DMA alloc, PCI config userspace access).** 2000b/2000d/2000e are nice-to-have for NIC but not required for poll-based operation.

## Implementation Steps

### Step 1: Phase 2000a — PCI Enhancement (`src/arch/x86_64/pci.zig`)

See `docs/TODO/2000a-pci-enhancement.md` for full details. Key additions:

- `probeBarSize(bus, slot, func, bar_index) -> u64` — write 0xFFFFFFFF, read back, restore
- Multi-function device scan (header type bit 7 → scan functions 0-7)
- Multi-bus enumeration (follow PCI bridge secondary bus numbers)
- `findCapability(bus, slot, func, cap_id) -> ?u8` — walk capabilities linked list
- MSI-X capability parsing (`MsixCapability` struct)
- `findByClass(class, subclass, prog_if) -> ?PciDevice`

**Addition for NIC**: Userspace PCI config access syscall:
```
SYS_PCI_CFG (41): pci_cfg(bdf, offset, value, write) -> u64
```
- `bdf` = `(bus << 16 | slot << 8 | func)`, offset 4-byte aligned
- Wraps existing `pci.configRead()`/`pci.configWrite()`
- Root-only. Needed for userspace drivers to enable bus mastering, read BARs

**Files**: `src/arch/x86_64/pci.zig`, `src/syscall.zig`, `lib/syscall.zig`

### Step 2: Phase 2000c — Device-Backed mmap (`src/syscall.zig`, `src/arch/x86_64/paging.zig`)

See `docs/TODO/2000c-device-mmap.md` for full details. Key additions:

```
SYS_MMAP_DEVICE (42): mmap_device(phys_addr, size, flags) -> virt_addr
```
- Flags: `MMAP_NOCACHE` (0x1), `MMAP_WRITECOMBINE` (0x2), `MMAP_HUGEPAGE` (0x4)
- Maps physical MMIO range into caller's page tables at `proc.mmap_next`
- Root-only
- PAT initialization for write-combining (MSR 0x277)
- Per-process device mapping tracking for cleanup on exit

**Files**: `src/arch/x86_64/paging.zig`, `src/syscall.zig`, `src/process.zig`, `lib/syscall.zig`

### Step 3: DMA Allocation (addition to 2000c)

Not in the existing 2000c doc but needed for NIC/GPU descriptor rings:
```
SYS_DMA_ALLOC (43): dma_alloc(pages, result_ptr) -> virt_addr
```
- `pmm.allocContiguousPages(pages)` + map into userspace + write phys addr to `result_ptr`
- Root-only. Descriptor rings must be physically contiguous with known physical address.
- Small addition (~30 lines) alongside `mmap_device`

**Files**: `src/syscall.zig`, `lib/syscall.zig`

### Step 4: Ether Driver Mode (`src/ether.zig`)

A "driver" ether client reverses data flow — NIC driver sits below `/dev/ether0`:

**New fields on `EtherClient`:**
- `is_driver: bool`
- `tx_ring: [64][1518]u8` + `tx_frame_lens: [64]u16` + `tx_head/tx_count` (BSS)
- `tx_waiters: [4]?u16`

**New ctl command:** `"driver"` sets `is_driver = true`

**sysWrite routing** (`src/syscall.zig`):
- Driver writes → `ether.deliverFrame()` (RX: hardware → netd)
- Non-driver writes + driver exists → `ether.enqueueTx()` (TX: netd → hardware)
- No driver → fallback `virtio_net.send()` (backward compatible)

**sysRead for driver clients:** reads from TX ring (frames netd wants transmitted), blocks when empty

**Files**: `src/ether.zig`, `src/syscall.zig`

### Step 5: Shared NIC Library (`fornax-nics/lib/nic.zig`)

Thin wrappers over the new syscalls + PCI discovery logic:

```zig
// PCI device discovery (parse /dev/pci text + pci_cfg reads for BARs)
pub const PciDevice = struct { bdf: u32, vendor: u16, device: u16, bar: [6]u64, irq: u8 };
pub fn findDevice(vendor: u16, device: u16) ?PciDevice;
pub fn enableBusMastering(dev: *const PciDevice) void;

// MMIO (wraps mmap_device)
pub fn mapMmio(phys: u64, size: u64) ?[*]volatile u8;
pub fn mmioRead8/16/32(base: [*]volatile u8, off: u32) u8/u16/u32;
pub fn mmioWrite8/16/32(base: [*]volatile u8, off: u32, val: ...) void;

// DMA (wraps dma_alloc)
pub fn allocDma(pages: u32) ?struct { virt: [*]u8, phys: u64 };

// Ether interface
pub fn openEtherDriver() ?i64;  // open /dev/ether0, write "driver" ctl
```

**Files**: `fornax-nics/lib/nic.zig`

### Step 6: RTL8125 Driver (`fornax-nics/r8169/src/main.zig`)

**Register map** (MMIO offsets):

| Register | Offset | Width | Purpose |
|----------|--------|-------|---------|
| MAC0-5 | 0x00 | 8x6 | MAC address |
| ChipCmd | 0x37 | 8 | Reset(0x10), RxEnb(0x08), TxEnb(0x04) |
| IntrMask | 0x38 | 32 | Interrupt mask (RTL8125 32-bit) |
| TxDescAddrLo/Hi | 0x20/0x24 | 32 | TX descriptor ring phys addr |
| TxConfig | 0x40 | 32 | TX DMA/IFG config |
| RxConfig | 0x44 | 32 | RX filter/DMA config |
| Cfg9346 | 0x50 | 8 | Unlock(0xC0)/Lock(0x00) |
| PHYAR | 0x60 | 32 | PHY register access |
| PHYstatus | 0x6C | 32 | Link status |
| RxMaxSize | 0xDA | 16 | Max RX packet size |
| RxDescAddrLo/Hi | 0xE4/0xE8 | 32 | RX descriptor ring phys addr |

**Descriptor format** (16 bytes, 256 per ring):
```zig
const TxDesc = extern struct { opts1: u32, opts2: u32, addr_lo: u32, addr_hi: u32 };
const RxDesc = extern struct { opts1: u32, opts2: u32, addr_lo: u32, addr_hi: u32 };
// opts1 bits: OWN(31), EOR(30), FS(29), LS(28), length(0-15)
```

**Init sequence**:
1. `nic.findDevice(0x10EC, 0x8125)` → PCI device
2. `enableBusMastering()`
3. `nic.mapMmio(bar2_phys, 0x10000)` → volatile MMIO ptr
4. Software reset (write 0x10 to ChipCmd, poll until cleared)
5. Unlock config (write 0xC0 to Cfg9346)
6. Read MAC from offsets 0x00-0x05
7. `nic.allocDma(1)` x2 for TX/RX descriptor rings (256x16B = 4KB each)
8. `nic.allocDma(1)` x512 for data buffers (2KB each)
9. Program TxDescAddr, RxDescAddr with physical addresses
10. Configure TxConfig, RxConfig, RxMaxSize
11. Enable RX/TX (write CmdRxEnb|CmdTxEnb to ChipCmd)
12. Lock config (write 0x00 to Cfg9346)
13. `nic.openEtherDriver()` → fd for `/dev/ether0` in driver mode

**Main loop** (2 threads):
- **RX thread** (main): polls RX descriptors (OWN bit), writes received frames to ether fd
- **TX thread**: blocking `read()` on ether fd for TX frames, submits to TX ring

**Files**: `fornax-nics/r8169/src/main.zig`

### Step 7: Integration

**Init spawn order**: partfs → fxfs → **r8169** → netd → login

Auto-detect: init reads `/dev/pci`, matches vendor:device, spawns matching driver from `/bin/`. Falls back to kernel virtio-net if no userspace driver found.

## Testing

- **Build**: `zig build r8169` in fornax-nics compiles without errors
- **Syscall smoke test**: small program exercises pci_cfg + mmap_device + dma_alloc in QEMU
- **Mock driver test**: userspace program opens /dev/ether0 in driver mode, echoes frames (validates ether TX ring)
- **Real hardware**: PCI passthrough of RTL8125 via VFIO, or bare-metal boot

## Dependencies

- Phase 2000a — PCI enhancement (BAR size probing, capabilities)
- Phase 2000c — Device-backed mmap

## New Syscalls Summary

| SYS # | Name | Args | Description |
|-------|------|------|-------------|
| 41 | pci_cfg | bdf, offset, value, write | PCI config space read/write (root-only) |
| 42 | mmap_device | phys_addr, size, flags | Map MMIO into userspace (root-only) |
| 43 | dma_alloc | pages, result_ptr | Allocate contiguous DMA memory (root-only) |

## Estimated Size

- Kernel changes (steps 1-4): ~500-600 lines across pci.zig, syscall.zig, ether.zig, process.zig, paging.zig, lib/syscall.zig
- Userspace NIC lib (step 5): ~150 lines
- RTL8125 driver (step 6): ~400-500 lines
- Total: ~1100-1250 lines
