# Phase 3000: Cluster Discovery

**Requires: `-Dcluster=true` at build time.**

## Goal

Fornax nodes automatically discover each other on the local network. Clustering is a compile-time option — when disabled (default), none of this code is included in the kernel binary.

The kernel gates cluster code with:
```zig
const build_options = @import("build_options");
if (build_options.cluster) {
    // cluster init...
}
```

## Design

### Discovery Protocol (UDP broadcast, port 9710)

Simple gossip protocol. Each node periodically broadcasts its state.

```
Message format (text, Plan 9 style):
  ANNOUNCE <node_id> <addr> <name> <cpu_count> <mem_total> <mem_free> <container_count>
  HEARTBEAT <node_id> <load> <mem_free> <container_count>
  LEAVE <node_id>
```

- Broadcast interval: 5 seconds
- Heartbeat timeout: 15 seconds → mark as "suspect"
- Dead timeout: 30 seconds → mark as "dead", remove after 60s

### Why Gossip (not leader election)

- No single point of failure
- Works across network partitions (nodes see what they can see)
- Simple implementation — no Raft/Paxos complexity
- Sufficient for discovery; scheduling can layer consensus on top if needed

## Interface

```
/cluster/
├── self/
│   ├── id                  "a7f3b2c1" (unique node ID, generated at boot)
│   ├── name                "fornax-01" (configurable)
│   ├── addr                "10.0.0.2"
│   └── resources           "cpus 4\nmem 256M\nmem_free 128M\n"
├── nodes/
│   ├── b8e4d3f2/
│   │   ├── name            "fornax-02"
│   │   ├── addr            "10.0.0.3"
│   │   ├── resources       "cpus 2\nmem 128M\nmem_free 64M\n"
│   │   ├── containers/     list of running containers
│   │   └── status          "online" / "suspect" / "dead"
│   └── ...
└── ctl                     write "join" / "leave" / "name fornax-01"
```

## Build Integration

Clustering is controlled by the `-Dcluster=true` build option in `build.zig`. This sets `build_options.cluster = true`, which the kernel checks at comptime. When false, `@import` of cluster modules is skipped entirely — Zig's dead code elimination ensures zero binary overhead.

## Verify

1. Build with `zig build x86_64 -Dcluster=true`
2. Boot two Fornax QEMU instances on same virtual network
3. Within 5 seconds, `ls /cluster/nodes/` shows the other node
4. Kill one instance — other marks it "suspect" then "dead"
5. Restart it — rediscovered and shown as "online"
6. Build without `-Dcluster` — verify no cluster code in binary

## Files

| File | Description |
|------|-------------|
| `srv/cluster/main.zig` | Discovery protocol + /cluster/* file server |
| `src/main.zig` | Conditionally spawn cluster server when `build_options.cluster` is true |
| `build.zig` | `-Dcluster` option, passed to kernel via `build_options` module |
