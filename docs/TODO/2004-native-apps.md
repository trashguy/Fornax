# Phase 2004 — Native GUI Apps

## Status: Planned

## Goal
Proof of life. Native Fornax programs drawing in windows.

## Decisions (open)

- **Which app first?**: cmd/clock is simpler (no input, just draw + sleep loop).
  cmd/term is more useful (validates keyboard input path too). Start with clock
  as smoke test, then term?
- **Time source**: cmd/clock needs a time source. New `SYS.time` syscall? Read
  from /dev/time (served by a time server)? Or just a frame counter for MVP
  (no real clock, just proves the drawing path works)?
- **Terminal emulation**: How much of VT100/ANSI does cmd/term need? Full escape
  code parsing? Or bare minimum (print characters, handle newline, backspace)?
  Bare minimum first — full VT100 is a rabbit hole.
- **Shell integration**: cmd/term needs a shell to be useful. Does it spawn
  cmd/sh as a child (Phase 24)? Or is it standalone for now (just echoes input)?
  Standalone echo mode for MVP, shell integration when Phase 24 lands.
- **Drawing API**: Do apps use the text-based T_CTL protocol directly, or do we
  provide a helper library in lib/fornax.zig (e.g., `draw.rect(...)`,
  `draw.text(...)`)? Helper lib reduces boilerplate and is reusable.

## Apps
- `cmd/clock` — simple clock widget (draws time, updates periodically)
- `cmd/term` — graphical terminal (reads /dev/cons, draws text via /dev/draw)
- `cmd/acme` — Plan 9 acme-style editor (stretch)

## Validation Path
```
app → /dev/draw → srv/wm → srv/draw → srv/gpu → pixels
```

## cmd/clock
1. Opens /dev/wm/ctl, creates 200x200 window
2. Opens /dev/draw (window-local, provided by srv/wm)
3. Loop: draw background, draw time digits, flush, sleep 1s

## cmd/term
1. Opens /dev/wm/ctl, creates 640x480 window
2. Opens /dev/draw (window-local) + /dev/kbd (window-local)
3. Maintains text buffer (cols x rows)
4. On key: append to input buffer, echo via /dev/draw text command
5. On newline: write to /dev/cons for shell processing

## Dependencies
- Phase 2003: srv/wm
- Phase 24: shell (for cmd/term to be useful)
