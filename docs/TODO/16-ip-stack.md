# Phase 16: IP Stack (Ethernet + ARP + IPv4 + UDP + ICMP)

## Goal

Userspace file server providing Plan 9-style network interface at `/net/`. Enough to ping and send/receive UDP datagrams.

## Interface

```
/net/
├── arp                     read = ARP table ("10.0.0.1 52:54:00:12:34:56\n...")
├── ipifc/
│   └── 0/
│       ├── ctl             write "add 10.0.0.2/24", "mtu 1500"
│       ├── addr            read = "10.0.0.2"
│       ├── mask            read = "255.255.255.0"
│       └── stats           read = interface counters
├── udp/
│   ├── clone               open → returns connection number (e.g., "0")
│   └── 0/
│       ├── ctl             write "connect 10.0.0.1!53" or "headers"
│       ├── data            read/write datagrams
│       ├── local           read = "10.0.0.2!12345"
│       └── remote          read = "10.0.0.1!53"
└── icmp/
    └── stats               read = "echo_req 5\necho_reply 5\n..."
```

## Modules

| Module | Responsibility |
|--------|---------------|
| `ethernet.zig` | Parse/build Ethernet frames, demux by EtherType |
| `arp.zig` | ARP request/reply, cache with timeout |
| `ipv4.zig` | IP header parse/build, checksum, basic routing |
| `icmp.zig` | Echo request/reply (ping) |
| `udp.zig` | Connectionless datagrams, port multiplexing |

## Verify

1. Fornax responds to ping from host
2. Two Fornax instances exchange UDP messages
3. ARP table shows discovered hosts
