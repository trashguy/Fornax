# Phase 15: PCI Enumeration + virtio-net Driver

## Goal

Talk to QEMU's virtual NIC. Expose raw Ethernet frames as a userspace file server at `/dev/ether0/`.

## Architecture

```
Applications
    │ open/read/write /dev/ether0/*
    v
ether_server (userspace file server)
    │ IPC to kernel for MMIO access
    v
virtio-net device (PCI, MMIO virtqueues)
    │
    v
QEMU virtual network
```

## PCI Enumeration (kernel-side)

PCI config space is accessed via I/O ports 0xCF8 (address) and 0xCFC (data) on x86_64.

### New file: `src/arch/x86_64/pci.zig`

```
Functions:
  configRead(bus, slot, func, offset) → u32
  configWrite(bus, slot, func, offset, value)
  enumerate() → list of discovered devices
  findDevice(vendor_id, device_id) → ?PciDevice

Types:
  PciDevice { bus, slot, func, vendor_id, device_id, class, subclass, bar[6] }
```

Scan bus 0, slots 0-31, function 0 (simple scan, sufficient for QEMU).

virtio-net identification:
- Vendor ID: 0x1AF4 (Red Hat / virtio)
- Device ID: 0x1000 (transitional) or 0x1041 (modern virtio-net)

## virtio Basics

virtio devices communicate through virtqueues — ring buffers in shared memory.

Each virtqueue has three parts:
1. **Descriptor table**: array of buffer descriptors (addr, len, flags, next)
2. **Available ring**: guest → device (buffers ready for device to consume)
3. **Used ring**: device → guest (buffers the device is done with)

virtio-net has 3 queues:
- Queue 0: receiveq (device → guest: incoming packets)
- Queue 1: transmitq (guest → device: outgoing packets)
- Queue 2: controlq (optional, for advanced features)

## Implementation Plan

### Step 1: PCI enumeration

New file: `src/arch/x86_64/pci.zig`
- Read PCI config space via ports 0xCF8/0xCFC
- Enumerate bus 0, find virtio-net device
- Read BARs (Base Address Registers) for MMIO regions
- Print discovered devices to serial

### Step 2: virtio initialization

New file: `src/virtio.zig`
- Generic virtio device setup (not NIC-specific)
- virtqueue allocation and initialization
- Feature negotiation
- Device status protocol: RESET → ACKNOWLEDGE → DRIVER → FEATURES_OK → DRIVER_OK

### Step 3: virtio-net driver

New file: `user/ether_server.zig` (initially kernel-side for bring-up, move to userspace later)
- Initialize virtio-net device
- Set up receive/transmit virtqueues
- Post receive buffers
- Handle incoming frames
- Expose via file server interface

### Step 4: File server interface

```
/dev/ether0/
├── data        read = receive frame, write = send frame
├── addr        read = MAC address (text: "52:54:00:12:34:56")
├── ctl         write "mtu 1500", "promisc on"
├── stats       read = "rx_packets 123\ntx_packets 456\n..."
└── type        read = "virtio-net"
```

## QEMU Setup

Add to run script:
```
-device virtio-net-pci,netdev=net0
-netdev user,id=net0
```

Or for multi-node testing:
```
# Node A
-device virtio-net-pci,netdev=net0 -netdev socket,id=net0,listen=:1234
# Node B
-device virtio-net-pci,netdev=net0 -netdev socket,id=net0,connect=:1234
```

## Verify

1. PCI scan finds virtio-net device, prints vendor/device ID
2. virtio init completes (device status = DRIVER_OK)
3. Read MAC address from device
4. Receive a frame (from QEMU user-mode network stack)
5. Send a frame (visible in QEMU network capture)

## Files Changed

| File | Change |
|------|--------|
| `src/arch/x86_64/pci.zig` | New: PCI config space access + enumeration |
| `src/virtio.zig` | New: Generic virtio device/queue setup |
| `user/ether_server.zig` | New: virtio-net driver + file server |
| `src/main.zig` | Add PCI scan after arch init |
| `build.zig` | Add ether_server binary |
| `scripts/run-x86_64.sh` | Add virtio-net device to QEMU |

## Risks

| Risk | Mitigation |
|------|------------|
| virtio modern vs legacy | Start with legacy (simpler I/O port based), upgrade to modern (MMIO) later |
| MMIO access from userspace | For bring-up, run driver in kernel; move to userspace once MMIO mapping works |
| Interrupt handling for RX | Poll initially, add IRQ support later |
| DMA buffer alignment | virtio requires page-aligned buffers; PMM already provides this |
