# Phase 211: `syslogd` — Userspace Syslog Server

## Status: Planned

## Depends On

- Filesystem mount hierarchy / fstab (TBD phase number)

## Goal

Kernel messages go through klog (`dmesg`), but userspace servers and init have no structured logging — their debug prints either clutter the console or get removed. A **syslogd** IPC server provides `/var/log/syslog` as a ring-buffer-backed virtual file. Any process can write diagnostics there; `syslog` command reads them.

---

## Design

- **syslogd** mounts at `/var/log/`, serves one virtual file: `syslog`
- 64 KB ring buffer (matches klog), offset-based reads
- Writing appends to ring buffer, reading returns from offset
- **syslog** command reads `/var/log/syslog` (like `dmesg` for userspace)
- Servers write startup/debug messages to `/var/log/syslog` instead of stdout

---

## Files to Modify

| File | Action |
|------|--------|
| `srv/syslogd/main.zig` | **Create** — ring buffer IPC server |
| `cmd/syslog/main.zig` | **Create** — syslog reader command |
| `src/main.zig` | Add `spawnSyslogd()` between ramfs and partfs |
| `build.zig` | Add syslogd_exe + syslog_exe + initrd entries |
| `srv/partfs/main.zig` | Open `/var/log/syslog`, write startup messages there |
| `srv/fxfs/main.zig` | Open `/var/log/syslog`, write startup messages there |
| `cmd/init/main.zig` | Redirect debug prints to `/var/log/syslog` |

---

## Step 1: syslogd Server (`srv/syslogd/main.zig`)

Ring buffer (same design as kernel klog):
- `ring: [65536]u8 linksection(".bss")` — 64 KB circular buffer
- `write_pos: u32 = 0` — current write position in ring
- `total_written: u32 = 0` — monotonic counter for offset-based reads
- Handle 1 for the `syslog` file, tracked via `open_handles: u32`

IPC message handlers:
- **T_OPEN**: path empty or "syslog" → return handle 1, increment open_handles
- **T_WRITE**: `data[0..4]` = handle, `data[4..data_len]` = payload → append to ring buffer, reply R_OK with bytes written
- **T_READ**: `data[0..4]` = handle, `data[4..8]` = offset, `data[8..12]` = count → read from ring at offset, reply R_OK with data. EOF if offset >= total_written. Skip to earliest if offset < (total_written - 65536)
- **T_STAT**: return total_written as file size, type=0 (file)
- **T_CLOSE**: decrement open_handles
- **T_CTL / T_CREATE / T_REMOVE**: R_ERROR (not supported)

Pattern follows `srv/ramfs/main.zig`: BSS message buffers, SERVER_FD=3, recv/dispatch/reply loop.

---

## Step 2: syslog Command (`cmd/syslog/main.zig`)

Mirrors `cmd/dmesg/main.zig`:
```
open("/var/log/syslog") → fd
loop: read(fd, buf, 4096) → n; if n==0 break; write(1, buf[0..n])
close(fd)
exit(0)
```

---

## Step 3: Kernel Spawn (`src/main.zig`)

Add `spawnSyslogd()` following the `spawnRamfs()` pattern:
- Find "syslogd" in initrd
- Create process, load ELF, allocate stack
- Create IPC channel, set fd 3 = server end
- Mount client end at `/var/log/` in root namespace
- Clone namespace into process

Boot order: `spawnRamfs()` → `spawnSyslogd()` → `spawnPartfs()` → `spawnFxfs()` → `spawnInit()`

---

## Step 4: Build Integration (`build.zig`)

- Add `syslogd_exe` (srv pattern, like partfs_exe)
- Add `syslog_exe` (cmd pattern, like dmesg_exe)
- Add both to initrd array

---

## Step 5: Server Integration

**`srv/partfs/main.zig`**: Open `/var/log/syslog` at startup, write "partfs: starting\n" and "partfs: ready\n"

**`srv/fxfs/main.zig`**: Open `/var/log/syslog` at startup, write "fxfs: starting\n" and "fxfs: ready\n"

**`cmd/init/main.zig`**: Open `/var/log/syslog`, redirect debug prints there. Keep error messages on stdout (critical).

**`srv/ramfs/main.zig`**: No change — ramfs starts before syslogd, can't log to it.

---

## Verify

1. `make run` — builds cleanly
2. Boot to shell — no server/init debug output on console
3. Run `syslog` — see partfs/fxfs/init startup messages in the log
4. Run `dmesg` — still works (kernel log separate from userspace log)
5. Serial output unaffected
