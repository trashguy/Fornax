/// RISC-V Sv48 4-level paging: L3 → L2 → L1 → L0.
///
/// Sv48 mirrors x86_64 PML4 structure exactly (4 levels, 512 entries/table, 4KB pages).
/// Superpages: 2MB (L1 leaf), 1GB (L2 leaf), 512GB (L3 leaf).
///
/// PTE format: [53:10] PPN, [7:0] D|A|G|U|X|W|R|V
///   - Non-leaf: V=1, R=W=X=0, PPN→next table
///   - Leaf: V=1, at least one of R|W|X set
///
/// Initial kernel mapping:
///   - Identity map first 4 GB with 2MB superpages
///   - Higher-half map at 0xFFFF_8000_0000_0000 with 2MB superpages
///   - After switch, kernel runs in higher-half
const klog = @import("../../klog.zig");
const pmm = @import("../../pmm.zig");
const mem = @import("../../mem.zig");
const cpu = @import("cpu.zig");

const PAGE_SIZE = mem.PAGE_SIZE;

/// Sv48 PTE flag bits.
pub const Flags = struct {
    pub const VALID: u64 = 1 << 0;
    pub const READ: u64 = 1 << 1;
    pub const WRITE: u64 = 1 << 2;
    pub const EXEC: u64 = 1 << 3;
    pub const USER: u64 = 1 << 4;
    pub const GLOBAL: u64 = 1 << 5;
    pub const ACCESSED: u64 = 1 << 6;
    pub const DIRTY: u64 = 1 << 7;

    // Aliases for compatibility with x86_64 paging API
    pub const PRESENT: u64 = VALID;
    pub const WRITABLE: u64 = WRITE;
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

/// Kernel root page table physical address.
var kernel_root_phys: u64 = 0;

/// Whether paging has been initialized.
var initialized: bool = false;

pub fn isInitialized() bool {
    return initialized;
}

/// Convert a physical address to a PageTable pointer.
/// Before paging init: uses identity map (UEFI page tables).
/// After paging init: uses higher-half mapping.
inline fn tablePtr(phys: u64) *PageTable {
    return @ptrFromInt(if (initialized) phys +% mem.KERNEL_VIRT_BASE else phys);
}

/// Convert a physical address to a byte pointer.
pub inline fn physPtr(phys: u64) [*]u8 {
    return @ptrFromInt(if (initialized) phys +% mem.KERNEL_VIRT_BASE else phys);
}

/// Encode a physical address into a Sv48 PTE (PPN field at bits [53:10]).
inline fn physToPte(phys: u64) u64 {
    return (phys >> 12) << 10;
}

/// Extract the physical address from a Sv48 PTE.
inline fn pteToPhys(pte: u64) u64 {
    return ((pte >> 10) & 0xFFF_FFFF_FFFF) << 12;
}

/// Check if a PTE is a leaf (has at least one of R|W|X set).
inline fn isLeaf(pte: u64) bool {
    return (pte & (Flags.READ | Flags.WRITE | Flags.EXEC)) != 0;
}

/// PPN mask for extracting physical page number from PTE.
const PPN_MASK: u64 = 0x003F_FFFF_FFFF_FC00; // bits [53:10]

/// 2MB-aligned physical address mask for superpages.
const MEGA_ADDR_MASK: u64 = 0x003F_FFFF_FFE0_0000;

pub fn init() void {
    // Allocate root page table (L3)
    const root_page = pmm.allocPage() orelse {
        klog.err("Paging: failed to allocate root table!\n");
        return;
    };
    kernel_root_phys = root_page;
    const root: *PageTable = @ptrFromInt(root_page);
    root.zero();

    // Identity map first 4 GB using 2MB superpages
    mapHugeRegion(root, 0, 0, 4 * 1024 / 2) orelse {
        klog.err("Paging: failed to map identity region!\n");
        return;
    };

    // Higher-half map: virtual 0xFFFF_8000_0000_0000 → physical 0, 4 GB
    mapHugeRegion(root, mem.KERNEL_VIRT_BASE, 0, 4 * 1024 / 2) orelse {
        klog.err("Paging: failed to map higher-half region!\n");
        return;
    };

    // Write SATP: mode=9 (Sv48), PPN of root table
    const satp_val: u64 = (@as(u64, 9) << 60) | (kernel_root_phys >> 12);
    cpu.csrWrite(cpu.CSR_SATP, satp_val);
    asm volatile ("sfence.vma" ::: .{ .memory = true });

    initialized = true;

    klog.info("Paging: Sv48 4GB identity + higher-half mapped, SATP switched\n");
}

/// Map `count` 2MB superpages starting at `virt_base` → `phys_base`.
fn mapHugeRegion(root: *PageTable, virt_base: u64, phys_base: u64, count: usize) ?void {
    var virt = virt_base;
    var phys = phys_base;
    for (0..count) |_| {
        mapHugePage(root, virt, phys) orelse return null;
        virt += 2 * 1024 * 1024;
        phys += 2 * 1024 * 1024;
    }
}

/// Map a single 2MB superpage: virt → phys.
/// Sv48 2MB superpage = leaf entry at L1 (level 1) with R+W+X set.
fn mapHugePage(root: *PageTable, virt: u64, phys: u64) ?void {
    // Sv48 indices: [47:39]=L3, [38:30]=L2, [29:21]=L1, [20:12]=L0
    const l3_idx = (virt >> 39) & 0x1FF;
    const l2_idx = (virt >> 30) & 0x1FF;
    const l1_idx = (virt >> 21) & 0x1FF;

    // Ensure L2 table exists
    const l2 = getOrAllocTable(root, l3_idx, 0) orelse return null;

    // Ensure L1 table exists
    const l1 = getOrAllocTable(l2, l2_idx, 0) orelse return null;

    // Set 2MB superpage entry (leaf at L1: R+W+X+V+A+D set)
    l1.entries[l1_idx] = physToPte(phys) | Flags.VALID | Flags.READ | Flags.WRITE | Flags.EXEC | Flags.ACCESSED | Flags.DIRTY;
}

/// Get the next-level page table at `index`, allocating if necessary.
/// If the entry is a 2MB superpage (leaf at L1), split it into 512 × 4KB pages first.
fn getOrAllocTable(table: *PageTable, index: u64, propagate_flags: u64) ?*PageTable {
    const idx: usize = @intCast(index);
    if (table.entries[idx] & Flags.VALID != 0) {
        // Propagate USER/WRITABLE to existing intermediate entries
        table.entries[idx] |= propagate_flags;

        if (isLeaf(table.entries[idx])) {
            // Split 2MB superpage into 512 × 4KB pages
            const huge_phys = pteToPhys(table.entries[idx]) & MEGA_ADDR_MASK;
            const base_flags = table.entries[idx] & 0xFF; // preserve flag bits

            const pt_page = pmm.allocPage() orelse return null;
            const pt: *PageTable = tablePtr(pt_page);
            for (0..512) |i| {
                pt.entries[i] = physToPte(huge_phys + i * PAGE_SIZE) | (base_flags & ~@as(u64, 0)); // keep all flags
            }
            // Replace entry: now a non-leaf pointing to the new page table
            table.entries[idx] = physToPte(pt_page) | Flags.VALID | propagate_flags;
            return pt;
        }
        // Regular non-leaf entry — extract physical address
        const addr = pteToPhys(table.entries[idx]);
        return tablePtr(addr);
    }

    // Allocate a new page table
    const page = pmm.allocPage() orelse return null;
    const new_table: *PageTable = tablePtr(page);
    new_table.zero();
    table.entries[idx] = physToPte(page) | Flags.VALID | propagate_flags;
    return new_table;
}

/// Create a new address space with kernel half and deep-copied identity map.
/// Sv48: entries 0-255 = user half, 256-511 = kernel half.
pub fn createAddressSpace() ?*PageTable {
    const page = pmm.allocPage() orelse return null;
    const new_root: *PageTable = tablePtr(page);
    new_root.zero();

    const kernel_root: *PageTable = tablePtr(kernel_root_phys);

    // Copy kernel half (entries 256-511) — shallow copy
    for (256..512) |i| {
        new_root.entries[i] = kernel_root.entries[i];
    }

    // Deep-copy identity map (entry 0) so mapPage() can split superpages
    // without corrupting the kernel's shared tables.
    if (kernel_root.entries[0] & Flags.VALID != 0) {
        const kernel_l2: *PageTable = tablePtr(pteToPhys(kernel_root.entries[0]));
        const new_l2_page = pmm.allocPage() orelse return null;
        const new_l2: *PageTable = tablePtr(new_l2_page);
        new_l2.zero();

        for (0..512) |i| {
            if (kernel_l2.entries[i] & Flags.VALID == 0) continue;

            if (isLeaf(kernel_l2.entries[i])) {
                // 1GB superpage — just copy the entry
                new_l2.entries[i] = kernel_l2.entries[i];
            } else {
                // Points to an L1 table — allocate a private copy
                const kernel_l1: *PageTable = tablePtr(pteToPhys(kernel_l2.entries[i]));
                const new_l1_page = pmm.allocPage() orelse return null;
                const new_l1: *PageTable = tablePtr(new_l1_page);
                new_l1.* = kernel_l1.*; // Copy all entries (including superpages)
                new_l2.entries[i] = physToPte(new_l1_page) | (kernel_l2.entries[i] & 0xFF);
            }
        }

        new_root.entries[0] = physToPte(new_l2_page) | (kernel_root.entries[0] & 0xFF);
    }

    return new_root;
}

/// Deep-copy the entire user-half address space (Sv48 entries 1-255) for fork.
/// Entry 0 (identity map) is handled by createAddressSpace(). The kernel half
/// (entries 256-511) is shared. Each 4KB user page is fully copied (no COW).
pub fn deepCopyAddressSpace(src_root: *PageTable) ?*PageTable {
    // Create base address space (kernel half + identity map deep-copy)
    const new_root = createAddressSpace() orelse return null;

    // Walk L3 entries 1-255 (user half, excluding entry 0 identity map)
    for (1..256) |l3_idx| {
        if (src_root.entries[l3_idx] & Flags.VALID == 0) continue;
        if (isLeaf(src_root.entries[l3_idx])) {
            // Superpage — copy entry as-is
            new_root.entries[l3_idx] = src_root.entries[l3_idx];
            continue;
        }
        const src_l2: *PageTable = tablePtr(pteToPhys(src_root.entries[l3_idx]));

        const new_l2_page = pmm.allocPage() orelse return null;
        const new_l2: *PageTable = tablePtr(new_l2_page);
        new_l2.zero();

        for (0..512) |l2_idx| {
            if (src_l2.entries[l2_idx] & Flags.VALID == 0) continue;
            if (isLeaf(src_l2.entries[l2_idx])) {
                // 1GB superpage — copy as-is
                new_l2.entries[l2_idx] = src_l2.entries[l2_idx];
                continue;
            }
            const src_l1: *PageTable = tablePtr(pteToPhys(src_l2.entries[l2_idx]));

            const new_l1_page = pmm.allocPage() orelse return null;
            const new_l1: *PageTable = tablePtr(new_l1_page);
            new_l1.zero();

            for (0..512) |l1_idx| {
                if (src_l1.entries[l1_idx] & Flags.VALID == 0) continue;
                if (isLeaf(src_l1.entries[l1_idx])) {
                    // 2MB superpage — copy as-is
                    new_l1.entries[l1_idx] = src_l1.entries[l1_idx];
                    continue;
                }
                const src_l0: *PageTable = tablePtr(pteToPhys(src_l1.entries[l1_idx]));

                const new_l0_page = pmm.allocPage() orelse return null;
                const new_l0: *PageTable = tablePtr(new_l0_page);
                new_l0.zero();

                for (0..512) |l0_idx| {
                    if (src_l0.entries[l0_idx] & Flags.VALID == 0) continue;
                    if (src_l0.entries[l0_idx] & Flags.USER == 0) continue; // skip non-user pages

                    const src_phys = pteToPhys(src_l0.entries[l0_idx]);
                    const new_page = pmm.allocPage() orelse return null;

                    // Copy 4KB page content
                    const src_ptr: [*]const u8 = physPtr(src_phys);
                    const dst_ptr: [*]u8 = physPtr(new_page);
                    @memcpy(dst_ptr[0..mem.PAGE_SIZE], src_ptr[0..mem.PAGE_SIZE]);

                    // Preserve flags, point to new physical page
                    const flags_bits = src_l0.entries[l0_idx] & 0x3FF; // low 10 bits are flags
                    new_l0.entries[l0_idx] = physToPte(new_page) | flags_bits;
                }

                // Non-leaf: only VALID bit (no U/A/D — reserved on riscv64)
                new_l1.entries[l1_idx] = physToPte(new_l0_page) | Flags.VALID;
            }

            new_l2.entries[l2_idx] = physToPte(new_l1_page) | Flags.VALID;
        }

        new_root.entries[l3_idx] = physToPte(new_l2_page) | Flags.VALID;
    }

    return new_root;
}

/// Map a single 4KB page in the given address space.
pub fn mapPage(root: *PageTable, virt: u64, phys: u64, flags: u64) ?void {
    const l3_idx = (virt >> 39) & 0x1FF;
    const l2_idx = (virt >> 30) & 0x1FF;
    const l1_idx = (virt >> 21) & 0x1FF;
    const l0_idx = (virt >> 12) & 0x1FF;

    // RISC-V Sv48: U bit is only checked on LEAF PTEs. Non-leaf PTEs must
    // have U/A/D cleared (reserved per spec). Do NOT propagate USER to
    // intermediate entries — unlike x86_64 where U must be set at every level.
    const l2 = getOrAllocTable(root, l3_idx, 0) orelse return null;
    const l1 = getOrAllocTable(l2, l2_idx, 0) orelse return null;
    const l0 = getOrAllocTable(l1, l1_idx, 0) orelse return null;

    l0.entries[@intCast(l0_idx)] = physToPte(phys) | flags | Flags.VALID | Flags.READ | Flags.ACCESSED | Flags.DIRTY;
}

/// Unmap a single 4KB page.
pub fn unmapPage(root: *PageTable, virt: u64) void {
    const l3_idx: usize = @intCast((virt >> 39) & 0x1FF);
    const l2_idx: usize = @intCast((virt >> 30) & 0x1FF);
    const l1_idx: usize = @intCast((virt >> 21) & 0x1FF);
    const l0_idx: usize = @intCast((virt >> 12) & 0x1FF);

    if (root.entries[l3_idx] & Flags.VALID == 0) return;
    const l2: *PageTable = tablePtr(pteToPhys(root.entries[l3_idx]));

    if (l2.entries[l2_idx] & Flags.VALID == 0) return;
    if (isLeaf(l2.entries[l2_idx])) return; // Can't unmap inside a superpage
    const l1: *PageTable = tablePtr(pteToPhys(l2.entries[l2_idx]));

    if (l1.entries[l1_idx] & Flags.VALID == 0) return;
    if (isLeaf(l1.entries[l1_idx])) return; // Can't unmap inside a superpage
    const l0: *PageTable = tablePtr(pteToPhys(l1.entries[l1_idx]));

    l0.entries[l0_idx] = 0;

    // Invalidate TLB for this address
    asm volatile ("sfence.vma %[addr], zero"
        :
        : [addr] "r" (virt),
        : .{ .memory = true }
    );
}

/// Switch to a different address space.
pub fn switchAddressSpace(root: *PageTable) void {
    const virt = @intFromPtr(root);
    const phys = if (virt >= mem.KERNEL_VIRT_BASE) virt - mem.KERNEL_VIRT_BASE else virt;
    const satp_val: u64 = (@as(u64, 9) << 60) | (phys >> 12);
    cpu.csrWrite(cpu.CSR_SATP, satp_val);
    asm volatile ("sfence.vma" ::: .{ .memory = true });
}

/// Get the kernel root page table.
pub fn getKernelRoot() *PageTable {
    return tablePtr(kernel_root_phys);
}

/// Walk page tables to translate a virtual address to physical.
pub fn translateVaddr(root: *PageTable, virt: u64) ?u64 {
    const l3_idx: usize = @intCast((virt >> 39) & 0x1FF);
    if (root.entries[l3_idx] & Flags.VALID == 0) return null;
    if (isLeaf(root.entries[l3_idx])) {
        // 512GB superpage (unlikely but handle it)
        return pteToPhys(root.entries[l3_idx]) | (virt & 0x7F_FFFF_FFFF);
    }
    const l2: *PageTable = tablePtr(pteToPhys(root.entries[l3_idx]));

    const l2_idx: usize = @intCast((virt >> 30) & 0x1FF);
    if (l2.entries[l2_idx] & Flags.VALID == 0) return null;
    if (isLeaf(l2.entries[l2_idx])) {
        // 1GB superpage
        return pteToPhys(l2.entries[l2_idx]) | (virt & 0x3FFFFFFF);
    }
    const l1: *PageTable = tablePtr(pteToPhys(l2.entries[l2_idx]));

    const l1_idx: usize = @intCast((virt >> 21) & 0x1FF);
    if (l1.entries[l1_idx] & Flags.VALID == 0) return null;
    if (isLeaf(l1.entries[l1_idx])) {
        // 2MB superpage
        return pteToPhys(l1.entries[l1_idx]) | (virt & 0x1FFFFF);
    }
    const l0: *PageTable = tablePtr(pteToPhys(l1.entries[l1_idx]));

    const l0_idx: usize = @intCast((virt >> 12) & 0x1FF);
    if (l0.entries[l0_idx] & Flags.VALID == 0) return null;
    return pteToPhys(l0.entries[l0_idx]) | (virt & 0xFFF);
}

/// Free all user-half pages and page tables in an address space.
pub fn freeAddressSpace(root: *PageTable) void {
    // Walk user-half only (entries 0-255). Kernel half (256-511) is shared.
    // On RISC-V, non-leaf PTEs cannot have the USER flag (it's reserved),
    // so we cannot use USER to distinguish kernel vs user page tables.
    // All intermediate page tables in user-half are private copies
    // (deep-copied from kernel or allocated by mapPage), so free them all.
    for (0..256) |l3_idx| {
        if (root.entries[l3_idx] & Flags.VALID == 0) continue;
        if (isLeaf(root.entries[l3_idx])) continue;
        const l2_phys = pteToPhys(root.entries[l3_idx]);
        const l2: *PageTable = tablePtr(l2_phys);

        for (0..512) |l2_idx| {
            if (l2.entries[l2_idx] & Flags.VALID == 0) continue;
            if (isLeaf(l2.entries[l2_idx])) continue; // superpage, don't free
            const l1_phys = pteToPhys(l2.entries[l2_idx]);
            const l1: *PageTable = tablePtr(l1_phys);

            for (0..512) |l1_idx| {
                if (l1.entries[l1_idx] & Flags.VALID == 0) continue;
                if (isLeaf(l1.entries[l1_idx])) continue; // 2MB superpage
                const l0_phys = pteToPhys(l1.entries[l1_idx]);
                const l0: *PageTable = tablePtr(l0_phys);

                // Free leaf (4KB) pages that have USER flag
                for (0..512) |l0_idx| {
                    if (l0.entries[l0_idx] & Flags.VALID == 0) continue;
                    if (l0.entries[l0_idx] & Flags.USER != 0) {
                        pmm.freePage(pteToPhys(l0.entries[l0_idx]));
                    }
                }

                // Free the L0 page table (always private on riscv64)
                pmm.freePage(l0_phys);
            }

            // Free the L1 page table (always private on riscv64)
            pmm.freePage(l1_phys);
        }

        // Free the L2 page table
        pmm.freePage(l2_phys);
    }

    // Free the root page table itself
    const root_phys = @intFromPtr(root) - if (@intFromPtr(root) >= mem.KERNEL_VIRT_BASE) mem.KERNEL_VIRT_BASE else 0;
    pmm.freePage(root_phys);
}
