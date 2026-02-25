/// AArch64 ARMv8-A 4-level paging (4KB granule, 48-bit VA).
///
/// Page table structure mirrors x86_64/riscv64: L3 → L2 → L1 → L0 (root is L3).
/// TTBR1_EL1 = kernel (upper half, never changes).
/// TTBR0_EL1 = user (lower half, switched per-process).
///
/// Descriptor format (4KB granule):
///   Table descriptor (non-leaf): [47:12]=next table addr, [1:0]=0b11
///   Page descriptor (leaf at L0): [47:12]=OA, [1:0]=0b11, + attribute bits
///   Block descriptor (leaf at L1=2MB, L2=1GB): [47:21/30]=OA, [1:0]=0b01
///
/// Attribute bits (for page/block descriptors):
///   [54] UXN (User Execute Never)
///   [53] PXN (Privileged Execute Never)
///   [10] AF (Access Flag) — must be set, else access fault
///   [9:8] SH (Shareability): 0b11=Inner Shareable
///   [7:6] AP (Access Permission): AP[2:1]
///         AP[2]=0 → read/write, AP[2]=1 → read-only
///         AP[1]=1 → EL0 accessible (user)
///   [4:2] AttrIndx (index into MAIR_EL1)
///   [1:0] 0b11=page/table, 0b01=block
const klog = @import("../../klog.zig");
const pmm = @import("../../pmm.zig");
const mem = @import("../../mem.zig");
const cpu = @import("cpu.zig");

const PAGE_SIZE = mem.PAGE_SIZE;

/// AArch64 page table flag bits.
/// Named for compatibility with x86_64/riscv64 paging API.
pub const Flags = struct {
    /// Valid descriptor (bit 0). For table/page: bits [1:0]=0b11.
    pub const PRESENT: u64 = 0x3; // valid page/table descriptor
    /// Writable: AP[2]=0. Since AP[2]=1 means read-only, we represent
    /// "writable" as 0 (default is RW) and apply RO when WRITABLE is absent.
    /// For the API: WRITABLE=0 means "caller sets this to indicate writable".
    /// We handle the inversion in mapPage().
    pub const WRITABLE: u64 = 1 << 51; // software flag — handled in mapPage
    /// User accessible: AP[1]=1 (bit 6).
    pub const USER: u64 = 1 << 6;
    /// Executable: no-op on aarch64 (pages are executable by default).
    /// Non-executable is controlled by UXN/PXN bits.
    pub const EXEC: u64 = 0;

    // Internal hardware bits
    pub const AF: u64 = 1 << 10; // Access Flag
    pub const SH_INNER: u64 = 0x3 << 8; // Inner Shareable
    pub const ATTR_NORMAL: u64 = 0 << 2; // MAIR index 0 (normal memory)
    pub const ATTR_DEVICE: u64 = 1 << 2; // MAIR index 1 (device memory)
    pub const UXN: u64 = 1 << 54; // User Execute Never
    pub const PXN: u64 = 1 << 53; // Privileged Execute Never
    pub const AP_RO: u64 = 1 << 7; // AP[2]=1 → read-only
    pub const BLOCK: u64 = 0x1; // Block descriptor (leaf at L1/L2)
};

/// A page table is 512 entries of 8 bytes each (4KB total).
pub const PageTable = struct {
    entries: [512]u64,

    pub fn zero(self: *PageTable) void {
        for (&self.entries) |*e| {
            e.* = 0;
        }
    }
};

/// Kernel root page table physical address (TTBR1).
var kernel_root_phys: u64 = 0;

/// User identity-map root physical address (TTBR0 during kernel init).
var user_root_phys: u64 = 0;

/// Whether paging has been initialized.
var initialized: bool = false;

pub fn isInitialized() bool {
    return initialized;
}

/// Convert a physical address to a PageTable pointer.
inline fn tablePtr(phys: u64) *PageTable {
    return @ptrFromInt(if (initialized) phys +% mem.KERNEL_VIRT_BASE else phys);
}

/// Convert a physical address to a byte pointer.
pub inline fn physPtr(phys: u64) [*]u8 {
    return @ptrFromInt(if (initialized) phys +% mem.KERNEL_VIRT_BASE else phys);
}

/// Extract OA (Output Address) from a table descriptor: bits [47:12].
inline fn pteToPhys(pte: u64) u64 {
    return pte & 0x0000_FFFF_FFFF_F000;
}

/// Check if descriptor is valid (bit 0 set).
inline fn isValid(pte: u64) bool {
    return pte & 0x1 != 0;
}

/// Check if descriptor is a block (leaf): bits [1:0] = 0b01, or
/// a page descriptor at L0: bits [1:0] = 0b11. Both are leaf entries.
/// Table descriptors (non-leaf) at L3/L2/L1 have [1:0]=0b11 but NO
/// attribute bits like AF/SH/AP — we distinguish by checking AF.
/// Simpler: at L0 everything valid is a leaf; at L1/L2, blocks have [1:0]=0b01.
inline fn isBlock(pte: u64) bool {
    return (pte & 0x3) == 0x1; // block descriptor
}

/// Standard leaf attributes for normal memory pages.
const LEAF_ATTRS: u64 = Flags.PRESENT | Flags.AF | Flags.SH_INNER | Flags.ATTR_NORMAL;

/// Standard leaf attributes for device memory (identity-mapped MMIO).
const DEVICE_LEAF_ATTRS: u64 = Flags.PRESENT | Flags.AF | Flags.ATTR_DEVICE | Flags.PXN | Flags.UXN;

/// Block descriptor attributes for 2MB normal memory (identity/higher-half map).
const BLOCK_ATTRS: u64 = Flags.BLOCK | Flags.AF | Flags.SH_INNER | Flags.ATTR_NORMAL;

/// Block descriptor attributes for 2MB device memory.
const DEVICE_BLOCK_ATTRS: u64 = Flags.BLOCK | Flags.AF | Flags.ATTR_DEVICE | Flags.PXN | Flags.UXN;

/// Table descriptor: valid non-leaf entry pointing to next-level table.
const TABLE_DESC: u64 = Flags.PRESENT; // bits [1:0] = 0b11

pub fn init() void {
    // Disable alignment checking — UEFI enables SCTLR_EL1.A (bit 1),
    // which causes alignment faults on NEON 128-bit struct copies that the
    // Zig compiler generates for 8-byte-aligned data.
    {
        var sctlr = cpu.readSctlr();
        sctlr &= ~@as(u64, 1 << 1); // Clear A bit
        cpu.writeSctlr(sctlr);
        cpu.isb();
    }

    // Step 1: Build page tables using UEFI's existing MMU configuration.
    // Do NOT touch MAIR/TCR yet — changing them while UEFI's page tables
    // are active causes attribute mismatches (Normal memory becomes Device
    // memory, which has strict alignment requirements regardless of SCTLR.A).

    // Allocate kernel root table (TTBR1 — upper half)
    const kern_page = pmm.allocPage() orelse {
        klog.err("Paging: failed to allocate kernel root table!\n");
        return;
    };
    kernel_root_phys = kern_page;
    const kern_root: *PageTable = @ptrFromInt(kern_page);
    kern_root.zero();

    // Allocate user root table (TTBR0 — lower half, identity map)
    const user_page = pmm.allocPage() orelse {
        klog.err("Paging: failed to allocate user root table!\n");
        return;
    };
    user_root_phys = user_page;
    const user_root: *PageTable = @ptrFromInt(user_page);
    user_root.zero();

    // Identity map first 4 GB using 2MB blocks in TTBR0 (lower half).
    // 0x00000000-0x3FFFFFFF = first 1 GB (includes MMIO devices below 0x40000000)
    // 0x40000000-0xFFFFFFFF = RAM on QEMU virt
    mapHugeRegion(user_root, 0, 0, 4 * 1024 / 2) orelse {
        klog.err("Paging: failed to map identity region!\n");
        return;
    };

    // Higher-half map: virtual KERNEL_VIRT_BASE → physical 0, 4 GB
    // This goes into TTBR1 (upper half addresses).
    // TTBR1 maps addresses 0xFFFF_0000_0000_0000 and above.
    // KERNEL_VIRT_BASE = 0xFFFF_8000_0000_0000.
    // With T1SZ=16, TTBR1 covers 0xFFFF_0000_0000_0000 - 0xFFFF_FFFF_FFFF_FFFF.
    // Index into TTBR1 root: bits [47:39] of (VA without top bits).
    mapHugeRegion(kern_root, mem.KERNEL_VIRT_BASE, 0, 4 * 1024 / 2) orelse {
        klog.err("Paging: failed to map higher-half region!\n");
        return;
    };

    // Map PCI ECAM region (above 4 GB on QEMU virt aarch64).
    // ECAM at 0x40_1000_0000, size 256 MB. Map 16 MB (8 blocks) for bus 0.
    const pci_ecam_phys: u64 = 0x40_1000_0000;
    const pci_ecam_blocks: usize = 8; // 16 MB = 8 × 2MB blocks
    mapHugeRegionDevice(user_root, pci_ecam_phys, pci_ecam_phys, pci_ecam_blocks) orelse {
        klog.err("Paging: failed to map PCI ECAM!\n");
    };
    mapHugeRegionDevice(kern_root, mem.KERNEL_VIRT_BASE +% pci_ecam_phys, pci_ecam_phys, pci_ecam_blocks) orelse {
        klog.err("Paging: failed to map PCI ECAM (higher-half)!\n");
    };

    // Step 2: Switch MMU configuration atomically — MAIR, TCR, TTBRs, then TLB flush.
    // This replaces UEFI's attribute/translation config with ours in one shot.

    // Configure MAIR_EL1:
    //   Attr0 = 0xFF (Normal, Write-Back, Read-Write-Allocate, Inner+Outer)
    //   Attr1 = 0x00 (Device-nGnRnE)
    cpu.writeMair(0x00000000000000FF);

    // Configure TCR_EL1:
    //   T0SZ = 16 (48-bit VA for TTBR0, lower half)
    //   T1SZ = 16 (48-bit VA for TTBR1, upper half)
    //   TG0 = 0b00 (4KB granule for TTBR0)
    //   TG1 = 0b10 (4KB granule for TTBR1)
    //   IRGN0/ORGN0 = 0b01 (Write-Back, Write-Allocate)
    //   IRGN1/ORGN1 = 0b01 (Write-Back, Write-Allocate)
    //   SH0/SH1 = 0b11 (Inner Shareable)
    //   IPS = 0b010 (40-bit PA, 1TB — sufficient for QEMU virt)
    const tcr: u64 = (16 << 0) | // T0SZ
        (16 << 16) | // T1SZ
        (0b00 << 14) | // TG0 = 4KB
        (0b10 << 30) | // TG1 = 4KB
        (0b01 << 8) | // IRGN0 = WB-WA
        (0b01 << 10) | // ORGN0 = WB-WA
        (0b11 << 12) | // SH0 = Inner Shareable
        (0b01 << 24) | // IRGN1 = WB-WA
        (0b01 << 26) | // ORGN1 = WB-WA
        (0b11 << 28) | // SH1 = Inner Shareable
        (@as(u64, 0b010) << 32); // IPS = 40-bit
    cpu.writeTcr(tcr);

    // Switch page tables
    cpu.writeTtbr0(user_root_phys);
    cpu.writeTtbr1(kernel_root_phys);

    // Synchronize and flush TLB so new MAIR/TCR/TTBRs take effect
    cpu.isb();
    cpu.tlbiAll();
    cpu.dsb();
    cpu.isb();

    // Ensure MMU is enabled with correct SCTLR flags
    var sctlr = cpu.readSctlr();
    sctlr |= 1; // M bit (MMU enable)
    sctlr |= (1 << 2); // C bit (data cache)
    sctlr |= (1 << 12); // I bit (instruction cache)
    sctlr &= ~@as(u64, 1 << 1); // Keep A bit clear (alignment checking off)
    cpu.writeSctlr(sctlr);
    cpu.isb();

    initialized = true;

    klog.info("Paging: AArch64 4KB granule, 4GB identity + higher-half mapped\n");
}

/// Map `count` 2MB blocks starting at `virt_base` → `phys_base`.
fn mapHugeRegion(root: *PageTable, virt_base: u64, phys_base: u64, count: usize) ?void {
    var virt = virt_base;
    var phys = phys_base;
    for (0..count) |_| {
        mapHugeBlock(root, virt, phys) orelse return null;
        virt += 2 * 1024 * 1024;
        phys += 2 * 1024 * 1024;
    }
}

/// Map `count` 2MB blocks as device memory (MMIO).
fn mapHugeRegionDevice(root: *PageTable, virt_base: u64, phys_base: u64, count: usize) ?void {
    var virt = virt_base;
    var phys = phys_base;
    for (0..count) |_| {
        const l3_idx = (virt >> 39) & 0x1FF;
        const l2_idx = (virt >> 30) & 0x1FF;
        const l1_idx = (virt >> 21) & 0x1FF;
        const l2 = getOrAllocTable(root, l3_idx) orelse return null;
        const l1 = getOrAllocTable(l2, l2_idx) orelse return null;
        l1.entries[@intCast(l1_idx)] = (phys & 0x0000_FFFF_FFE0_0000) | DEVICE_BLOCK_ATTRS;
        virt += 2 * 1024 * 1024;
        phys += 2 * 1024 * 1024;
    }
}

/// Map a single 2MB block: virt → phys.
/// Block descriptor at L1 level (bits [1:0]=0b01, OA at [47:21]).
fn mapHugeBlock(root: *PageTable, virt: u64, phys: u64) ?void {
    // AArch64 with 4KB granule, 48-bit VA:
    // L3 index: [47:39], L2 index: [38:30], L1 index: [29:21], L0 index: [20:12]
    const l3_idx = (virt >> 39) & 0x1FF;
    const l2_idx = (virt >> 30) & 0x1FF;
    const l1_idx = (virt >> 21) & 0x1FF;

    // Ensure L2 table exists
    const l2 = getOrAllocTable(root, l3_idx) orelse return null;

    // Ensure L1 table exists
    const l1 = getOrAllocTable(l2, l2_idx) orelse return null;

    // Determine if this is device memory (below RAM base on QEMU virt)
    // QEMU virt: RAM starts at 0x4000_0000. Below that is MMIO.
    const attrs = if (phys < 0x4000_0000) DEVICE_BLOCK_ATTRS else BLOCK_ATTRS;

    // Set 2MB block descriptor at L1
    l1.entries[@intCast(l1_idx)] = (phys & 0x0000_FFFF_FFE0_0000) | attrs;
}

/// Get the next-level page table at `index`, allocating if necessary.
/// If the entry is a 2MB block, split it into 512 × 4KB pages first.
fn getOrAllocTable(table: *PageTable, index: u64) ?*PageTable {
    const idx: usize = @intCast(index);
    if (isValid(table.entries[idx])) {
        if (isBlock(table.entries[idx])) {
            // Split 2MB block into 512 × 4KB pages
            const block_phys = table.entries[idx] & 0x0000_FFFF_FFE0_0000;
            // Determine if device or normal memory
            const is_device = (table.entries[idx] & 0x1C) == Flags.ATTR_DEVICE;
            const page_attrs: u64 = if (is_device) DEVICE_LEAF_ATTRS else LEAF_ATTRS;

            const pt_page = pmm.allocPage() orelse return null;
            const pt: *PageTable = tablePtr(pt_page);
            for (0..512) |i| {
                pt.entries[i] = (block_phys + i * PAGE_SIZE) | page_attrs;
            }
            // Replace with table descriptor
            table.entries[idx] = pt_page | TABLE_DESC;
            return pt;
        }
        // Regular table descriptor — extract physical address
        const addr = pteToPhys(table.entries[idx]);
        return tablePtr(addr);
    }

    // Allocate a new page table
    const page = pmm.allocPage() orelse return null;
    const new_table: *PageTable = tablePtr(page);
    new_table.zero();
    table.entries[idx] = page | TABLE_DESC;
    return new_table;
}

/// Create a new address space with kernel higher-half and deep-copied identity map.
/// Returns a new TTBR0 root table for a process.
pub fn createAddressSpace() ?*PageTable {
    const page = pmm.allocPage() orelse return null;
    const new_root: *PageTable = tablePtr(page);
    new_root.zero();

    // TTBR0 only maps the lower half (user space).
    // The kernel lives in TTBR1 (upper half) which is shared and never changes.
    // We need to deep-copy the identity map from the boot TTBR0 so each process
    // has its own private copy that mapPage() can split independently.
    const boot_root: *PageTable = tablePtr(user_root_phys);

    // Deep-copy L3 entry 0 (covers 0x00000000-0x7FFFFFFFFF — identity map)
    if (isValid(boot_root.entries[0])) {
        const boot_l2: *PageTable = tablePtr(pteToPhys(boot_root.entries[0]));
        const new_l2_page = pmm.allocPage() orelse return null;
        const new_l2: *PageTable = tablePtr(new_l2_page);
        new_l2.zero();

        for (0..512) |i| {
            if (!isValid(boot_l2.entries[i])) continue;

            if (isBlock(boot_l2.entries[i])) {
                // 1GB block — just copy the entry
                new_l2.entries[i] = boot_l2.entries[i];
            } else {
                // Points to an L1 table — allocate a private copy
                const boot_l1: *PageTable = tablePtr(pteToPhys(boot_l2.entries[i]));
                const new_l1_page = pmm.allocPage() orelse return null;
                const new_l1: *PageTable = tablePtr(new_l1_page);
                new_l1.* = boot_l1.*; // Copy all entries
                new_l2.entries[i] = new_l1_page | TABLE_DESC;
            }
        }

        new_root.entries[0] = new_l2_page | TABLE_DESC;
    }

    return new_root;
}

/// Deep-copy the entire user-half address space for fork.
/// Entry 0 (identity map) is handled by createAddressSpace().
/// Each 4KB user page is fully copied (no COW).
pub fn deepCopyAddressSpace(src_root: *PageTable) ?*PageTable {
    const new_root = createAddressSpace() orelse return null;

    // Walk L3 entries 1-511 (user half, excluding entry 0 identity map)
    for (1..512) |l3_idx| {
        if (!isValid(src_root.entries[l3_idx])) continue;
        if (isBlock(src_root.entries[l3_idx])) {
            new_root.entries[l3_idx] = src_root.entries[l3_idx];
            continue;
        }
        const src_l2: *PageTable = tablePtr(pteToPhys(src_root.entries[l3_idx]));

        const new_l2_page = pmm.allocPage() orelse return null;
        const new_l2: *PageTable = tablePtr(new_l2_page);
        new_l2.zero();

        for (0..512) |l2_idx| {
            if (!isValid(src_l2.entries[l2_idx])) continue;
            if (isBlock(src_l2.entries[l2_idx])) {
                new_l2.entries[l2_idx] = src_l2.entries[l2_idx];
                continue;
            }
            const src_l1: *PageTable = tablePtr(pteToPhys(src_l2.entries[l2_idx]));

            const new_l1_page = pmm.allocPage() orelse return null;
            const new_l1: *PageTable = tablePtr(new_l1_page);
            new_l1.zero();

            for (0..512) |l1_idx| {
                if (!isValid(src_l1.entries[l1_idx])) continue;
                if (isBlock(src_l1.entries[l1_idx])) {
                    new_l1.entries[l1_idx] = src_l1.entries[l1_idx];
                    continue;
                }
                const src_l0: *PageTable = tablePtr(pteToPhys(src_l1.entries[l1_idx]));

                const new_l0_page = pmm.allocPage() orelse return null;
                const new_l0: *PageTable = tablePtr(new_l0_page);
                new_l0.zero();

                for (0..512) |l0_idx| {
                    if (!isValid(src_l0.entries[l0_idx])) continue;
                    // Only copy user pages (AP[1]=1, bit 6)
                    if (src_l0.entries[l0_idx] & Flags.USER == 0) continue;

                    const src_phys = pteToPhys(src_l0.entries[l0_idx]);
                    const new_page = pmm.allocPage() orelse return null;

                    // Copy 4KB page content
                    const src_data: [*]const u8 = physPtr(src_phys);
                    const dst_data: [*]u8 = physPtr(new_page);
                    @memcpy(dst_data[0..mem.PAGE_SIZE], src_data[0..mem.PAGE_SIZE]);

                    // Preserve attributes, point to new physical page
                    const attrs = src_l0.entries[l0_idx] & 0xFFFF_0000_0000_0FFF;
                    new_l0.entries[l0_idx] = new_page | attrs;
                }

                new_l1.entries[l1_idx] = new_l0_page | TABLE_DESC;
            }

            new_l2.entries[l2_idx] = new_l1_page | TABLE_DESC;
        }

        new_root.entries[l3_idx] = new_l2_page | TABLE_DESC;
    }

    return new_root;
}

/// Map a single 4KB page in the given address space (TTBR0 root).
pub fn mapPage(root: *PageTable, virt: u64, phys: u64, flags: u64) ?void {
    const l3_idx = (virt >> 39) & 0x1FF;
    const l2_idx = (virt >> 30) & 0x1FF;
    const l1_idx = (virt >> 21) & 0x1FF;
    const l0_idx = (virt >> 12) & 0x1FF;

    // AArch64 table descriptors don't need USER/AP propagation (unlike x86_64).
    // AP/UXN/PXN only go on leaf (page) descriptors.
    const l2 = getOrAllocTable(root, l3_idx) orelse return null;
    const l1 = getOrAllocTable(l2, l2_idx) orelse return null;
    const l0 = getOrAllocTable(l1, l1_idx) orelse return null;

    // Build page descriptor
    var pte: u64 = phys | LEAF_ATTRS;

    // User accessible
    if (flags & Flags.USER != 0) {
        pte |= Flags.USER; // AP[1] = 1
    }

    // Read-only if WRITABLE not set (AP[2]=1)
    if (flags & Flags.WRITABLE == 0) {
        pte |= Flags.AP_RO;
    }

    // Non-executable (if EXEC is not in flags, apply UXN)
    // Since EXEC=0, we check: if caller did NOT set any exec bit, set UXN.
    // Actually, for user code segments we want them executable.
    // The ELF loader sets EXEC flag (=0) for executable segments, so all user
    // pages are executable by default. This matches AArch64 behavior where
    // UXN must be explicitly set to prevent execution.
    // We DON'T set UXN here — same as riscv64 where EXEC=bit3 is always set
    // by the ELF loader for code segments.

    l0.entries[@intCast(l0_idx)] = pte;
}

/// Unmap a single 4KB page.
pub fn unmapPage(root: *PageTable, virt: u64) void {
    const l3_idx: usize = @intCast((virt >> 39) & 0x1FF);
    const l2_idx: usize = @intCast((virt >> 30) & 0x1FF);
    const l1_idx: usize = @intCast((virt >> 21) & 0x1FF);
    const l0_idx: usize = @intCast((virt >> 12) & 0x1FF);

    if (!isValid(root.entries[l3_idx])) return;
    if (isBlock(root.entries[l3_idx])) return;
    const l2: *PageTable = tablePtr(pteToPhys(root.entries[l3_idx]));

    if (!isValid(l2.entries[l2_idx])) return;
    if (isBlock(l2.entries[l2_idx])) return;
    const l1: *PageTable = tablePtr(pteToPhys(l2.entries[l2_idx]));

    if (!isValid(l1.entries[l1_idx])) return;
    if (isBlock(l1.entries[l1_idx])) return;
    const l0: *PageTable = tablePtr(pteToPhys(l1.entries[l1_idx]));

    l0.entries[l0_idx] = 0;

    // Invalidate TLB for this address
    asm volatile ("tlbi vale1is, %[addr]"
        :
        : [addr] "r" (virt >> 12),
    );
    cpu.dsb();
    cpu.isb();
}

/// Switch TTBR0 to a different address space (user half only).
pub fn switchAddressSpace(root: *PageTable) void {
    const virt = @intFromPtr(root);
    const phys = if (virt >= mem.KERNEL_VIRT_BASE) virt - mem.KERNEL_VIRT_BASE else virt;
    cpu.writeTtbr0(phys);
    cpu.isb();
    cpu.tlbiAll();
}

/// Switch TTBR0 to the boot identity map.
pub fn switchToKernel() void {
    cpu.writeTtbr0(user_root_phys);
    cpu.isb();
    cpu.tlbiAll();
}

/// Get the kernel root page table (TTBR1).
pub fn getKernelRoot() *PageTable {
    return tablePtr(kernel_root_phys);
}

/// Walk page tables to translate a virtual address to physical.
pub fn translateVaddr(root: *PageTable, virt: u64) ?u64 {
    const l3_idx: usize = @intCast((virt >> 39) & 0x1FF);
    if (!isValid(root.entries[l3_idx])) return null;
    if (isBlock(root.entries[l3_idx])) {
        // 512GB block (unlikely)
        return pteToPhys(root.entries[l3_idx]) | (virt & 0x7F_FFFF_FFFF);
    }
    const l2: *PageTable = tablePtr(pteToPhys(root.entries[l3_idx]));

    const l2_idx: usize = @intCast((virt >> 30) & 0x1FF);
    if (!isValid(l2.entries[l2_idx])) return null;
    if (isBlock(l2.entries[l2_idx])) {
        // 1GB block
        return pteToPhys(l2.entries[l2_idx]) | (virt & 0x3FFFFFFF);
    }
    const l1: *PageTable = tablePtr(pteToPhys(l2.entries[l2_idx]));

    const l1_idx: usize = @intCast((virt >> 21) & 0x1FF);
    if (!isValid(l1.entries[l1_idx])) return null;
    if (isBlock(l1.entries[l1_idx])) {
        // 2MB block
        return pteToPhys(l1.entries[l1_idx]) | (virt & 0x1FFFFF);
    }
    const l0: *PageTable = tablePtr(pteToPhys(l1.entries[l1_idx]));

    const l0_idx: usize = @intCast((virt >> 12) & 0x1FF);
    if (!isValid(l0.entries[l0_idx])) return null;
    return pteToPhys(l0.entries[l0_idx]) | (virt & 0xFFF);
}

/// Free all user-half pages and page tables in an address space.
pub fn freeAddressSpace(root: *PageTable) void {
    // All entries are user-half (TTBR0). Walk them all.
    for (0..512) |l3_idx| {
        if (!isValid(root.entries[l3_idx])) continue;
        if (isBlock(root.entries[l3_idx])) continue; // block, don't free
        const l2_phys = pteToPhys(root.entries[l3_idx]);
        const l2: *PageTable = tablePtr(l2_phys);

        for (0..512) |l2_idx| {
            if (!isValid(l2.entries[l2_idx])) continue;
            if (isBlock(l2.entries[l2_idx])) continue;
            const l1_phys = pteToPhys(l2.entries[l2_idx]);
            const l1: *PageTable = tablePtr(l1_phys);

            for (0..512) |l1_idx| {
                if (!isValid(l1.entries[l1_idx])) continue;
                if (isBlock(l1.entries[l1_idx])) continue;
                const l0_phys = pteToPhys(l1.entries[l1_idx]);
                const l0: *PageTable = tablePtr(l0_phys);

                // Free leaf (4KB) pages that have USER flag
                for (0..512) |l0_idx| {
                    if (!isValid(l0.entries[l0_idx])) continue;
                    if (l0.entries[l0_idx] & Flags.USER != 0) {
                        pmm.freePage(pteToPhys(l0.entries[l0_idx]));
                    }
                }

                pmm.freePage(l0_phys);
            }

            pmm.freePage(l1_phys);
        }

        pmm.freePage(l2_phys);
    }

    // Free the root page table itself
    const root_phys = @intFromPtr(root) -% (if (@intFromPtr(root) >= mem.KERNEL_VIRT_BASE) mem.KERNEL_VIRT_BASE else 0);
    pmm.freePage(root_phys);
}
