/// NVMe (Non-Volatile Memory Express) block device driver.
///
/// PCIe-attached NVMe controller (class 0x01, subclass 0x08, prog_if 0x02).
/// Uses MMIO BAR0 for register access. Admin + I/O submission/completion queues.
/// Provides readBlock/writeBlock for 4096-byte blocks (same API as virtio_blk).

const pmm = @import("pmm.zig");
const klog = @import("klog.zig");
const mem = @import("mem.zig");

const builtin = @import("builtin");

const paging = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/paging.zig"),
    .riscv64 => @import("arch/riscv64/paging.zig"),
    .aarch64 => @import("arch/aarch64/paging.zig"),
    else => struct {
        pub fn physPtr(_: u64) [*]u8 {
            return @ptrFromInt(0);
        }
        pub const Flags = struct {
            pub const WRITABLE: u64 = 0;
            pub const NO_CACHE: u64 = 0;
        };
    },
};

const pci = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/pci.zig"),
    .riscv64 => @import("arch/riscv64/pci.zig"),
    .aarch64 => @import("arch/aarch64/pci.zig"),
    else => struct {
        pub const PciDevice = struct {
            pub fn memBase(_: *const @This(), _: u3) ?u64 {
                return null;
            }
        };
        pub fn findNvme() ?*PciDevice {
            return null;
        }
        pub fn enableBusMastering(_: *const PciDevice) void {}
    },
};

const cpu = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/cpu.zig"),
    .riscv64 => @import("arch/riscv64/cpu.zig"),
    .aarch64 => @import("arch/aarch64/cpu.zig"),
    else => struct {
        pub fn spinHint() void {}
    },
};

// ── NVMe Register Offsets (BAR0 MMIO) ──────────────────────────────────

const REG_CAP = 0x00; // Controller Capabilities (u64)
const REG_VS = 0x08; // Version (u32)
const REG_CC = 0x14; // Controller Configuration (u32)
const REG_CSTS = 0x18; // Controller Status (u32)
const REG_AQA = 0x24; // Admin Queue Attributes (u32)
const REG_ASQ = 0x28; // Admin Submission Queue Base (u64)
const REG_ACQ = 0x30; // Admin Completion Queue Base (u64)

// CC register bits
const CC_EN: u32 = 1 << 0;
const CC_CSS_NVM: u32 = 0 << 4; // NVM command set
const CC_MPS_4K: u32 = 0 << 7; // Memory page size = 4KB (2^(12+0))
const CC_IOSQES_64: u32 = 6 << 16; // I/O SQ entry size = 2^6 = 64 bytes
const CC_IOCQES_16: u32 = 4 << 20; // I/O CQ entry size = 2^4 = 16 bytes

// CSTS register bits
const CSTS_RDY: u32 = 1 << 0;

// Admin command opcodes
const ADMIN_IDENTIFY: u8 = 0x06;
const ADMIN_CREATE_IO_CQ: u8 = 0x05;
const ADMIN_CREATE_IO_SQ: u8 = 0x01;

// NVM command opcodes
const NVM_READ: u8 = 0x02;
const NVM_WRITE: u8 = 0x01;

// Queue sizes (entries)
const ADMIN_QUEUE_SIZE: u16 = 16;
const IO_QUEUE_SIZE: u16 = 64;

// ── DMA Structures (extern struct for hardware layout) ─────────────────

/// NVMe Submission Queue Entry (64 bytes)
const SubmissionEntry = extern struct {
    cdw0: u32, // Opcode[7:0], FUSE[9:8], PSDT[15:14], CID[31:16]
    nsid: u32, // Namespace ID
    cdw2: u32,
    cdw3: u32,
    mptr: u64, // Metadata pointer
    prp1: u64, // PRP Entry 1
    prp2: u64, // PRP Entry 2
    cdw10: u32,
    cdw11: u32,
    cdw12: u32,
    cdw13: u32,
    cdw14: u32,
    cdw15: u32,
};

/// NVMe Completion Queue Entry (16 bytes)
const CompletionEntry = extern struct {
    dw0: u32, // Command-specific
    dw1: u32, // Reserved
    sq_head: u16, // SQ head pointer
    sq_id: u16, // SQ identifier
    cid: u16, // Command ID
    status_phase: u16, // Status[15:1], Phase[0]
};

// ── Queue State ────────────────────────────────────────────────────────

const QueuePair = struct {
    sq_phys: u64, // Submission queue physical base
    cq_phys: u64, // Completion queue physical base
    sq_tail: u16, // SQ producer index
    cq_head: u16, // CQ consumer index
    phase: u1, // Expected CQ phase bit
    size: u16, // Number of entries
    sq_doorbell: u64, // SQ tail doorbell MMIO address
    cq_doorbell: u64, // CQ head doorbell MMIO address
};

// ── Module State ───────────────────────────────────────────────────────

var mmio_base: u64 = 0;
var doorbell_stride: u64 = 4; // bytes, default 4 (2^(2+0))
var admin_queue: QueuePair = undefined;
var io_queue: QueuePair = undefined;
var next_cid: u16 = 1;
var capacity_blocks: u64 = 0; // in 4096-byte blocks
var capacity_sectors: u64 = 0; // in 512-byte sectors
var lba_size: u32 = 512; // bytes per LBA
var initialized: bool = false;

// ── MMIO Helpers (inline asm, same pattern as xhci.zig) ────────────────

fn mmioRead32(addr: u64) u32 {
    if (comptime builtin.cpu.arch == .x86_64) {
        const virt: usize = @intFromPtr(paging.physPtr(addr));
        var result: u32 = undefined;
        asm volatile ("movl (%[addr]), %[result]"
            : [result] "=r" (result),
            : [addr] "r" (virt),
            : .{.memory = true});
        return result;
    } else {
        // riscv64: direct volatile access (identity-mapped or higher-half)
        return cpu.mmioRead32(addr);
    }
}

fn mmioWrite32(addr: u64, val: u32) void {
    if (comptime builtin.cpu.arch == .x86_64) {
        const virt: usize = @intFromPtr(paging.physPtr(addr));
        asm volatile ("movl %[val], (%[addr])"
            :
            : [val] "r" (val), [addr] "r" (virt),
            : .{.memory = true});
    } else {
        cpu.mmioWrite32(addr, val);
    }
}

fn mmioRead64(addr: u64) u64 {
    const lo: u64 = mmioRead32(addr);
    const hi: u64 = mmioRead32(addr + 4);
    return lo | (hi << 32);
}

fn mmioWrite64(addr: u64, val: u64) void {
    mmioWrite32(addr, @truncate(val));
    mmioWrite32(addr + 4, @truncate(val >> 32));
}

fn mapMmioRegion(phys_base: u64, size: u64) bool {
    const kernel_root = if (comptime builtin.cpu.arch == .x86_64)
        paging.getKernelPml4()
    else if (comptime builtin.cpu.arch == .riscv64)
        paging.getKernelRoot()
    else
        return false;
    const flags = paging.Flags.WRITABLE | if (comptime @hasDecl(paging.Flags, "NO_CACHE")) paging.Flags.NO_CACHE else 0;
    const page_size: u64 = 4096;
    var offset: u64 = 0;
    while (offset < size) : (offset += page_size) {
        const phys = (phys_base + offset) & ~@as(u64, 0xFFF);
        const virt = phys +% mem.KERNEL_VIRT_BASE;
        paging.mapPage(kernel_root, virt, phys, flags) orelse {
            return false;
        };
    }
    return true;
}

// ── Doorbell Helpers ───────────────────────────────────────────────────

fn sqDoorbellAddr(qid: u16) u64 {
    return mmio_base + 0x1000 + @as(u64, qid) * 2 * doorbell_stride;
}

fn cqDoorbellAddr(qid: u16) u64 {
    return mmio_base + 0x1000 + (@as(u64, qid) * 2 + 1) * doorbell_stride;
}

// ── Queue Operations ───────────────────────────────────────────────────

fn submitCommand(qp: *QueuePair, cmd: *const SubmissionEntry) void {
    const sq_ptr: [*]u8 = paging.physPtr(qp.sq_phys);
    const offset = @as(usize, qp.sq_tail) * @sizeOf(SubmissionEntry);
    const dest: *volatile SubmissionEntry = @ptrCast(@alignCast(sq_ptr + offset));
    dest.* = cmd.*;
    qp.sq_tail = (qp.sq_tail + 1) % qp.size;

    // Barrier: ensure SQ entry writes are visible before doorbell
    // (see docs/aarch64-gotchas.md §3)
    if (comptime builtin.cpu.arch == .aarch64) {
        asm volatile ("dc cvac, %[addr]" : : [addr] "r" (@intFromPtr(dest)));
        asm volatile ("dsb sy" ::: .{ .memory = true });
    } else if (comptime builtin.cpu.arch == .riscv64) {
        asm volatile ("fence rw, rw" ::: .{ .memory = true });
    }

    // Ring doorbell
    mmioWrite32(qp.sq_doorbell, qp.sq_tail);
}

fn pollCompletion(qp: *QueuePair, expected_cid: u16) bool {
    const cq_ptr: [*]u8 = paging.physPtr(qp.cq_phys);
    var spins: u32 = 0;
    while (spins < 50_000_000) : (spins += 1) {
        const offset = @as(usize, qp.cq_head) * @sizeOf(CompletionEntry);
        const entry: *volatile CompletionEntry = @ptrCast(@alignCast(cq_ptr + offset));
        const sp = entry.status_phase;
        const phase_bit: u1 = @truncate(sp & 1);
        if (phase_bit == qp.phase) {
            // New completion entry
            const status = sp >> 1;
            const cid = entry.cid;
            // Advance CQ head
            qp.cq_head = (qp.cq_head + 1) % qp.size;
            if (qp.cq_head == 0) qp.phase ^= 1;
            // Ring CQ doorbell
            mmioWrite32(qp.cq_doorbell, qp.cq_head);
            if (cid != expected_cid) {
                klog.warn("nvme: CID mismatch got=");
                klog.warnDec(cid);
                klog.warn(" exp=");
                klog.warnDec(expected_cid);
                klog.warn("\n");
                continue;
            }
            if (status != 0) {
                klog.err("nvme: command failed status=0x");
                klog.errHex(status);
                klog.err("\n");
                return false;
            }
            return true;
        }
        cpu.spinHint();
    }
    klog.err("nvme: command timeout CID=");
    klog.errDec(expected_cid);
    klog.err("\n");
    return false;
}

fn allocCid() u16 {
    const cid = next_cid;
    next_cid +%= 1;
    if (next_cid == 0) next_cid = 1;
    return cid;
}

// ── Admin Commands ─────────────────────────────────────────────────────

fn adminIdentify(cns: u32, nsid: u32, data_phys: u64) bool {
    const cid = allocCid();
    var cmd: SubmissionEntry = .{
        .cdw0 = @as(u32, ADMIN_IDENTIFY) | (@as(u32, cid) << 16),
        .nsid = nsid,
        .cdw2 = 0,
        .cdw3 = 0,
        .mptr = 0,
        .prp1 = data_phys,
        .prp2 = 0,
        .cdw10 = cns,
        .cdw11 = 0,
        .cdw12 = 0,
        .cdw13 = 0,
        .cdw14 = 0,
        .cdw15 = 0,
    };
    submitCommand(&admin_queue, &cmd);
    return pollCompletion(&admin_queue, cid);
}

fn adminCreateIoCq(cq_phys: u64, qid: u16, size: u16) bool {
    const cid = allocCid();
    var cmd: SubmissionEntry = .{
        .cdw0 = @as(u32, ADMIN_CREATE_IO_CQ) | (@as(u32, cid) << 16),
        .nsid = 0,
        .cdw2 = 0,
        .cdw3 = 0,
        .mptr = 0,
        .prp1 = cq_phys,
        .prp2 = 0,
        // CDW10: size[31:16] (0-based), QID[15:0]
        .cdw10 = @as(u32, qid) | (@as(u32, size - 1) << 16),
        // CDW11: PC=1 (physically contiguous), IEN=0 (interrupts disabled)
        .cdw11 = 1, // bit 0 = physically contiguous
        .cdw12 = 0,
        .cdw13 = 0,
        .cdw14 = 0,
        .cdw15 = 0,
    };
    submitCommand(&admin_queue, &cmd);
    return pollCompletion(&admin_queue, cid);
}

fn adminCreateIoSq(sq_phys: u64, qid: u16, size: u16, cqid: u16) bool {
    const cid = allocCid();
    var cmd: SubmissionEntry = .{
        .cdw0 = @as(u32, ADMIN_CREATE_IO_SQ) | (@as(u32, cid) << 16),
        .nsid = 0,
        .cdw2 = 0,
        .cdw3 = 0,
        .mptr = 0,
        .prp1 = sq_phys,
        .prp2 = 0,
        // CDW10: size[31:16] (0-based), QID[15:0]
        .cdw10 = @as(u32, qid) | (@as(u32, size - 1) << 16),
        // CDW11: PC=1, QPRIO=0 (urgent), CQID[31:16]
        .cdw11 = 1 | (@as(u32, cqid) << 16), // bit 0 = physically contiguous
        .cdw12 = 0,
        .cdw13 = 0,
        .cdw14 = 0,
        .cdw15 = 0,
    };
    submitCommand(&admin_queue, &cmd);
    return pollCompletion(&admin_queue, cid);
}

// ── Init ───────────────────────────────────────────────────────────────

pub fn init() bool {
    if (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .riscv64 and builtin.cpu.arch != .aarch64) return false;

    const dev = pci.findNvme() orelse {
        klog.debug("nvme: no controller found\n");
        return false;
    };

    klog.info("nvme: found at PCI ");
    klog.infoDec(dev.bus);
    klog.info(":");
    klog.infoDec(dev.slot);
    klog.info(".");
    klog.infoDec(dev.func);
    klog.info("\n");

    // Enable bus mastering + memory space
    pci.enableBusMastering(dev);

    // Read BAR0 (64-bit MMIO)
    mmio_base = dev.memBase(0) orelse {
        klog.err("nvme: BAR0 not memory-mapped\n");
        return false;
    };

    // Map MMIO region if above 4 GB
    if (mmio_base >= 0x1_0000_0000) {
        if (!mapMmioRegion(mmio_base, 0x10000)) {
            klog.err("nvme: failed to map MMIO region\n");
            return false;
        }
    }

    // Read capabilities
    const cap = mmioRead64(mmio_base + REG_CAP);
    const mqes: u16 = @truncate((cap & 0xFFFF) + 1); // Maximum Queue Entries Supported (0-based)
    const dstrd: u4 = @truncate((cap >> 32) & 0xF); // Doorbell Stride
    const timeout_500ms: u8 = @truncate((cap >> 24) & 0xFF); // Timeout in 500ms units
    doorbell_stride = @as(u64, 4) << dstrd;

    _ = mqes;
    _ = timeout_500ms;

    const vs = mmioRead32(mmio_base + REG_VS);
    klog.info("nvme: version ");
    klog.infoDec((vs >> 16) & 0xFFFF);
    klog.info(".");
    klog.infoDec((vs >> 8) & 0xFF);
    klog.info(".");
    klog.infoDec(vs & 0xFF);
    klog.info("\n");

    // Disable controller
    var cc = mmioRead32(mmio_base + REG_CC);
    cc &= ~CC_EN;
    mmioWrite32(mmio_base + REG_CC, cc);

    // Wait for CSTS.RDY == 0
    var spins: u32 = 0;
    while (mmioRead32(mmio_base + REG_CSTS) & CSTS_RDY != 0) : (spins += 1) {
        if (spins > 50_000_000) {
            klog.err("nvme: timeout disabling controller\n");
            return false;
        }
        cpu.spinHint();
    }

    // Allocate admin queues
    const asq_phys = pmm.allocPage() orelse {
        klog.err("nvme: OOM admin SQ\n");
        return false;
    };
    const acq_phys = pmm.allocPage() orelse {
        klog.err("nvme: OOM admin CQ\n");
        pmm.freePage(asq_phys);
        return false;
    };

    // Zero queue pages
    zeroPage(asq_phys);
    zeroPage(acq_phys);

    // Configure admin queue attributes
    // AQA: ACQS[27:16] (0-based), ASQS[11:0] (0-based)
    const aqa: u32 = (@as(u32, ADMIN_QUEUE_SIZE - 1) << 16) | (ADMIN_QUEUE_SIZE - 1);
    mmioWrite32(mmio_base + REG_AQA, aqa);
    mmioWrite64(mmio_base + REG_ASQ, asq_phys);
    mmioWrite64(mmio_base + REG_ACQ, acq_phys);

    // Enable controller
    cc = CC_EN | CC_CSS_NVM | CC_MPS_4K | CC_IOSQES_64 | CC_IOCQES_16;
    mmioWrite32(mmio_base + REG_CC, cc);

    // Wait for CSTS.RDY == 1
    spins = 0;
    while (mmioRead32(mmio_base + REG_CSTS) & CSTS_RDY == 0) : (spins += 1) {
        if (spins > 50_000_000) {
            klog.err("nvme: timeout enabling controller\n");
            pmm.freePage(asq_phys);
            pmm.freePage(acq_phys);
            return false;
        }
        cpu.spinHint();
    }

    // Initialize admin queue state
    admin_queue = .{
        .sq_phys = asq_phys,
        .cq_phys = acq_phys,
        .sq_tail = 0,
        .cq_head = 0,
        .phase = 1,
        .size = ADMIN_QUEUE_SIZE,
        .sq_doorbell = sqDoorbellAddr(0),
        .cq_doorbell = cqDoorbellAddr(0),
    };

    // Identify Controller (CNS=1)
    const identify_phys = pmm.allocPage() orelse {
        klog.err("nvme: OOM identify\n");
        return false;
    };
    zeroPage(identify_phys);

    if (!adminIdentify(1, 0, identify_phys)) {
        klog.err("nvme: identify controller failed\n");
        pmm.freePage(identify_phys);
        return false;
    }

    // Parse Identify Controller data (4096 bytes)
    const id_ptr: [*]u8 = paging.physPtr(identify_phys);

    // MDTS at byte 77 (Maximum Data Transfer Size, units of minimum page size power)
    const mdts = id_ptr[77];
    if (mdts > 0) {
        klog.debug("nvme: MDTS=");
        klog.debugDec(mdts);
        klog.debug("\n");
    }

    // Identify Namespace 1 (CNS=0, NSID=1)
    zeroPage(identify_phys);
    if (!adminIdentify(0, 1, identify_phys)) {
        klog.err("nvme: identify namespace failed\n");
        pmm.freePage(identify_phys);
        return false;
    }

    // Parse Identify Namespace data
    // NSZE at bytes 0-7 (namespace size in logical blocks)
    const nsze = @as(u64, id_ptr[0]) | (@as(u64, id_ptr[1]) << 8) |
        (@as(u64, id_ptr[2]) << 16) | (@as(u64, id_ptr[3]) << 24) |
        (@as(u64, id_ptr[4]) << 32) | (@as(u64, id_ptr[5]) << 40) |
        (@as(u64, id_ptr[6]) << 48) | (@as(u64, id_ptr[7]) << 56);

    // FLBAS at byte 26 — bits [3:0] index into LBAF table
    const flbas = id_ptr[26];
    const lbaf_index = flbas & 0x0F;

    // LBAF table starts at byte 128, each entry is 4 bytes
    // LBAF[n] byte 2 = LBADS (LBA Data Size as power of 2)
    const lbaf_offset: usize = 128 + @as(usize, lbaf_index) * 4;
    const lbads = id_ptr[lbaf_offset + 2];
    lba_size = @as(u32, 1) << @intCast(lbads);

    pmm.freePage(identify_phys);

    // Calculate capacity
    capacity_sectors = nsze * (lba_size / 512);
    capacity_blocks = (nsze * lba_size) / 4096;

    const mb = capacity_blocks * 4 / 1024; // blocks * 4KB / 1MB
    klog.info("nvme: ");
    klog.infoDec(nsze);
    klog.info(" LBAs, ");
    klog.infoDec(lba_size);
    klog.info("B/LBA, ");
    klog.infoDec(mb);
    klog.info(" MB\n");

    // Create I/O Completion Queue (QID=1)
    const io_cq_phys = pmm.allocPage() orelse {
        klog.err("nvme: OOM I/O CQ\n");
        return false;
    };
    zeroPage(io_cq_phys);

    if (!adminCreateIoCq(io_cq_phys, 1, IO_QUEUE_SIZE)) {
        klog.err("nvme: create I/O CQ failed\n");
        pmm.freePage(io_cq_phys);
        return false;
    }

    // Create I/O Submission Queue (QID=1, associated CQ=1)
    // IO_QUEUE_SIZE * 64 = 4096 bytes = 1 page for 64 entries
    const io_sq_phys = pmm.allocPage() orelse {
        klog.err("nvme: OOM I/O SQ\n");
        return false;
    };
    zeroPage(io_sq_phys);

    if (!adminCreateIoSq(io_sq_phys, 1, IO_QUEUE_SIZE, 1)) {
        klog.err("nvme: create I/O SQ failed\n");
        pmm.freePage(io_sq_phys);
        return false;
    }

    // Initialize I/O queue state
    io_queue = .{
        .sq_phys = io_sq_phys,
        .cq_phys = io_cq_phys,
        .sq_tail = 0,
        .cq_head = 0,
        .phase = 1,
        .size = IO_QUEUE_SIZE,
        .sq_doorbell = sqDoorbellAddr(1),
        .cq_doorbell = cqDoorbellAddr(1),
    };

    klog.info("nvme: ready\n");
    initialized = true;
    return true;
}

// ── Block I/O ──────────────────────────────────────────────────────────

pub fn readBlock(block: u64, buf: *[4096]u8) bool {
    if (!initialized) return false;
    if (block >= capacity_blocks) return false;

    // Allocate DMA page
    const data_phys = pmm.allocPage() orelse {
        klog.err("nvme: read OOM blk=");
        klog.errDec(block);
        klog.err("\n");
        return false;
    };

    // Build NVM Read command
    const lbas_per_block = 4096 / lba_size;
    const slba = block * lbas_per_block;
    const nlb: u32 = @intCast(lbas_per_block - 1); // 0-based
    const cid = allocCid();

    var cmd: SubmissionEntry = .{
        .cdw0 = @as(u32, NVM_READ) | (@as(u32, cid) << 16),
        .nsid = 1,
        .cdw2 = 0,
        .cdw3 = 0,
        .mptr = 0,
        .prp1 = data_phys,
        .prp2 = 0, // Single page, no PRP list needed for 4KB
        .cdw10 = @truncate(slba), // SLBA low
        .cdw11 = @truncate(slba >> 32), // SLBA high
        .cdw12 = nlb, // NLB (0-based)
        .cdw13 = 0,
        .cdw14 = 0,
        .cdw15 = 0,
    };

    submitCommand(&io_queue, &cmd);

    if (!pollCompletion(&io_queue, cid)) {
        pmm.freePage(data_phys);
        return false;
    }

    // Copy DMA buffer to caller
    const data_ptr: [*]u8 = paging.physPtr(data_phys);
    @memcpy(buf, data_ptr[0..4096]);
    pmm.freePage(data_phys);
    return true;
}

pub fn writeBlock(block: u64, buf: *const [4096]u8) bool {
    if (!initialized) return false;
    if (block >= capacity_blocks) return false;

    // Allocate DMA page
    const data_phys = pmm.allocPage() orelse {
        klog.err("nvme: write OOM blk=");
        klog.errDec(block);
        klog.err("\n");
        return false;
    };

    // Copy caller data to DMA buffer
    const data_ptr: [*]u8 = paging.physPtr(data_phys);
    @memcpy(data_ptr[0..4096], buf);

    // Build NVM Write command
    const lbas_per_block = 4096 / lba_size;
    const slba = block * lbas_per_block;
    const nlb: u32 = @intCast(lbas_per_block - 1);
    const cid = allocCid();

    var cmd: SubmissionEntry = .{
        .cdw0 = @as(u32, NVM_WRITE) | (@as(u32, cid) << 16),
        .nsid = 1,
        .cdw2 = 0,
        .cdw3 = 0,
        .mptr = 0,
        .prp1 = data_phys,
        .prp2 = 0,
        .cdw10 = @truncate(slba),
        .cdw11 = @truncate(slba >> 32),
        .cdw12 = nlb,
        .cdw13 = 0,
        .cdw14 = 0,
        .cdw15 = 0,
    };

    submitCommand(&io_queue, &cmd);

    if (!pollCompletion(&io_queue, cid)) {
        pmm.freePage(data_phys);
        return false;
    }

    pmm.freePage(data_phys);
    return true;
}

// ── Public API ─────────────────────────────────────────────────────────

pub fn isInitialized() bool {
    return initialized;
}

pub fn getCapacitySectors() u64 {
    return capacity_sectors;
}

pub fn getCapacityBlocks() u64 {
    return capacity_blocks;
}

// ── Helpers ────────────────────────────────────────────────────────────

fn zeroPage(phys: u64) void {
    const ptr: [*]u8 = paging.physPtr(phys);
    @memset(ptr[0..4096], 0);
}
