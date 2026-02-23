# Code Cleanup

## Split Large Modules

The kernel has two files that have grown unwieldy:

### 1. `src/syscall.zig` (~4400 lines)
Currently contains all syscall handlers in a single massive switch statement.

**Recommendation:** Split by category:
- `src/syscall/fs.zig` - open, read, write, stat, seek, etc.
- `src/syscall/proc.zig` - fork, exec, wait, exit, getpid
- `src/syscall/mem.zig` - brk, mmap, munmap
- `src/syscall/net.zig` - socket, connect, listen
- `src/syscall.zig` - dispatcher/registry

### 2. `src/process.zig` (~1300 lines)
Contains process/thread management.

**Recommendation:** Consider splitting if it contains multiple distinct concerns (e.g., process creation vs scheduling vs lifecycle).

### Guidelines for Zig file sizes
- ~500 lines: Clean, easy to navigate
- ~1000 lines: Manageable
- ~1500+: Consider splitting

Zig's stdlib uses large files, but that's not a model to emulate for a codebase that needs long-term maintenance.

## Documentation

### Inline (Zig docs)
Use `///` doc comments on public functions and types. Generate via `zig docs`.

### Architecture Overview (Markdown)
Zig docs answer "what does this function do" but can't explain "how the pieces fit together."

Suggested docs:
- `docs/architecture.md` - overall kernel design
- `docs/ipc.md` - message passing protocol
- `docs/syscall-abi.md` - syscall interface
- `docs/namespaces.md` - mount/namespace semantics

### When to document
If you find yourself writing a comment thread to explain something, that's a signal it should be in the docs.

## Tracing and Debugging

Post-mortem crash analysis is limited with just panic output. Consider adding a lightweight in-memory trace buffer that captures:
- Last N events (syscalls, interrupts, context switches)
- Timestamp for each event
- Wrap-around ring buffer in a dedicated section

This helps debug issues that are hard to reproduce. Keep it minimal to avoid performance impact.
