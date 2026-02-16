# Phase 207: Plan 9-style Environment Variables (`/env/`)

## Status: Planned

## Goal

Implement Plan 9-style environment variables as files in `/env/`. Each variable is a file whose name is the variable name and whose contents are the value. Child processes inherit them via namespace cloning.

In the interim, fsh has a local `export` builtin that sets shell variables (no inheritance). This phase replaces that with real per-process env vars.

## Depends On

- Phase 24 (shell) — done
- Phase 200 (/proc) — done (establishes kernel-intercepted virtual paths pattern)

---

## 207.1: `srv/envfs/main.zig` — envfs server (NEW)

In-memory filesystem server mounted at `/env/`. Handles T_OPEN/T_CREATE/T_READ/T_WRITE/T_CLOSE/T_REMOVE/T_STAT.

- Each variable = one file: `open("/env/FOO")` reads value, `create("/env/FOO", 0)` + write sets it
- Directory listing shows all defined variables
- Simple flat namespace (no subdirectories)
- Server runs per-process or is namespace-inherited (TBD: shared instance with per-client state, or forked copy)

## 207.2: Namespace inheritance for `/env/`

When `sysSpawn` clones the parent namespace, the child inherits the same `/env/` mount. Since namespaces are deep-copied, writes in the child don't affect the parent (copy-on-write semantics via separate envfs instance or shared-with-fork).

Options:
- **Option A**: envfs is a shared server; spawn sends a "fork" message so the server creates a child-private copy of the env table
- **Option B**: envfs state is small enough to serialize into the initrd/spawn path, so each process gets its own envfs instance
- **Option C**: Kernel intercepts `/env/` paths (like `/proc/`, `/net/`) and stores env vars in the process struct directly — no userspace server needed

## 207.3: Shell integration

- `export FOO=bar` → `create("/env/FOO", 0)` + `write(fd, "bar")` + `close(fd)`
- `$FOO` expansion → `open("/env/FOO")` + `read` + `close`
- `unset FOO` → `remove("/env/FOO")`
- `env` command (`cmd/env/main.zig`) → list `/env/` directory, cat each file
- `export` with no args → list all exported variables

## 207.4: Source script support

Convention: `/env/profile` or `/boot/profile` sourced at shell startup for default exports (PATH equivalent, prompt, etc.)

---

## Design Notes

Plan 9 stores env vars at `/env/` as regular files. rc(1) reads/writes them directly. Key differences from Unix:
- No `envp` array — just filesystem reads
- Inheritance is automatic via namespace cloning
- Any process can inspect another's env via its namespace (if accessible)
- Variables can contain binary data (not NUL-terminated)

For Fornax, Option C (kernel-intercepted `/env/`) is simplest — follows the `/proc/` pattern, stores vars in the process struct, no extra server process. But limits env size to what fits in the process struct.

---

## Files

| File | Change |
|------|--------|
| `srv/envfs/main.zig` OR `src/syscall.zig` | Env var storage + IPC handling |
| `src/process.zig` | Per-process env table (if Option C) |
| `cmd/fsh/main.zig` | `export` uses `/env/` instead of local table |
| `cmd/env/main.zig` | New: list environment variables |
| `build.zig` | Add envfs/env build targets |

---

## Verify

1. `export FOO=hello` then spawn child that does `cat /env/FOO` → prints `hello`
2. Child sets `BAR=world`, parent `cat /env/BAR` → not found (isolation)
3. `env` command lists all exported variables
