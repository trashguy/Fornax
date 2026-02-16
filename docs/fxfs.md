# fxfs — Fornax Filesystem

## Design Philosophy

fxfs is a persistent filesystem for Fornax, blending ideas from three proven designs:

- **ext2**: Inodes as the unit of file metadata, directory entries mapping names to
  inode numbers, bitmap-based block allocation, superblock with backup copy.
- **XFS**: Extent-based data storage — file data is tracked as contiguous block
  ranges rather than individual block pointers, reducing metadata overhead for
  large files.
- **btrfs**: Copy-on-Write (CoW) B-tree for all metadata. Every mutation creates
  new blocks, writing a new path from leaf to root. The old tree remains valid
  until the superblock is atomically updated, providing crash consistency without
  a journal.

fxfs runs as a userspace server (`srv/fxfs/main.zig`), communicating with the
kernel and other processes via IPC messages over file descriptors. The block device
is accessed through `pread`/`pwrite` syscalls on fd 4.

## On-Disk Format

### Block Size

Fixed at **4096 bytes**. All structures are block-aligned.

### Disk Layout

```
Block 0:    Primary superblock
Block 1:    Backup superblock
Block 2+:   Bitmap (1 or more blocks)
Block N:    Data start (B-tree nodes + file data blocks)
```

The exact positions are stored in the superblock: `bitmap_start` and `data_start`.

### Superblock (80 bytes at block 0)

```
Offset  Size  Field
------  ----  -----
 0       8    magic           "FXFS0001"
 8       4    block_size      4096
12       4    (padding)
16       8    total_blocks    Total blocks in filesystem
24       8    tree_root       Block number of B-tree root node
32       8    next_inode      Next inode number to allocate
40       8    free_blocks     Count of free blocks
48       8    generation      Transaction generation counter
56       8    bitmap_start    Block number of first bitmap block
64       8    data_start      Block number of first data block
72       4    (reserved)
76       4    checksum        CRC32 of bytes 0..79
```

A backup copy is written to block 1. On mount, the primary is loaded. If
checksum validation fails, the backup can be used as a fallback.

### B-tree Nodes

All metadata lives in a single B-tree. Nodes are one block (4096 bytes) each.

#### Node Header (16 bytes)

```
Offset  Size  Field
------  ----  -----
 0       1    level           0 = leaf, 1+ = internal
 1       2    num_items       Number of items (leaf) or keys (internal)
 3       1    (padding)
 4       8    generation      Transaction generation when written
12       4    checksum        CRC32 of the full block
```

#### Leaf Nodes (level = 0)

Items are stored in **sorted key order**. Headers grow forward from byte 16,
data grows backward from byte 4095. This dual-cursor layout maximizes space
utilization.

```
[Header 16B] [ItemHdr 0] [ItemHdr 1] ... [ItemHdr N] ... [Data N] ... [Data 1] [Data 0]
```

Each **Leaf Item Header** is 21 bytes:

```
Offset  Size  Field
------  ----  -----
 0       8    key.inode_nr    Inode number
 8       1    key.item_type   Item type (1=INODE, 2=DIR_ENTRY, 3=EXTENT_DATA)
 9       8    key.offset      Type-specific offset
17       2    data_offset     Byte offset of item data within the block
19       2    data_size       Size of item data in bytes
```

**Capacity**: With 21-byte headers and variable-size data, a leaf typically holds
60-100+ items depending on data sizes. Maximum header slots: (4096 - 16) / 21 = 194.

#### Internal Nodes (level >= 1)

Internal nodes store separator keys and child block pointers.

```
[Header 16B] [Key 0] [Key 1] ... [Key N-1] [Child 0] [Child 1] ... [Child N]
```

Each **key** is 17 bytes (same layout as leaf item keys, without data_offset/size).
Each **child pointer** is 8 bytes (block number). Children are stored contiguously
after all keys.

For N keys, there are N+1 children. Child[i] points to the subtree containing
all keys < Key[i]. Child[N] contains keys >= Key[N-1].

**Capacity**: (4096 - 16) / (17 + 8) = 163 keys per internal node.

### Keys

Keys provide a total ordering over all items in the B-tree:

```
(inode_nr: u64, item_type: u8, offset: u64)
```

Comparison is lexicographic: first by `inode_nr`, then `item_type`, then `offset`.
This groups all items for an inode together and orders them by type, which
enables efficient range scans (e.g., listing all directory entries for an inode).

### Item Types

#### INODE_ITEM (type = 1)

Stores file/directory metadata. Key: `(inode_nr, 1, 0)`.

```
Offset  Size  Field
------  ----  -----
 0       2    mode      File type + permissions (S_IFDIR|0755, S_IFREG|0644)
 2       2    uid       User ID
 4       2    gid       Group ID
 6       2    nlinks    Hard link count
 8       8    size      File size in bytes
16       8    atime     Access time (epoch seconds)
24       8    mtime     Modification time (epoch seconds)
32       8    ctime     Change time (epoch seconds)
```

Total: **40 bytes**.

Mode constants: `S_IFDIR = 0o040000`, `S_IFREG = 0o100000`, `S_IFMT = 0o170000`.

#### DIR_ENTRY (type = 2)

Maps a filename to an inode within a parent directory. Key: `(parent_inode, 2, name_hash)`.

The `offset` field contains an FNV-1a hash of the filename, enabling O(1) lookup
for the common case (no hash collisions). On collision, a full scan of the
directory's DIR_ENTRY items is performed.

```
Offset  Size  Field
------  ----  -----
 0       8    inode_nr    Target inode number
 8       1    file_type   DT_REG(1) or DT_DIR(2)
 9       1    name_len    Length of filename
10       N    name        Filename bytes (up to 255)
```

Total: **10 + name_len** bytes.

#### EXTENT_DATA (type = 3)

Stores file content. Key: `(inode_nr, 3, file_offset)`.

**Inline data** (small files, <= 3800 bytes): The item data contains the raw file
content directly. Identified by `data_size != 16` or `disk_block == 0`.

**Extent reference** (large files): Points to contiguous disk blocks.

```
Offset  Size  Field
------  ----  -----
 0       8    disk_block    First block number on disk
 8       4    num_blocks    Number of contiguous blocks
12       4    (reserved)
```

Total: **16 bytes** (EXTENT_DATA_SIZE).

The extent covers bytes `[file_offset, file_offset + num_blocks * 4096)`.

### Bitmap Allocator

Free/allocated status of every block is tracked in a bitmap starting at
`bitmap_start`. Each bit represents one block: 0 = free, 1 = allocated.

One bitmap block (4096 bytes = 32,768 bits) covers 32,768 blocks = 128 MB.

Blocks 0 through `data_start - 1` (superblocks + bitmap) are always marked
allocated. The allocator scans linearly from `data_start` to find free blocks.

## IPC Protocol

fxfs communicates via `IpcMessage` structs (tag + data_len + 4096-byte data buffer)
over IPC fd 3.

### Operations

| Tag | Name | Request Data | Response Data |
|-----|------|-------------|---------------|
| 1 | T_OPEN | path (bytes) | handle_id (u32) |
| 7 | T_CREATE | flags (u32) + path (bytes) | handle_id (u32) |
| 2 | T_READ | handle_id (u32) + offset (u32) + count (u32) | file data (bytes) |
| 3 | T_WRITE | handle_id (u32) + data (bytes) | bytes_written (u32) |
| 4 | T_CLOSE | handle_id (u32) | (empty) |
| 5 | T_STAT | handle_id (u32) | size (u32) + is_dir (u32) + padding |
| 8 | T_REMOVE | path (bytes) | (empty) |

Responses use tag `R_OK` (128) on success or `R_ERROR` (129) on failure.

### Handles

The server maintains up to 32 handles, each tracking:
- `inode_nr`: The inode this handle refers to
- `write_offset`: Current write position (advanced after each write)
- `active`: Whether the handle is in use

Handles are allocated on open/create and freed on close.

### Create Flags

The flags field in T_CREATE is a bitmask:
- Bit 0 (`0x1`): Create directory (S_IFDIR) instead of regular file
- Bit 1 (`0x2`): Append mode — set initial write_offset to file size

If the path already exists, T_CREATE returns a handle to the existing file
(with append offset if requested) rather than failing.

### Virtual ctl File

Opening path `"ctl"` returns a handle to a virtual file that, when read, returns
filesystem statistics:

```
TOTAL=<total_blocks>
FREE=<free_blocks>
BSIZE=4096
```

This is used by the `df` command.

## Data Storage

### Inline vs Extent

Files up to **3800 bytes** are stored inline — the raw content is placed directly
in the B-tree leaf as the EXTENT_DATA item's data payload. This avoids allocating
separate data blocks for small files.

Files larger than 3800 bytes use **extent references**. The server allocates
contiguous disk blocks, writes file data to them, and stores an ExtentData
record (disk_block + num_blocks) in the B-tree.

### Write Path

1. If `write_offset + data_len <= 3800`: store inline
   - Read existing inline data (if any) into a 3800-byte buffer
   - Overlay new data at the write offset
   - Delete old EXTENT_DATA item, insert new one with combined content
2. If data exceeds 3800 bytes: allocate extent
   - Calculate number of blocks needed
   - Allocate contiguous blocks via bitmap
   - Write data blocks to disk
   - Delete old EXTENT_DATA, insert extent reference

### Read Path

1. Look up EXTENT_DATA item for the inode at offset 0
2. If data is exactly 16 bytes with `disk_block > 0`: read from extent
   - Calculate target block from file_offset
   - Read block via pread, extract requested bytes
3. Otherwise: data is inline
   - Return bytes directly from the B-tree leaf

## Copy-on-Write Transaction Model

Every mutation follows the CoW pattern:

1. **Read** the target leaf node
2. **Build** a new leaf in memory with the modification applied
3. **Allocate** a new block for the modified leaf
4. **Write** the new leaf to the new block
5. **Free** the old leaf block
6. **CoW the path**: for each ancestor from leaf to root, create a new copy
   with the updated child pointer
7. **Update** `sb_tree_root` to the new root block
8. **Commit**: increment generation, flush bitmap, write both superblocks

The key property: the old superblock points to the old root, which points to
the old tree. Until step 8 completes, the old tree is fully intact. If the
system crashes mid-mutation, the old superblock is still valid.

### Generation Counter

Every node written includes the current `generation + 1`. The superblock records
the committed generation. This allows detecting stale nodes from incomplete
transactions.

### Path CoW (`cowPath`)

After modifying a leaf, `cowPath` walks the recorded path from leaf to root:
- For each internal node in the path, copy it to a new block with the updated
  child pointer
- Free the old block
- The final block becomes the new root

## Hash Function

Directory entry offsets use **FNV-1a** hash of the filename:

```
hash = 0x811c9dc5 (FNV offset basis)
for each byte b in name:
    hash ^= b
    hash *%= 0x01000193 (FNV prime)
return hash as u64
```

This provides good distribution for typical filenames and enables direct B-tree
lookup for directory entries without scanning.

## Block Cache

A simple 16-entry read cache (`cache_blocks` + `cache_entries`) reduces disk reads:
- `readBlockCached()`: check cache first, fall back to `readBlock()` (pread)
- `cacheInsert()`: add/replace entry (LRU by use_count)
- `cacheInvalidate()`: remove entry when a block is freed

The cache holds raw 4096-byte blocks indexed by block number.

## Filesystem Formatting

### Runtime Formatting (`formatDisk`)

If no valid superblock is found on mount, fxfs formats the device:
1. Binary-search probe to determine disk size
2. Calculate bitmap/data layout
3. Write bitmap with system blocks marked allocated
4. Write root B-tree leaf containing inode 1 (root directory, S_IFDIR|0755)
5. Write primary + backup superblocks

### Host Formatting (`mkfxfs`)

The `tools/mkfxfs.zig` host tool creates fxfs images with pre-populated content:
- `--offset <bytes>`: Start at partition offset within image
- `--size <bytes>`: Limit filesystem size
- `--add <host-path>:<fs-path>`: Add individual files
- `--populate <dir>`: Recursively add directory contents

mkfxfs collects all items, sorts by key, builds leaves with a dual-cursor
`LeafBuilder`, and creates an internal root node if multiple leaves are needed.

## File Type Constants

| Constant | Value | Meaning |
|----------|-------|---------|
| S_IFDIR | 0o040000 | Directory |
| S_IFREG | 0o100000 | Regular file |
| S_IFMT | 0o170000 | Type mask |
| DT_REG | 1 | Regular file (dir entry) |
| DT_DIR | 2 | Directory (dir entry) |
| INODE_ITEM | 1 | Inode metadata |
| DIR_ENTRY | 2 | Directory entry |
| EXTENT_DATA | 3 | File data (inline or extent) |
