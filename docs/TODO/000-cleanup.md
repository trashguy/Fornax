# Code Cleanup

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
