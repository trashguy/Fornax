# Phase 203: Text Processing Utilities

## Status: Done

## Goal

Pure userspace text processing. No kernel changes. All follow the same pattern: read from stdin or file args, process line-by-line, write to stdout.

## Depends On

- Phase 24 (shell) — done
- Phase 201 (seek) — benefits head/tail

---

## 203.1: `cmd/grep/main.zig` (NEW — ~80 lines)

`grep pattern [file...]` — literal substring match using `str.indexOfSlice`. Read in 4 KB chunks, buffer partial lines across reads, print matching lines. Supports stdin when no file args (for pipes: `cat file | grep foo`).

## 203.2: `cmd/head/main.zig` (NEW — ~60 lines)

`head [-n N] [file]` — print first N lines (default 10). Count newlines, stop early.

## 203.3: `cmd/tail/main.zig` (NEW — ~70 lines)

`tail [-n N] [file]` — print last N lines (default 10). Read entire input into BSS buffer (32 KB, `linksection(".bss")`), scan backwards for Nth-from-last newline.

## 203.4: `cmd/sed/main.zig` (NEW — ~120 lines)

Minimal: `sed 's/old/new/'` and `sed 's/old/new/g'` only. Parse s-expression delimiter/old/new/flags. Per-line literal substitution via `str.indexOfSlice`. No address ranges, no hold space, no multi-command.

## 203.5: `cmd/awk/main.zig` (NEW — ~100 lines)

Minimal: `awk '{print $N}'` and `awk -F: '{print $1}'`. Split lines on delimiter (default whitespace), emit selected fields. No variables, no conditions, no arithmetic.

## 203.6: `cmd/less/main.zig` (NEW — ~90 lines)

Read file/stdin into BSS buffer. Display 24 lines, wait for keypress (raw keyboard mode — existing `rawon`/`rawoff` mechanism). Space=next page, Enter=next line, q=quit, b=back page.

---

## Files

| File | Change |
|------|--------|
| `cmd/grep/main.zig` | New file |
| `cmd/head/main.zig` | New file |
| `cmd/tail/main.zig` | New file |
| `cmd/sed/main.zig` | New file |
| `cmd/awk/main.zig` | New file |
| `cmd/less/main.zig` | New file |
| `build.zig` | Add 6 build targets + initrd entries |

**Phase 203 total: ~520 lines, 6 new files. No kernel changes.**

---

## Verify

1. `echo hello world | grep hello` → prints line
2. `head -n 2 /boot/init` → first 2 lines
3. `echo a:b:c | awk -F: '{print $2}'` → "b"
4. `echo foo bar | sed 's/foo/baz/'` → "baz bar"
5. `less /boot/init` → paged view, q to quit
