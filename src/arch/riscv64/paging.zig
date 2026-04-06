/// RISC-V Sv39 3-level paging: root (L2) → L1 → L0.
///
/// Sv39: 39-bit virtual address, sign-extended to 64 bits.
/// 512 entries/table, 4KB pages.  Superpages: 2MB (L1 leaf), 1GB (L2 leaf).
/// User half: entries 0-255.  Kernel half: entries 256-511.
///
/// PTE format: [53:10] PPN, [7:0] D|A|G|U|X|W|R|V
///   - Non-leaf: V=1, R=W=X=0, PPN→next table
///   - Leaf: V=1, at least one of R|W|X set
///
/// Initial kernel mapping (size determined by mem.KERNEL_MAP_SIZE):
///   - Identity map with 2MB superpages (covers all RAM + device MMIO)
///   - Higher-half map at KERNEL_VIRT_BASE (0xFFFF_FFC0_0000_0000) with 2MB superpages
///   - After SATP switch, kernel runs in higher-half
const klog = @import("../../klog.zig");
const pmm = @import("../../pmm.zig");
const mem = @import("../../mem.zig");
const cpu = @import("cpu.zig");

const PAGE_SIZE = mem.PAGE_SIZE;

/// SATP mode for Sv39.
const SATP_MODE_SV39: u64 = 8;

/// ASID support: probed in init(), ASID bits sit at SATP[59:44].
/// max_asid = 0 means no ASID support (or probing not done yet).
var max_asid: u16 = 0;

pub fn hasAsidSupport() bool {
    return max_asid > 0;
}

pub fn getMaxAsid() u16 {
    return max_asid;
}

/// Sv39 PTE flag bits.
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
    pub const NO_EXECUTE: u64 = 0; // RISC-V: no NX bit, just don't set EXEC
    pub const DEVICE_MAP: u64 = 0; // RISC-V: cache control via PMAs, not PTEs
    pub const WRITE_COMBINE: u64 = 0;
    pub const NO_CACHE: u64 = 0;
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
/// Before paging init: uses identity map (bare mode).
/// After paging init: uses higher-half mapping.
inline fn tablePtr(phys: u64) *PageTable {
    return @ptrFromInt(if (initialized) phys +% mem.KERNEL_VIRT_BASE else phys);
}

/// Convert a physical address to a byte pointer.
pub inline fn physPtr(phys: u64) [*]u8 {
    return @ptrFromInt(if (initialized) phys +% mem.KERNEL_VIRT_BASE else phys);
}

/// Encode a physical address into a PTE (PPN field at bits [53:10]).
inline fn physToPte(phys: u64) u64 {
    return (phys >> 12) << 10;
}

/// Extract the physical address from a PTE.
inline fn pteToPhys(pte: u64) u64 {
    return ((pte >> 10) & 0xFFF_FFFF_FFFF) << 12;
}

/// Check if a PTE is a leaf (has at least one of R|W|X set).
inline fn isLeaf(pte: u64) bool {
    return (pte & (Flags.READ | Flags.WRITE | Flags.EXEC)) != 0;
}

/// 2MB-aligned physical address mask for superpages.
const MEGA_ADDR_MASK: u64 = 0x003F_FFFF_FFE0_0000;

/// Direct physical UART write — bypasses serial module, works in any paging state.
fn debugChar(c: u8) void {
    @as(*volatile u8, @ptrFromInt(@as(u64, 0x10000000))).* = c;
}

pub fn init() void {
    // Allocate root page table (L2 in Sv39)
    const root_page = pmm.allocPage() orelse {
        klog.err("Paging: failed to allocate root table!\n");
        return;
    };
    kernel_root_phys = root_page;
    const root: *PageTable = @ptrFromInt(root_page);
    root.zero();

    // Identity map using 2MB superpages (size from KERNEL_MAP_SIZE)
    const huge_count = mem.KERNEL_MAP_SIZE / (2 * 1024 * 1024);
    mapHugeRegion(root, 0, 0, huge_count) orelse {
        klog.err("Paging: failed to map identity region!\n");
        return;
    };

    // Higher-half map: virtual KERNEL_VIRT_BASE → physical 0
    mapHugeRegion(root, mem.KERNEL_VIRT_BASE, 0, huge_count) orelse {
        klog.err("Paging: failed to map higher-half region!\n");
        return;
    };

    // Write SATP: mode=8 (Sv39), PPN of root table
    const satp_val: u64 = (SATP_MODE_SV39 << 60) | (kernel_root_phys >> 12);
    cpu.csrWrite(cpu.CSR_SATP, satp_val);
    asm volatile ("sfence.vma" ::: .{ .memory = true });

    // Verify SATP was accepted
    const satp_readback = cpu.csrRead(cpu.CSR_SATP);
    const mode_readback = satp_readback >> 60;
    if (mode_readback != SATP_MODE_SV39) {
        debugChar('!');
        klog.err("Paging: Sv39 not supported (SATP mode=");
        klog.errDec(mode_readback);
        klog.err(")\n");
        return;
    }

    initialized = true;

    // Probe ASID width: write all-ones to SATP ASID field, read back.
    // SATP layout: [63:60]=mode, [59:44]=ASID, [43:0]=PPN
    {
        const satp_with_asid: u64 = (SATP_MODE_SV39 << 60) | (@as(u64, 0xFFFF) << 44) | (kernel_root_phys >> 12);
        cpu.csrWrite(cpu.CSR_SATP, satp_with_asid);
        const readback = cpu.csrRead(cpu.CSR_SATP);
        const asid_readback: u16 = @truncate((readback >> 44) & 0xFFFF);
        // Restore original SATP (ASID 0 for kernel)
        const satp_orig: u64 = (SATP_MODE_SV39 << 60) | (kernel_root_phys >> 12);
        cpu.csrWrite(cpu.CSR_SATP, satp_orig);
        asm volatile ("sfence.vma" ::: .{ .memory = true });
        max_asid = asid_readback;
    }

    klog.info("Paging: Sv39 ");
    klog.infoDec(mem.KERNEL_MAP_SIZE / (1024 * 1024 * 1024));
    klog.info("GB identity + higher-half mapped, ASID bits=");
    if (max_asid > 0) {
        // Count bits: max_asid is all-ones for the supported width
        var bits: u64 = 0;
        var v: u16 = max_asid;
        while (v != 0) : (v >>= 1) {
            bits += 1;
        }
        klog.infoDec(bits);
    } else {
        klog.info("0");
    }
    klog.info("\n");
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
/// Sv39 2MB superpage = leaf entry at L1 with R+W+X set.
fn mapHugePage(root: *PageTable, virt: u64, phys: u64) ?void {
    // Sv39 indices: [38:30]=L2 (root), [29:21]=L1, [20:12]=L0
    const l2_idx = (virt >> 30) & 0x1FF;
    const l1_idx = (virt >> 21) & 0x1FF;

    // Ensure L1 table exists
    const l1 = getOrAllocTable(root, l2_idx, 0) orelse return null;

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
/// Sv39: entries 0-255 = user half, 256-511 = kernel half.
pub fn createAddressSpace() ?*PageTable {
    const page = pmm.allocPage() orelse return null;
    const new_root: *PageTable = tablePtr(page);
    new_root.zero();

    const kernel_root: *PageTable = tablePtr(kernel_root_phys);

    // Copy kernel half (entries 256-511) — shallow copy
    for (256..512) |i| {
        new_root.entries[i] = kernel_root.entries[i];
    }

    // Deep-copy identity map entries so mapPage() can split superpages
    // without corrupting the kernel's shared tables.
    const id_entries = mem.KERNEL_MAP_SIZE / (1024 * 1024 * 1024);
    for (0..id_entries) |root_idx| {
        if (kernel_root.entries[root_idx] & Flags.VALID == 0) continue;

        if (isLeaf(kernel_root.entries[root_idx])) {
            new_root.entries[root_idx] = kernel_root.entries[root_idx];
        } else {
            const kernel_l1: *PageTable = tablePtr(pteToPhys(kernel_root.entries[root_idx]));
            const new_l1_page = pmm.allocPage() orelse return null;
            const new_l1: *PageTable = tablePtr(new_l1_page);
            new_l1.* = kernel_l1.*;
            new_root.entries[root_idx] = physToPte(new_l1_page) | (kernel_root.entries[root_idx] & 0xFF);
        }
    }

    return new_root;
}

/// Clear identity map entries from a user page table.
/// Call after elf.load() to prevent TLB conflicts on JH7110 where
/// user image base (0x40000000) overlaps with identity-mapped RAM.
/// Only clears entries that DON'T contain user mappings (still superpages).
pub fn clearIdentityMap(root: *PageTable) void {
    const id_entries = mem.KERNEL_MAP_SIZE / (1024 * 1024 * 1024);
    for (0..id_entries) |root_idx| {
        if (root.entries[root_idx] & Flags.VALID == 0) continue;
        // Only clear entries that are still identity-map superpages or
        // point to L1 tables where ALL entries are identity-map superpages.
        // If mapPage modified this entry (split superpages for user code),
        // the L1/L0 tables contain user mappings — keep those.
        // Keep entries needed by user code and the kernel:
        // Entry 1: 0x40000000-0x7FFFFFFF (user image base)
        // Entry 2: 0x80000000-0xBFFFFFFF (kernel binary — linked at 0x80200000)
        // Clear all other identity map entries (0, 3-9).
        if (root_idx != 1 and root_idx != 2) {
            root.entries[root_idx] = 0;
        }
    }
}

/// Deep-copy the entire user-half address space for fork.
/// Identity map entries are handled by createAddressSpace(). The kernel half
/// (entries 256-511) is shared. Each 4KB user page is fully copied (no COW).
pub fn deepCopyAddressSpace(src_root: *PageTable) ?*PageTable {
    // Create base address space (kernel half + identity map deep-copy)
    const new_root = createAddressSpace() orelse return null;

    // Walk root entries past identity map through user half (256 = kernel half start)
    const id_entries2 = mem.KERNEL_MAP_SIZE / (1024 * 1024 * 1024);
    for (id_entries2..256) |l2_idx| {
        if (src_root.entries[l2_idx] & Flags.VALID == 0) continue;
        if (isLeaf(src_root.entries[l2_idx])) {
            // 1GB superpage — copy as-is
            new_root.entries[l2_idx] = src_root.entries[l2_idx];
            continue;
        }
        const src_l1: *PageTable = tablePtr(pteToPhys(src_root.entries[l2_idx]));

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

        new_root.entries[l2_idx] = physToPte(new_l1_page) | Flags.VALID;
    }

    return new_root;
}

/// Map a single 4KB page in the given address space.
pub fn mapPage(root: *PageTable, virt: u64, phys: u64, flags: u64) ?void {
    // Sv39 indices: [38:30]=L2 (root), [29:21]=L1, [20:12]=L0
    const l2_idx = (virt >> 30) & 0x1FF;
    const l1_idx = (virt >> 21) & 0x1FF;
    const l0_idx = (virt >> 12) & 0x1FF;

    // RISC-V Sv39: U bit is only checked on LEAF PTEs. Non-leaf PTEs must
    // have U/A/D cleared (reserved per spec). Do NOT propagate USER to
    // intermediate entries — unlike x86_64 where U must be set at every level.
    const l1 = getOrAllocTable(root, l2_idx, 0) orelse return null;
    const l0 = getOrAllocTable(l1, l1_idx, 0) orelse return null;

    l0.entries[@intCast(l0_idx)] = physToPte(phys) | flags | Flags.VALID | Flags.READ | Flags.ACCESSED | Flags.DIRTY;
}

/// Map a 2MB superpage (L1 leaf entry) for userspace device mmap.
pub fn mapHugePageUser(root: *PageTable, virt: u64, phys: u64, flags: u64) ?void {
    const l2_idx = (virt >> 30) & 0x1FF;
    const l1_idx = (virt >> 21) & 0x1FF;

    const l1 = getOrAllocTable(root, l2_idx, 0) orelse return null;

    // L1 leaf = 2MB superpage. Physical address must be 2MB-aligned.
    l1.entries[@intCast(l1_idx)] = (physToPte(phys) & MEGA_ADDR_MASK) | flags | Flags.VALID | Flags.READ | Flags.ACCESSED | Flags.DIRTY;
}

/// Unmap a single 4KB page.
pub fn unmapPage(root: *PageTable, virt: u64) void {
    const l2_idx: usize = @intCast((virt >> 30) & 0x1FF);
    const l1_idx: usize = @intCast((virt >> 21) & 0x1FF);
    const l0_idx: usize = @intCast((virt >> 12) & 0x1FF);

    if (root.entries[l2_idx] & Flags.VALID == 0) return;
    if (isLeaf(root.entries[l2_idx])) return; // Can't unmap inside a superpage
    const l1: *PageTable = tablePtr(pteToPhys(root.entries[l2_idx]));

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

/// Switch to a different address space with ASID.
/// When ASIDs are available, the ASID is encoded in SATP[59:44] and no
/// sfence.vma is needed — each ASID has its own TLB partition.
/// Without ASIDs, sfence.vma flushes the entire TLB after SATP switch.
/// (The earlier "sfence.vma kills timer" was caused by PLIC/identity-map
/// bugs, not sfence.vma itself — Linux uses sfence.vma on U74 without issues.)
pub fn switchAddressSpace(root: *PageTable, asid: u16) void {
    _ = asid; // TODO: re-enable ASID once TLB flush is validated
    const virt = @intFromPtr(root);
    const phys = if (virt >= mem.KERNEL_VIRT_BASE) virt - mem.KERNEL_VIRT_BASE else virt;
    const satp_val: u64 = (SATP_MODE_SV39 << 60) | (phys >> 12);
    cpu.csrWrite(cpu.CSR_SATP, satp_val);
    asm volatile ("sfence.vma" ::: .{ .memory = true });
}

/// Switch SATP to the kernel's root page table (ASID 0).
/// Must be called before freeAddressSpace() to avoid walking freed page tables.
pub fn switchToKernel() void {
    const satp_val: u64 = (SATP_MODE_SV39 << 60) | (kernel_root_phys >> 12);
    asm volatile ("fence rw, rw" ::: .{ .memory = true });
    cpu.csrWrite(cpu.CSR_SATP, satp_val);
    asm volatile ("fence.i" ::: .{ .memory = true });
}

/// Get the kernel root page table.
pub fn getKernelRoot() *PageTable {
    return tablePtr(kernel_root_phys);
}

/// Get the SATP value for the kernel page tables (Sv39 mode, ASID 0).
pub fn getKernelSatp() u64 {
    return (SATP_MODE_SV39 << 60) | (kernel_root_phys >> 12);
}

/// Flush TLB entries for a specific ASID (all addresses).
pub fn flushAsid(asid: u16) void {
    cpu.sfenceVmaAsid(asid);
}

/// Walk page tables to translate a virtual address to physical.
pub fn translateVaddr(root: *PageTable, virt: u64) ?u64 {
    const l2_idx: usize = @intCast((virt >> 30) & 0x1FF);
    if (root.entries[l2_idx] & Flags.VALID == 0) return null;
    if (isLeaf(root.entries[l2_idx])) {
        // 1GB superpage
        return pteToPhys(root.entries[l2_idx]) | (virt & 0x3FFFFFFF);
    }
    const l1: *PageTable = tablePtr(pteToPhys(root.entries[l2_idx]));

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
    for (0..256) |l2_idx| {
        if (root.entries[l2_idx] & Flags.VALID == 0) continue;
        if (isLeaf(root.entries[l2_idx])) continue;
        const l1_phys = pteToPhys(root.entries[l2_idx]);
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

            // Free the L0 page table
            pmm.freePage(l0_phys);
        }

        // Free the L1 page table
        pmm.freePage(l1_phys);
    }

    // Free the root page table itself
    const root_phys = @intFromPtr(root) - if (@intFromPtr(root) >= mem.KERNEL_VIRT_BASE) mem.KERNEL_VIRT_BASE else 0;
    pmm.freePage(root_phys);
}
