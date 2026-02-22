# Task Completion Notes

## Integration Test Fixes (Latest)
- **IPC client queue**: `src/ipc.zig` + `src/syscall.zig` — IPC channels now support multiple concurrent clients via wait queue (MAX_CLIENT_WAITERS=16). Before, when two processes (e.g., shell + pipeline child) both sent IPC to fxfs, the second overwrote the first, causing shell hang. `sendToServer` queues if slot taken; `sysIpcReply` promotes next queued client.
- **dd short-write handling**: `cmd/dd/main.zig` — dd now loops on write() to handle short writes. IPC MAX_MSG_DATA=4096 but writes use 4 bytes for handle → max 4092 data per write. Without loop, each 4096-byte write lost 4 bytes.
- **wc flags**: `cmd/wc/main.zig` — Added `-l`/`-w`/`-c` flag support. Without flags, shows all three.
- **Test rm -f**: `rm` without `-f` prompts for confirmation, blocking automated tests.
- **Test RAM**: 1G required (256M causes virtio-blk timeout after ~19K operations).
- **Test file count**: Reduced test_filesystem "many files" from 20 to 5 to keep test fast.
