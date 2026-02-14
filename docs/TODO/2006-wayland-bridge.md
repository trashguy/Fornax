# Phase 2006 — Wayland Bridge (sommelier in POSIX Realm)

## Status: Planned

## Goal
Wayland compositor running inside a POSIX realm that bridges GUI apps to Fornax windows.

## Decisions (open)

- **sommelier vs cage vs custom**: sommelier (Google, C) is purpose-built for
  bridging Wayland into foreign windowing systems (used in ChromeOS). cage is a
  simpler single-app Wayland compositor. Or write a minimal custom bridge?
  sommelier is battle-tested but complex; cage is simpler for MVP; custom gives
  full control but is more work.
- **Pixel transfer path**: sommelier needs to write pixels to /dev/draw. Does it
  use the Fornax draw API directly (via libposix shim translating to Fornax
  syscalls)? Or does it write to a shared memory buffer that srv/wm reads?
  Direct /dev/draw writes are simpler — sommelier just looks like any other
  Fornax GUI app.
- **Input forwarding**: sommelier needs /dev/mouse and /dev/kbd events,
  translated to Wayland input events for clients. Does it read Fornax input
  files directly, or does srv/wm proxy input to it? Direct reads via namespace
  binding — srv/wm gives the sommelier window its own /dev/mouse and /dev/kbd.
- **Unix socket emulation**: Wayland uses Unix domain sockets. Fornax doesn't
  have Unix sockets natively. Options: (a) Implement Unix sockets in POSIX realm
  as part of Phase 1000. (b) Bridge Wayland over Fornax IPC channels. (c) Use
  named pipes (if implemented). Unix sockets are probably needed for POSIX
  compat anyway.
- **Multi-window**: Does sommelier get one Fornax window for all Wayland clients
  (composites internally), or does it create a separate Fornax window per
  Wayland client surface? One window is simpler; per-surface integrates better
  with native window management.

## Architecture
```
POSIX Realm:
  sommelier (Wayland compositor)
    ├── accepts Wayland connections from GUI apps
    ├── composites client surfaces
    ├── writes pixels to /dev/draw (Fornax window)
    └── reads /dev/mouse, /dev/kbd → forwards to clients
```

## Key Insight
srv/wm doesn't know or care what's behind the window.
sommelier just writes pixels to `/dev/draw` like any native app.

## Dependencies
- Phase 1000: POSIX Realms (musl, PT_INTERP, Unix sockets)
- Phase 2003: srv/wm
