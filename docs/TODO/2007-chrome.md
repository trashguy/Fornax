# Phase 2007 — Chrome in a Fornax Window

## Status: Planned

## Goal
Capstone: Chrome runs in a POSIX realm, renders via sommelier into a native Fornax window.

## Decisions (open)

- **Chrome vs simpler browser**: Chrome is massive (multi-process, GPU process,
  sandbox, etc.). Start with a simpler browser to validate the stack? e.g.
  Netsurf (C, small, no JS), or surf (suckless, WebKit). Or go straight for
  Chrome to prove the full POSIX compat story?
- **Rendering backend**: Chrome can use software rendering (--disable-gpu) or
  GPU. Software rendering (via Skia CPU backend) should work out of the box
  with just Wayland + framebuffer. GPU rendering needs Phase 2005 + Mesa/Vulkan.
  Software rendering for MVP.
- **Multi-process Chrome**: Chrome spawns many child processes (renderer, GPU,
  network, etc.). These all need to work within the POSIX realm. Does the realm
  support multiple processes? Or do we need to restrict Chrome to single-process
  mode (--single-process)?
- **Crash isolation scope**: When Chrome crashes, what exactly dies? Just the
  realm? The Wayland bridge too? How does srv/wm detect the window owner is gone
  and reclaim the window? Supervisor monitors the realm process — on crash,
  supervisor notifies srv/wm to destroy the window.

## Full Rendering Path
```
Chrome (POSIX realm)
  → Wayland protocol (Unix socket via /net/unix)
  → sommelier (POSIX realm, bridges to Fornax)
  → writes to /dev/draw (Fornax window, provided by srv/wm)
  → srv/wm composites all windows
  → srv/draw renders to framebuffer
  → srv/gpu pushes to display
  → pixels on screen
```

## User Experience
```
fornax% chrome &
# Chrome window appears alongside native windows
# Alt-tab between acme (native) and Chrome (realm)
# Chrome crashes → realm dies → srv/wm reclaims window → native apps unaffected
```

## Dependencies
- Phase 2006: Wayland bridge
- Phase 1000: POSIX Realms
