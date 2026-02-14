# Phase 21: Cluster Scheduler

**Requires: `-Dcluster=true` at build time.**

## Goal

Schedule and manage containers across a cluster of Fornax nodes. The scheduler is a userspace program — it reads cluster state from `/cluster/nodes/*` and issues commands via remote namespace mounts.

## Interface

```
/cluster/scheduler/
├── ctl                     write commands:
│                             "place <image> [constraints]"
│                             "migrate <container> <from> <to>"
│                             "evacuate <node>"
│                             "rebalance"
├── policy                  read/write: "spread" / "pack" / custom rules
│                             "affinity cpu>=2 mem>=128M"
│                             "anti-affinity web-* spread"
├── placements/             current container→node mappings
│   ├── container-abc       "node=fornax-02 image=hello status=running"
│   └── container-def       "node=fornax-01 image=web status=running"
└── log                     read = scheduling decisions log (text)
```

## Scheduling Algorithm

```
place(image, constraints):
  1. candidates = /cluster/nodes/* where status == "online"
  2. filter by constraints (cpu, mem, affinity, anti-affinity)
  3. apply policy:
     - "spread": pick node with fewest containers
     - "pack": pick node with most containers (bin packing)
     - "affinity": prefer nodes matching label/resource rules
  4. selected = pick best candidate
  5. mount("tcp!{selected.addr}!564", "/tmp/target", "")
  6. write("/tmp/target/cluster/ctl", "run {image}")
  7. record placement in /cluster/scheduler/placements/
  8. monitor via /tmp/target/cluster/containers/{id}/status
```

## Migration

```
migrate(container, from_node, to_node):
  1. Checkpoint container state on from_node (future: CRIU-like)
  2. Transfer state to to_node via 9P
  3. Start container on to_node
  4. Stop container on from_node
  5. Update placement record

  For MVP: stop on source, start fresh on target (no state transfer)
```

## Health Monitoring

The scheduler watches `/cluster/nodes/*/status`. When a node goes "dead":
1. Find all containers placed on that node
2. Re-place them on remaining healthy nodes
3. Log the recovery action

## Verify

1. Three-node cluster, all discovered
2. `write("/cluster/scheduler/ctl", "place hello")` → container starts on a node
3. Kill the node running the container → scheduler re-places on another node
4. `write("/cluster/scheduler/ctl", "evacuate fornax-02")` → all containers migrate off
