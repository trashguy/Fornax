# Phase 23: TTY / Interactive Console

## Goal

Rework the console server (currently scaffolded in Phase 12) into a proper
TTY that supports interactive input and output — required for a shell.

## Decision Points (discuss before implementing)

- **Line buffering vs raw mode**: Should the TTY do line editing (backspace,
  readline-style) in the server, or pass raw keystrokes to the application?
  Probably: line mode by default, raw mode via ctl file (like Plan 9).
- **Keyboard input**: Currently we have a framebuffer console for output. We
  need keyboard input — either PS/2 (simple, x86-only) or USB HID (complex)
  or virtio-input (QEMU-friendly). Which first?
- **Multiple TTYs?** One console to start, or virtual consoles (Alt+F1/F2)?
  Probably one for now.
- **Where does this run?** The console server is already a userspace process.
  It needs to talk to the keyboard driver (which could be another server or
  built into the console server for now).

## Interface

```
/dev/console
├── ctl          write "rawon" / "rawoff" / "echo on" / "echo off"
├── data         read = input from keyboard, write = output to screen
└── status       "line" / "raw"
```

## Needs

- Keyboard driver (PS/2 or virtio-input)
- Input buffer with blocking read (process blocks until input available)
- Line editing in line mode (backspace, enter to submit)
- Echo (typed characters appear on screen)

## Verify

1. User types on keyboard → characters appear on screen
2. Process reads from /dev/console → gets typed line
3. Shell (Phase 24) can read commands interactively
