# Phase 2002 — srv/input (Input Server)

## Status: Planned

## Goal
Unified input device server providing mouse and keyboard events.

## Decisions (open)

- **Interrupt delivery to userspace**: How does srv/input receive hardware
  interrupts? Options: (a) New `SYS.intr_recv` syscall that blocks until an
  interrupt fires on a registered IRQ. (b) Kernel pushes events into an IPC
  channel that srv/input reads. (c) Port I/O syscall (`SYS.inb`/`SYS.outb`) so
  srv/input polls PS/2 directly. Option (a) is cleanest but needs new kernel
  infra. Option (c) is simplest but polling is wasteful.
- **Unified server vs split**: One srv/input for both keyboard and mouse? Or
  separate srv/kbd and srv/mouse? Unified is fewer processes; split is simpler
  per-server. Plan 9 has separate /dev/mouse and /dev/cons (keyboard).
- **Event format**: Plan 9 mouse format is `m X Y buttons\n` (text). Plan 9
  keyboard is rune-based via /dev/cons. Do we use binary structs (faster, typed)
  or text (Plan 9 compatible, debuggable)? Binary for MVP, add text compat later?
- **Multi-client delivery**: When multiple processes read /dev/kbd, who gets the
  event? Only the focused window (srv/wm decides)? Or broadcast to all readers?
  Plan 9 model: /dev/cons is per-process (via namespace), so this is the wm's
  problem.
- **Initial hardware backend**: PS/2 keyboard is simplest (port 0x60/0x64, IRQ1).
  Do we also need mouse for MVP? Could start keyboard-only and add mouse when
  srv/wm needs it.

## Provides
- `/dev/mouse` — x, y, buttons (Plan 9 mouse format)
- `/dev/kbd` — key events (Plan 9 cons/keyboard format)
- `/dev/touch` — touch events (future)

## IPC Protocol
```
T_OPEN "mouse"  → R_OK
T_OPEN "kbd"    → R_OK
T_READ (mouse)  → R_OK + MouseEvent (x, y, buttons, timestamp)
T_READ (kbd)    → R_OK + KeyEvent (scancode, pressed, timestamp)
T_CTL  "grab"   → R_OK (exclusive input for this client)
T_CTL  "ungrab" → R_OK
T_CLOSE         → R_OK
```

## Mouse Event Format (Plan 9 compatible)
```
struct MouseEvent {
    x: i32,       // absolute X position
    y: i32,       // absolute Y position
    buttons: u32, // button bitmask (1=left, 2=middle, 4=right)
    msec: u32,    // timestamp
}
```

## Key Event Format
```
struct KeyEvent {
    scancode: u16,  // PS/2 scancode
    rune: u32,      // Unicode codepoint (0 if none)
    pressed: bool,  // true=down, false=up
    modifiers: u16, // shift/ctrl/alt/meta bitmask
}
```

## Implementation
1. Kernel delivers input interrupts to srv/input via chosen mechanism
2. Initially: PS/2 keyboard via port I/O (x86_64)
3. Initially: PS/2 mouse or emulated via UEFI pointer protocol
4. Clients block on T_READ until an event is available

## Dependencies
- Phase 17: spawn syscall
- Kernel: interrupt delivery or port I/O syscall (new)
