# 002-net-bugs.md

## Critical Bugs

### 1. ARP Cache Never Expires (`src/net/arp.zig`)
The ARP cache has no timeout mechanism - entries live forever until evicted via round-robin. This violates RFC 1122 which requires ARP cache entries to expire. Stale entries can cause packets to be sent to wrong MAC addresses.

### 2. TCP: No Validation of Sequence Number Bounds (`src/net/tcp.zig:717-747`)
In `handleEstablished()`, data is accepted without checking if the sequence number is within the receive window. A remote attacker could send data with arbitrary sequence numbers. BSD validates that `seq` is within the acceptable window range.

### 3. TCP: Missing RTTM (Round-Trip Time Measurement) (`src/net/tcp.zig`)
No actual RTT measurement - the RTO is simply doubled on each retransmission. BSD uses Karn's algorithm and maintains an RTT estimator (Van Jacobson algorithm).

### 4. TCP: No Fast Retransmit (`src/net/tcp.zig`)
The stack doesn't implement fast retransmit (RFC 2581). When duplicate ACKs are received, it only triggers retransmission after timeout expires, significantly hurting performance over lossy networks.

### 5. TCP: No Delayed ACK 
The stack sends an ACK for every data segment received. BSD typically delays ACKs by up to 200ms to reduce ACK overhead.

### 6. UDP: No Port Validation / Socket Bind Check (`src/net/udp.zig:119-138`)
The code doesn't verify the local IP address when receiving packets. Should verify the socket is bound to `INADDR_ANY` or the specific destination IP.

### 7. IPv4: No Source Address Validation (`src/net/ipv4.zig`)
No martian source filtering (RFC 1812 Section 5.2.7).

### 8. IPv4: No IP ID Randomization (`src/net/ipv4.zig:84`)
The IP identification field is a simple counter, making it easy to predict and a potential target for fragmentation attacks.

## Moderate Bugs

### 9. TCP: Incorrect Locking in handlePacket (`src/net/tcp.zig:482-496`)
Race condition between releasing `alloc_lock` and acquiring `conn.lock` - connection could be freed in between.

### 10. ARP: Accepts Any ARP Reply Without Validation (`src/net/arp.zig`)
The stack learns MAC addresses from any ARP reply without verifying we sent a request. Allows ARP spoofing.

### 11. Ethernet: No Minimum Frame Size Check (`src/net/ethernet.zig`)
`parse()` doesn't verify the frame meets minimum Ethernet size (64 bytes).

### 12. TCP: Window Scale Option Not Implemented
Advertises a fixed 16-bit window (max 65535 bytes) without TCP Window Scaling (RFC 1323).

### 13. TCP: No Path MTU Discovery
No ICMP "packet too big" handling or DF bit tracking.
