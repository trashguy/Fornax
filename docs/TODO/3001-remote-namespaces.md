# Phase 3001: Remote Namespace Import (9P over TCP)

**Requires: `-Dcluster=true` at build time.**

## Goal

Mount a remote Fornax node's file tree into the local namespace. Plan 9's distributed computing model — the same `open`/`read`/`write` syscalls work transparently across machines.

## Design

Our IPC messages already use 9P-style tags (T_OPEN, T_READ, T_WRITE, etc.). Running these over TCP instead of local channels gives us remote file access with minimal new code.

### Wire Protocol

9P2000 (Plan 9's file protocol), simplified:

```
Client → Server:
  Tversion  — negotiate protocol version
  Tauth     — authenticate (optional)
  Tattach   — attach to file tree root
  Twalk     — walk path components
  Topen     — open a file
  Tread     — read data
  Twrite    — write data
  Tclunk    — close file handle

Server → Client:
  Rversion, Rauth, Rattach, Rwalk, Ropen, Rread, Rwrite, Rclunk
  Rerror    — error response
```

Each message has: size(4) + type(1) + tag(2) + payload.

### Usage

```
# Import remote node's /proc into local namespace
mount("tcp!10.0.0.3!564", "/remote/node2", "")
cat /remote/node2/dev/console       → see remote console output
ls /remote/node2/proc/              → list remote processes

# Union mount: add remote node's containers into local view
bind("/remote/node2/containers", "/containers", AFTER)
```

## Components

| Component | Description |
|-----------|-------------|
| 9P server | Listens on port 564, translates 9P messages to local file ops |
| 9P client | mount() implementation — connects to remote 9P server |
| Transport | TCP stream carrying 9P messages |

## Verify

1. Node A exports its namespace on port 564
2. Node B mounts Node A: `mount("tcp!nodeA!564", "/remote/A", "")`
3. Node B reads `/remote/A/dev/console` — sees Node A's console output
4. Node B writes to `/remote/A/cluster/ctl` — command executes on Node A

## Security (future)

- TLS for transport encryption
- Capability-based access control per mount
- Per-connection namespace restrictions (export only specific subtrees)
