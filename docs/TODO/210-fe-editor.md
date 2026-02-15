# Phase 210: `fe` — Minimal vi-like Editor for Fornax

## Status: Planned

## Goal

Fornax has no text editor. Until POSIX realms (Phase 1000) enable running Neovim, users need a native way to edit files. `fe` is a minimal vi-like editor written in Zig, targeting Fornax's existing syscall interface. It provides enough vi keybindings (modal editing, search, Shift+A/G, etc.) for comfortable file editing. Aliased to `vi` in the shell.

The console currently lacks ANSI cursor positioning, which is a prerequisite — we add a CSI escape sequence parser to `src/console.zig` first. We also bump ramfs file size to 32 KB and add basic 8-color support while touching the console.

## Depends On

- Phase 24 (shell) — done

---

## Files to Modify

| File | Change |
|------|--------|
| `src/console.zig` | Add ANSI CSI state machine (cursor positioning, clear, colors, reverse video) |
| `src/keyboard.zig` | Add `"size"` control command (returns cols/rows via ring buffer) |
| `srv/ramfs/main.zig` | Bump `MAX_FILE_SIZE` from 4096 to 32768 |
| `cmd/fe/main.zig` | **New file** — the editor (~1000 lines) |
| `build.zig` | Add `fe_exe` build target + initrd entry (line 252) |
| `cmd/fsh/main.zig` | Add `vi` -> `fe` alias in `executeLine()` |

---

## Step 1: Console ANSI CSI Support (`src/console.zig`)

Add a state machine to `putChar()` that intercepts ESC sequences:

**New state variables:**
- `parse_state: enum { normal, esc_seen, csi_param }`
- `csi_params: [4]u16` — numeric parameters
- `csi_param_count: u8`
- `csi_private: bool` — for `ESC[?` sequences
- `reverse_video: bool` — attribute state
- `fg_override: ?u32` — foreground color override (for SGR 30-37)
- `bg_override: ?u32` — background color override (for SGR 40-47)

**Modified `putChar()`:** Extract current logic into `putCharNormal()`. New `putChar()` runs the state machine:
- `.normal`: If `0x1B` -> `.esc_seen`, else call `putCharNormal()`
- `.esc_seen`: If `[` -> `.csi_param` (reset params), else -> `.normal`
- `.csi_param`: Digits accumulate into current param; `;` advances param; `?` sets private flag; letter triggers `executeCsi()` and resets to `.normal`

**`executeCsi()` handlers:**

| Sequence | Code | Action |
|----------|------|--------|
| `ESC[row;colH` | `H`/`f` | Set `cursor_x`, `cursor_y` (1-based -> 0-based, clamped) |
| `ESC[2J` | `J` p0=2 | Call existing `clearScreen()` |
| `ESC[K` | `K` | New `clearToEndOfLine()` — fill from cursor to end of row with bg |
| `ESC[7m` | `m` p0=7 | Set `reverse_video = true` |
| `ESC[0m` | `m` p0=0 | Reset `reverse_video`, `fg_override`, `bg_override` |
| `ESC[30-37m` | `m` | Set `fg_override` to ANSI color palette |
| `ESC[40-47m` | `m` | Set `bg_override` to ANSI color palette |
| `ESC[nA/B/C/D` | `A-D` | Move cursor up/down/right/left by n (default 1) |

**8-color palette** (standard ANSI):
```
0=black, 1=red, 2=green, 3=yellow, 4=blue, 5=magenta, 6=cyan, 7=white
```

**Modified `drawGlyph()`:** Use `fg_override`/`bg_override` when set, swap fg/bg when `reverse_video` is true.

**New `clearToEndOfLine()`:** Fill pixels from `(cursor_x, cursor_y)` to end of row with background color.

**New public getters:** `getCols() -> u32`, `getRows() -> u32`.

---

## Step 2: Keyboard Size Query (`src/keyboard.zig`)

Add to `handleCtl()`:
```
} else if (eql(cmd, "size")) {
    // Format "cols rows\n" and push into ring buffer
}
```

Requires a small decimal-formatting helper (or reuse from console). Push the formatted string byte-by-byte into the ring buffer via `pushToRing()`, then call `wakeWaiter()`.

---

## Step 3: Ramfs File Size (`srv/ramfs/main.zig`)

Change `MAX_FILE_SIZE` from `4096` to `32768`. This increases per-node storage by 28 KB. With MAX_NODES=128, total ramfs BSS grows by ~3.5 MB (within the 256 MB RAM budget).

---

## Step 4: Editor (`cmd/fe/main.zig`)

### Data Structures

**Line storage** (BSS):
```
MAX_LINES = 1024, MAX_LINE_LEN = 256
lines: [MAX_LINES]Line  (~260 KB BSS)
Line = struct { data: [MAX_LINE_LEN]u8, len: usize }
```

**Editor state:**
- `mode: enum { normal, insert, command, search }`
- `cursor_row`, `cursor_col` — position in file (0-indexed)
- `view_top` — first visible line index (for scrolling)
- `screen_rows`, `screen_cols` — discovered via `write(0, "size")` + `read(0, buf)`
- `filename`, `modified`, `is_new_file`
- `cmd_buf`, `search_buf` — for `:` and `/` input
- `yank_line` — clipboard for `dd`/`p`
- `count_buf` — for numeric prefix (`5j`, `3dd`, etc.)
- `status_msg` — temporary message ("saved", "not found", etc.)

**Undo stack:**
```
MAX_UNDO = 32
UndoEntry = { op: enum, row, col, char, line: Line }
```
Operations: insert_char, delete_char, insert_line, delete_line, join_lines, split_line, replace_char. `u` pops and reverses. Circular buffer, no redo.

### Key Input

`readKey()` reads from fd 0 in raw mode. Returns a `Key` union:
- `.char: u8` — printable ASCII
- `.ctrl: u8` — Ctrl+letter
- `.arrow_up/down/left/right`, `.home`, `.end_key`
- `.backspace`, `.enter`, `.escape`

ESC sequence parsing: read ESC -> expect `[` -> read final byte (A/B/C/D/H/F).

### Normal Mode Keybindings

| Key | Action |
|-----|--------|
| `h`/Left | Move left |
| `j`/Down | Move down |
| `k`/Up | Move up |
| `l`/Right | Move right |
| `w` | Word forward |
| `b` | Word back |
| `0` | Line start |
| `$` | Line end |
| `G` | Go to last line (or `nG` with count prefix) |
| `gg` | Go to first line |
| `i` | Insert before cursor |
| `a` | Insert after cursor |
| `A` | Insert at end of line |
| `I` | Insert at first non-space |
| `o` | Open line below |
| `O` | Open line above |
| `x` | Delete char under cursor |
| `dd` | Delete line (into yank buffer) |
| `p` | Paste yanked line below |
| `r`+char | Replace char under cursor |
| `/` | Search forward |
| `n` | Next search match |
| `N` | Previous search match |
| `u` | Undo |
| `:` | Enter command mode |

### Insert Mode

- Printable chars -> insert at cursor, shift line right
- Enter -> split line at cursor (new line below)
- Backspace -> delete before cursor (or join with previous line if at col 0)
- ESC -> return to normal mode
- Arrow keys -> movement

### Command Mode

- `:w` — save (remove + create + write in 4KB chunks)
- `:q` — quit (refuse if modified)
- `:wq` — save and quit
- `:q!` — force quit
- `:w filename` — save as
- `:<number>` — go to line
- ESC — cancel command

### Screen Rendering

- Full redraw: iterate visible lines (`view_top` to `view_top + screen_rows - 1`)
- Each line: `moveTo(row, 0)`, write text (truncated to `screen_cols`), `clearToEOL`
- Lines past EOF: display `~`
- Status bar (last row): reverse video, show `-- INSERT --` or `-- NORMAL --`, filename, `[+]` if modified, `line,col`, total lines
- After drawing: park cursor at `(cursor_row - view_top, cursor_col)`

### CSI Output Helpers

Small functions that write escape sequences to stdout (fd 1):
- `moveTo(row, col)` — `ESC[{row+1};{col+1}H`
- `clearScreenCsi()` — `ESC[2J ESC[H`
- `clearLineCsi()` — `ESC[K`
- `setReverse()` / `resetAttr()` — `ESC[7m` / `ESC[0m`

Uses a `formatDecInto(buf, val)` helper to convert numbers to ASCII digits.

### File I/O

**Load:** `open(path)` -> loop `read(fd, 4KB chunk)` -> split on `\n` into `lines[]`.

**Save:** Serialize `lines[]` into flat buffer (join with `\n`) -> `remove(path)` -> `create(path, 0)` -> loop `write(fd, 4KB chunk)`.

### Terminal Setup/Teardown

```
init:  write(0, "rawon"), write(0, "echo off"), write(0, "size"), read(0, size_buf), clear screen
exit:  clear screen, write(0, "rawoff"), write(0, "echo on")
```

---

## Step 5: Build Integration (`build.zig`)

Add after `wc_exe` definition (~line 202):
```zig
const fe_exe = b.addExecutable(.{
    .name = "fe",
    .root_module = b.createModule(.{
        .root_source_file = b.path("cmd/fe/main.zig"),
        .target = x86_64_freestanding,
        .optimize = user_optimize,
        .imports = &.{
            .{ .name = "fornax", .module = fornax_module },
        },
    }),
});
fe_exe.image_base = user_image_base;
```

Add `fe_exe` to initrd array on line 252:
```zig
const x86_initrd = addInitrdStep(b, mkinitrd, "esp/EFI/BOOT", &.{
    ramfs_exe, init_exe, fsh_exe, hello_exe, tcptest_exe, dnstest_exe,
    ping_exe, echo_exe, cat_exe, ls_exe, rm_exe, mkdir_exe, wc_exe, fe_exe,
});
```

---

## Step 6: Shell Alias (`cmd/fsh/main.zig`)

In `executeLine()`, after the builtin dispatch block (around line 878) and before the external command resolution, add:

```zig
// Alias: vi -> fe
var cmd = stage.cmd;
if (fx.str.eql(cmd, "vi")) cmd = "fe";
```

Note: `cmd` is already a `[]const u8` extracted from stage. We just need to shadow/reassign it before it's used in `runExternalWithFds()`.

---

## Implementation Order

1. **Console CSI parser** — prerequisite for everything (Step 1)
2. **Keyboard size query** — small, needed by editor init (Step 2)
3. **Ramfs file size bump** — one-line change (Step 3)
4. **Editor skeleton** — `_start`, terminal init, file load, basic screen draw (Step 4 partial)
5. **Normal mode movement** — h/j/k/l, arrows, w/b, 0/$, G, gg, scrolling
6. **Insert mode** — i/a/A/I/o/O, character insert, newline, backspace
7. **Normal mode editing** — x, dd, p, r
8. **Command mode** — :w, :q, :wq, :q!, :w file, :number
9. **Search** — /, n, N
10. **Undo** — u with circular stack
11. **Count prefix** — numeric prefix for movement/editing commands
12. **Build + alias** — build.zig, initrd, shell vi alias (Steps 5-6)

---

## Verify

1. `make run` — build succeeds with new fe binary in initrd
2. In shell: `fe /boot/hello` — opens the hello binary's embedded path (or any existing file)
3. Create a test file: `echo "hello world" > /tmp/test.txt`
4. `fe /tmp/test.txt` — file displays with status bar at bottom
5. Navigate with h/j/k/l and arrow keys — cursor moves, scrolling works
6. Press `i`, type text, press ESC — insert mode works
7. Press `A` — cursor jumps to end of line, insert mode
8. Press `G` — jumps to last line
9. `/hello` Enter — search finds match, `n`/`N` cycle through
10. `dd` then `p` — delete and paste line
11. `:w` — saves file
12. `:q` — exits to shell, file persists
13. `vi /tmp/test.txt` — alias works, reopens in editor
14. `fe /tmp/newfile.txt` — creating a new file from scratch, `:w` saves it
15. Verify ANSI colors work: a future program can use `ESC[31m` etc.

---

## Estimated Size

| Component | Lines | BSS |
|-----------|-------|-----|
| Console CSI parser + colors | ~100 new | ~30 bytes |
| Keyboard size command | ~20 new | 0 |
| Ramfs change | 1 line | +3.5 MB |
| `cmd/fe/main.zig` | ~1000-1200 | ~270 KB |
| Build + alias | ~20 | N/A |
