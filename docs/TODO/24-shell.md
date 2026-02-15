# Phase 24: Shell — DONE

## What Was Implemented

**fsh** — Fornax shell, an rc-inspired interactive shell.

### cmd/fsh/main.zig
- Prompt loop: prints `fornax% `, reads line from stdin, tokenizes on whitespace
- Builtins: `exit`, `echo`, `clear`, `help`
- External commands: looks up `/boot/<name>`, loads ELF into 2MB buffer, spawns child, waits
- Error handling: "not found" for missing commands, "spawn failed" for spawn errors

### cmd/hello/main.zig
- Simple test program: prints "Hello from Fornax!" and exits

### cmd/init/main.zig (modified)
- Replaced echo loop with spawn-fsh-and-wait loop
- Loads /boot/fsh ELF, spawns, waits, respawns on exit

### build.zig (modified)
- Added fsh_exe and hello_exe build targets
- Included both in x86_64 initrd

## Verification
- `zig build x86_64` compiles cleanly
- Boot → init spawns fsh → `fornax%` prompt
- `hello` → "Hello from Fornax!" → prompt returns
- `echo foo bar` → "foo bar"
- `help` → lists builtins and /boot/ programs
- `nonexistent` → "fsh: nonexistent: not found"
- `exit` → fsh exits, init respawns it
