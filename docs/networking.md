# Networking Stack

Fornax implements networking from bare metal: PCI enumeration, virtio NIC driver, and a protocol stack covering Ethernet, ARP, IPv4, ICMP, and UDP.

## Packet Flow

```
             Incoming                          Outgoing
                │                                 │
       virtio_net.poll()                  virtio_net.send()
                │                                 ^
                v                                 │
   ┌────────────────────────┐        ┌────────────────────────┐
   │  net.handleFrame()     │        │  net.sendIpPacket()    │
   │  - filter: our MAC or  │        │  - subnet check        │
   │    broadcast            │        │  - ARP lookup/request  │
   │  - demux by EtherType  │        │  - Ethernet framing    │
   └────────┬───────────────┘        └────────────────────────┘
            │                                     ^
    ┌───────┴───────┐                             │
    v               v                     ┌───────┴───────┐
  0x0806          0x0800                  │               │
   ARP             IPv4                  IPv4            IPv4
    │               │                   build()         build()
    v               v                     ^               ^
 arp.handle     ipv4.parse                │               │
 Packet()        + verify                 │               │
    │            checksum             icmp.build     udp.build
    │               │                EchoReply()     Packet()
    v               v
 ARP reply    ┌─────┴──────┐
 (if for us)  v            v
            proto=1      proto=17
             ICMP          UDP
              │             │
              v             v
         icmp.handle   udp.handle
         Packet()      Packet()
              │             │
              v             v
         echo reply    deliver to
         (send back)   connection
                       rx buffer
```

## Hardware Layer

### PCI Enumeration (`src/arch/x86_64/pci.zig`)

Scans PCI bus 0, slots 0-31, reading config space via I/O ports `0xCF8` (address) and `0xCFC` (data). Each discovered device is logged to serial with vendor/device IDs and class codes.

`PciDevice` stores vendor ID, device ID, class/subclass, and BARs. Helper methods extract the I/O base address from BAR0 and enable bus mastering (required for DMA).

### virtio-net Driver (`src/virtio_net.zig`)

Uses the **virtio legacy I/O port interface** (virtio spec 0.9.5), which is simpler than the modern MMIO transport and well-supported by QEMU.

**Device discovery**: Finds vendor `0x1AF4` (Red Hat/Virtio), device `0x1000` (transitional net) or `0x1041` (modern net).

**Initialization sequence**:
1. Enable PCI bus mastering
2. Reset device (write 0 to status register)
3. Acknowledge + set DRIVER status
4. Read device features, negotiate (`MAC` + `STATUS`, no `MRG_RXBUF`)
5. Set up RX queue (index 0) and TX queue (index 1)
6. Post 16 receive buffers (4 KB pages from PMM)
7. Read MAC address from device config at BAR0 + `0x14`
8. Set DRIVER_OK status

**Virtqueue layout** (allocated from PMM, physically contiguous):
```
[Descriptor table: 16 bytes * queue_size]
[Available ring: 4 + 2 * queue_size + 2 bytes]
--- page-aligned boundary ---
[Used ring: 4 + 8 * queue_size + 2 bytes]
```

The descriptor table holds buffer addresses and lengths. The available ring tells the device which descriptors are ready. The used ring tells the driver which descriptors the device has finished with.

**Frame format**: Every frame is prepended with a 10-byte `VirtioNetHeader` (flags, GSO type/size, checksum offsets). All zeros for basic operation — no checksum offloading, no segmentation.

### Generic virtio (`src/virtio.zig`)

Shared virtio infrastructure used by any virtio device:
- I/O port read/write helpers (byte-level via `inb`/`outb`)
- `initDevice()`: Reset, acknowledge, read features
- `finishInit()`: Negotiate features, set DRIVER_OK
- `setupQueue()`: Allocate and configure a virtqueue
- `addBuffer()`: Add a descriptor to the available ring
- `notify()`: Write queue index to the notify register
- `pollUsed()`: Check the used ring for completed descriptors
- `memoryBarrier()`: Architecture-aware fence (`mfence` on x86_64, `dmb sy` on aarch64)

## Protocol Layers

### Ethernet (`src/net/ethernet.zig`)

IEEE 802.3 frame handling.

**Frame layout**: `[dst MAC 6][src MAC 6][EtherType 2][payload 46-1500]`

- `parse()`: Extracts header fields and payload slice. EtherType is big-endian.
- `build()`: Writes a complete frame into a buffer. Returns total length.
- Constants: `ETHER_ARP` (0x0806), `ETHER_IPV4` (0x0800), `BROADCAST` (FF:FF:FF:FF:FF:FF).

The integration layer (`net.zig`) filters incoming frames: only those addressed to our MAC or to broadcast are processed.

### ARP (`src/net/arp.zig`)

Address Resolution Protocol — resolves IPv4 addresses to MAC addresses.

**Cache**: 32 entries with round-robin eviction. No TTL (entries persist until evicted). Every ARP packet we receive (request or reply) inserts the sender's IP/MAC into the cache. Existing entries for the same IP are updated in place.

**Inbound flow**:
1. Validate hardware type (Ethernet), protocol type (IPv4), lengths
2. Learn sender's IP/MAC (always)
3. If this is an ARP request for our IP, build and send a unicast reply

**Outbound flow** (triggered by `net.sendIpPacket()`):
1. Look up destination (or gateway) IP in cache
2. If found, use the MAC to build the Ethernet frame
3. If not found, broadcast an ARP request and drop the current packet. The reply will populate the cache for the next attempt.

**ARP packet layout** (28 bytes for Ethernet+IPv4):
```
[hw_type 2][proto_type 2][hw_len 1][proto_len 1][operation 2]
[sender_mac 6][sender_ip 4][target_mac 6][target_ip 4]
```

### IPv4 (`src/net/ipv4.zig`)

Minimal IPv4: no fragmentation, no options, no routing table.

**Parse**:
- Validates version (must be 4) and IHL (must be >= 5)
- Verifies header checksum using RFC 1071 ones-complement sum
- Extracts payload based on total length field

**Build**:
- Version/IHL: `0x45` (20-byte header, no options)
- TTL: 64
- Flags: Don't Fragment (`0x4000`)
- Identification: auto-incrementing counter
- Computes and inserts header checksum

**Routing** (handled by `net.zig`):
- If `(dst & mask) == (our_ip & mask)`, destination is on the local subnet — use its IP for ARP lookup
- Otherwise, use the gateway IP for ARP lookup

**Checksum** (RFC 1071): Sum all 16-bit words, fold carries, ones-complement. Used by both IPv4 headers and ICMP.

**Default config** (QEMU user-mode networking):
| Field | Value |
|-------|-------|
| IP | 10.0.2.15 |
| Gateway | 10.0.2.2 |
| Subnet mask | 255.255.255.0 |

### ICMP (`src/net/icmp.zig`)

Internet Control Message Protocol — echo request/reply (ping).

When an echo request (type 8) arrives:
1. Verify ICMP checksum
2. Copy the entire ICMP payload (preserving identifier, sequence number, and data)
3. Set type to 0 (echo reply), code to 0
4. Recompute checksum
5. Build a new IPv4 packet with swapped src/dst addresses
6. Send back through the Ethernet/ARP path

**Stats tracked**: `echo_requests_rx`, `echo_replies_tx`, `echo_requests_tx`, `echo_replies_rx`.

### UDP (`src/net/udp.zig`)

User Datagram Protocol — connectionless datagrams with port multiplexing.

**Connection model**: 16 connection slots. Each slot has:
- Local port (assigned from ephemeral range 49152+ on alloc, or explicitly bound)
- Optional remote IP/port (if `connect()` was called, filters inbound datagrams)
- Single-datagram receive buffer (1500 bytes) — new datagrams overwrite unread ones

**API**:
| Function | Description |
|----------|-------------|
| `alloc()` | Allocate a connection slot, assign ephemeral port |
| `bind(idx, port)` | Set a specific local port |
| `connect(idx, ip, port)` | Filter to a specific remote |
| `close(idx)` | Release the slot |
| `recv(idx)` | Read the received datagram (if any) |

**Inbound**: Match by destination port. If the connection is "connected", also filter by remote IP/port. Payload is copied into the connection's receive buffer.

**Outbound**: `net.sendUdp()` builds the UDP header (checksum 0, valid for IPv4), wraps in IPv4, resolves ARP, frames in Ethernet, sends via virtio-net.

**Max payload**: 1472 bytes (1500 MTU - 20 IP - 8 UDP).

## Integration Layer (`src/net.zig`)

Wires all protocol modules to the virtio-net driver:

- `init()`: Reads MAC from virtio-net, sets default IP/gateway/mask, marks initialized
- `poll()`: Calls `virtio_net.poll()`, filters by destination MAC, dispatches by EtherType
- `sendIpPacket(dst_ip, packet)`: Determines next-hop (same subnet or gateway), resolves MAC via ARP, wraps in Ethernet, sends
- `sendUdp(dst_ip, src_port, dst_port, data)`: Convenience function — builds UDP+IP+Ethernet and sends
- `setIp()`, `setGateway()`, `setSubnetMask()`: Runtime configuration

## QEMU Setup

The run script (`scripts/run-x86_64.sh`) includes:
```
-device virtio-net-pci,netdev=net0
-netdev user,id=net0
```

QEMU user-mode networking provides a virtual network at `10.0.2.0/24` with:
- Gateway/DHCP at `10.0.2.2`
- DNS at `10.0.2.3`
- Fornax configured at `10.0.2.15`

## Future: Plan 9 `/net/` Interface

The protocol stack currently runs kernel-side. The plan is to expose it as a userspace file server at `/net/`, following the Plan 9 convention:

```
/net/
├── arp                     read = ARP table
├── ipifc/0/
│   ├── ctl                 write "add 10.0.0.2/24"
│   ├── addr                read = current IP
│   └── stats               read = interface counters
├── udp/
│   ├── clone               open -> returns connection number
│   └── 0/
│       ├── ctl             write "connect 10.0.0.1!53"
│       ├── data            read/write datagrams
│       ├── local           read = "10.0.0.2!12345"
│       └── remote          read = "10.0.0.1!53"
└── icmp/
    └── stats               read = echo counters
```

No sockets API. To send a UDP packet: open `/net/udp/clone`, write `"connect 10.0.0.1!53"` to the ctl file, write the payload to the data file.
