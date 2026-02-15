/// x86_64 4-level paging: PML4 → PDPT → PD → PT.
///
/// Initial kernel mapping:
///   - Identity map first 4 GB with 2MB huge pages (for transition)
///   - Higher-half map at 0xFFFF_8000_0000_0000 with 2MB huge pages
///   - After switch, kernel runs in higher-half; identity map kept temporarily
///
/// After init(), all page table access goes through the higher-half mapping
/// so that user-space ELF mappings (which overwrite identity-map entries)
/// cannot corrupt the kernel's view of physical memory during syscalls.
const console = @import("../../console.zig");
const serial = @import("../../serial.zig");
const pmm = @import("../../pmm.zig");
const mem = @import("../../mem.zig");

const PAGE_SIZE = mem.PAGE_SIZE;

/// Page table entry flags.
pub const Flags = struct {
    pub const PRESENT: u64 = 1 << 0;
    pub const WRITABLE: u64 = 1 << 1;
    pub const USER: u64 = 1 << 2;
    pub const WRITE_THROUGH: u64 = 1 << 3;
    pub const NO_CACHE: u64 = 1 << 4;
    pub const ACCESSED: u64 = 1 << 5;
    pub const DIRTY: u64 = 1 << 6;
    pub const HUGE_PAGE: u64 = 1 << 7; // 2MB in PD, 1GB in PDPT
    pub const GLOBAL: u64 = 1 << 8;
    pub const NO_EXECUTE: u64 = @as(u64, 1) << 63;
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

/// Kernel PML4 — the root page table for the kernel address space.
var kernel_pml4_phys: u64 = 0;

/// Whether paging has been initialized.
var initialized: bool = false;

pub fn isInitialized() bool {
    return initialized;
}

/// Convert a physical address to a PageTable pointer.
/// Before paging init: uses identity map (UEFI page tables).
/// After paging init: uses higher-half mapping (safe during syscalls,
/// immune to user-space identity-map overwrites).
inline fn tablePtr(phys: u64) *PageTable {
    return @ptrFromInt(if (initialized) phys +% mem.KERNEL_VIRT_BASE else phys);
}

/// Convert a physical address to a byte pointer (for zeroing/copying pages).
/// Same logic as tablePtr but returns [*]u8.
pub inline fn physPtr(phys: u64) [*]u8 {
    return @ptrFromInt(if (initialized) phys +% mem.KERNEL_VIRT_BASE else phys);
}

pub fn init() void {
    // Allocate PML4
    const pml4_page = pmm.allocPage() orelse {
        console.puts("Paging: failed to allocate PML4!\n");
        return;
    };
    kernel_pml4_phys = pml4_page;
    const pml4: *PageTable = @ptrFromInt(pml4_page);
    pml4.zero();

    // Identity map first 4 GB using 2MB huge pages
    // PML4[0] → PDPT → PD entries with HUGE_PAGE
    mapHugeRegion(pml4, 0, 0, 4 * 1024 / 2) orelse {
        console.puts("Paging: failed to map identity region!\n");
        return;
    };

    // Higher-half map: virtual 0xFFFF_8000_0000_0000 → physical 0, 4 GB
    // PML4 index for 0xFFFF_8000_0000_0000 = 256
    mapHugeRegion(pml4, mem.KERNEL_VIRT_BASE, 0, 4 * 1024 / 2) orelse {
        console.puts("Paging: failed to map higher-half region!\n");
        return;
    };

    // Switch CR3
    asm volatile ("mov %[cr3], %%cr3"
        :
        : [cr3] "r" (kernel_pml4_phys),
        : .{ .memory = true });

    initialized = true;

    console.puts("Paging: 4GB identity + higher-half mapped, CR3 switched\n");
}

/// Map `count` 2MB huge pages starting at `virt_base` → `phys_base`.
fn mapHugeRegion(pml4: *PageTable, virt_base: u64, phys_base: u64, count: usize) ?void {
    var virt = virt_base;
    var phys = phys_base;
    for (0..count) |_| {
        mapHugePage(pml4, virt, phys) orelse return null;
        virt += 2 * 1024 * 1024;
        phys += 2 * 1024 * 1024;
    }
}

/// Map a single 2MB huge page: virt → phys.
fn mapHugePage(pml4: *PageTable, virt: u64, phys: u64) ?void {
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pd_idx = (virt >> 21) & 0x1FF;

    // Ensure PDPT exists
    const pdpt = getOrAllocTable(pml4, pml4_idx, 0) orelse return null;

    // Ensure PD exists
    const pd = getOrAllocTable(pdpt, pdpt_idx, 0) orelse return null;

    // Set 2MB huge page entry
    pd.entries[pd_idx] = phys | Flags.PRESENT | Flags.WRITABLE | Flags.HUGE_PAGE;
}

const ADDR_MASK: u64 = 0x000F_FFFF_FFFF_F000;
const HUGE_ADDR_MASK: u64 = 0x000F_FFFF_FFE0_0000; // 2MB-aligned

/// Get the next-level page table at `index`, allocating if necessary.
/// If the entry is a 2MB huge page, split it into 512 × 4KB pages first.
fn getOrAllocTable(table: *PageTable, index: u64, propagate_flags: u64) ?*PageTable {
    const idx: usize = @intCast(index);
    if (table.entries[idx] & Flags.PRESENT != 0) {
        // Propagate USER/WRITABLE to existing intermediate entries
        table.entries[idx] |= propagate_flags;

        if (table.entries[idx] & Flags.HUGE_PAGE != 0) {
            // Split 2MB huge page into 512 × 4KB pages
            const huge_phys = table.entries[idx] & HUGE_ADDR_MASK;
            const base_flags = (table.entries[idx] & 0xFFF) & ~Flags.HUGE_PAGE;

            const pt_page = pmm.allocPage() orelse return null;
            const pt: *PageTable = tablePtr(pt_page);
            for (0..512) |i| {
                pt.entries[i] = (huge_phys + i * PAGE_SIZE) | base_flags;
            }
            // Replace PD entry: now points to a page table instead of a huge page
            table.entries[idx] = pt_page | Flags.PRESENT | Flags.WRITABLE | propagate_flags;
            return pt;
        }
        // Regular table entry — extract physical address
        const addr = table.entries[idx] & ADDR_MASK;
        return tablePtr(addr);
    }

    // Allocate a new page table
    const page = pmm.allocPage() orelse return null;
    const new_table: *PageTable = tablePtr(page);
    new_table.zero();
    table.entries[idx] = page | Flags.PRESENT | Flags.WRITABLE | propagate_flags;
    return new_table;
}

/// Create a new address space (PML4) with the kernel half and identity map.
/// The upper 256 entries (indices 256-511) are shallow-copied from the kernel PML4
/// so that kernel memory is accessible in every address space.
/// Entry 0 (identity map) is deep-copied (private PDPT + PD pages) so that
/// mapPage() can safely split 2MB huge pages for user mappings without
/// corrupting the kernel's identity map.
pub fn createAddressSpace() ?*PageTable {
    const page = pmm.allocPage() orelse return null;
    const new_pml4: *PageTable = tablePtr(page);
    new_pml4.zero();

    const kernel_pml4: *PageTable = tablePtr(kernel_pml4_phys);

    // Copy kernel half (PML4 entries 256-511) — shallow copy is fine,
    // kernel mappings are never modified per-process.
    for (256..512) |i| {
        new_pml4.entries[i] = kernel_pml4.entries[i];
    }

    // Deep-copy identity map (PML4 entry 0).
    // The kernel runs from identity-mapped addresses, so this must be present
    // in every address space. We deep-copy the PDPT and PD levels so that
    // mapPage() can split 2MB huge pages into 4KB entries without corrupting
    // the kernel's shared tables.
    if (kernel_pml4.entries[0] & Flags.PRESENT != 0) {
        const kernel_pdpt: *PageTable = tablePtr(kernel_pml4.entries[0] & ADDR_MASK);
        const new_pdpt_page = pmm.allocPage() orelse return null;
        const new_pdpt: *PageTable = tablePtr(new_pdpt_page);
        new_pdpt.zero();

        for (0..512) |i| {
            if (kernel_pdpt.entries[i] & Flags.PRESENT == 0) continue;

            if (kernel_pdpt.entries[i] & Flags.HUGE_PAGE != 0) {
                // 1GB huge page — just copy the entry (not used currently but safe)
                new_pdpt.entries[i] = kernel_pdpt.entries[i];
            } else {
                // Points to a PD — allocate a private copy
                const kernel_pd: *PageTable = tablePtr(kernel_pdpt.entries[i] & ADDR_MASK);
                const new_pd_page = pmm.allocPage() orelse return null;
                const new_pd: *PageTable = tablePtr(new_pd_page);
                new_pd.* = kernel_pd.*; // Copy all entries (including 2MB huge pages)
                new_pdpt.entries[i] = new_pd_page | (kernel_pdpt.entries[i] & 0xFFF);
            }
        }

        new_pml4.entries[0] = new_pdpt_page | (kernel_pml4.entries[0] & 0xFFF);
    }

    return new_pml4;
}

/// Map a single 4KB page in the given address space.
pub fn mapPage(pml4: *PageTable, virt: u64, phys: u64, flags: u64) ?void {
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pd_idx = (virt >> 21) & 0x1FF;
    const pt_idx = (virt >> 12) & 0x1FF;

    // Propagate USER and WRITABLE to intermediate table entries
    const propagate = flags & (Flags.USER | Flags.WRITABLE);
    const pdpt = getOrAllocTable(pml4, pml4_idx, propagate) orelse return null;
    const pd = getOrAllocTable(pdpt, pdpt_idx, propagate) orelse return null;
    const pt = getOrAllocTable(pd, pd_idx, propagate) orelse return null;

    pt.entries[@intCast(pt_idx)] = phys | flags | Flags.PRESENT;
}

/// Unmap a single 4KB page.
pub fn unmapPage(pml4: *PageTable, virt: u64) void {
    const pml4_idx: usize = @intCast((virt >> 39) & 0x1FF);
    const pdpt_idx: usize = @intCast((virt >> 30) & 0x1FF);
    const pd_idx: usize = @intCast((virt >> 21) & 0x1FF);
    const pt_idx: usize = @intCast((virt >> 12) & 0x1FF);

    if (pml4.entries[pml4_idx] & Flags.PRESENT == 0) return;
    const pdpt: *PageTable = tablePtr(pml4.entries[pml4_idx] & ADDR_MASK);

    if (pdpt.entries[pdpt_idx] & Flags.PRESENT == 0) return;
    const pd: *PageTable = tablePtr(pdpt.entries[pdpt_idx] & ADDR_MASK);

    if (pd.entries[pd_idx] & Flags.PRESENT == 0) return;
    const pt: *PageTable = tablePtr(pd.entries[pd_idx] & ADDR_MASK);

    pt.entries[pt_idx] = 0;

    // Invalidate TLB for this address
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (virt),
        : .{ .memory = true });
}

/// Switch to a different address space.
pub fn switchAddressSpace(pml4: *PageTable) void {
    // pml4 may be a higher-half pointer — convert back to physical for CR3.
    const virt = @intFromPtr(pml4);
    const phys = if (virt >= mem.KERNEL_VIRT_BASE) virt - mem.KERNEL_VIRT_BASE else virt;
    asm volatile ("mov %[cr3], %%cr3"
        :
        : [cr3] "r" (phys),
        : .{ .memory = true });
}

/// Get the physical address of the kernel PML4.
pub fn getKernelPml4() *PageTable {
    return tablePtr(kernel_pml4_phys);
}

/// Walk a PML4 to translate a virtual address to physical.
/// Returns null if the mapping doesn't exist.
pub fn translateVaddr(pml4: *PageTable, virt: u64) ?u64 {
    const pml4_idx: usize = @intCast((virt >> 39) & 0x1FF);
    if (pml4.entries[pml4_idx] & Flags.PRESENT == 0) return null;
    const pdpt: *PageTable = tablePtr(pml4.entries[pml4_idx] & ADDR_MASK);

    const pdpt_idx: usize = @intCast((virt >> 30) & 0x1FF);
    if (pdpt.entries[pdpt_idx] & Flags.PRESENT == 0) return null;
    if (pdpt.entries[pdpt_idx] & Flags.HUGE_PAGE != 0) {
        // 1GB huge page
        return (pdpt.entries[pdpt_idx] & HUGE_ADDR_MASK) | (virt & 0x3FFFFFFF);
    }
    const pd: *PageTable = tablePtr(pdpt.entries[pdpt_idx] & ADDR_MASK);

    const pd_idx: usize = @intCast((virt >> 21) & 0x1FF);
    if (pd.entries[pd_idx] & Flags.PRESENT == 0) return null;
    if (pd.entries[pd_idx] & Flags.HUGE_PAGE != 0) {
        // 2MB huge page
        return (pd.entries[pd_idx] & HUGE_ADDR_MASK) | (virt & 0x1FFFFF);
    }
    const pt: *PageTable = tablePtr(pd.entries[pd_idx] & ADDR_MASK);

    const pt_idx: usize = @intCast((virt >> 12) & 0x1FF);
    if (pt.entries[pt_idx] & Flags.PRESENT == 0) return null;
    return (pt.entries[pt_idx] & ADDR_MASK) | (virt & 0xFFF);
}

/// Free all user-half pages and page tables in an address space.
/// Walks PML4 entries 0-255 (user half). Frees leaf pages, intermediate
/// table pages, and the PML4 page itself.
/// IMPORTANT: Must not be called while the address space is active (CR3).
pub fn freeAddressSpace(pml4: *PageTable) void {
    // Walk user-half only (entries 0-255). Kernel half (256-511) is shared.
    for (0..256) |pml4_idx| {
        if (pml4.entries[pml4_idx] & Flags.PRESENT == 0) continue;
        const pdpt_phys = pml4.entries[pml4_idx] & ADDR_MASK;
        const pdpt: *PageTable = tablePtr(pdpt_phys);

        for (0..512) |pdpt_idx| {
            if (pdpt.entries[pdpt_idx] & Flags.PRESENT == 0) continue;
            if (pdpt.entries[pdpt_idx] & Flags.HUGE_PAGE != 0) {
                // 1GB huge page — don't free (kernel identity map)
                continue;
            }
            const pd_phys = pdpt.entries[pdpt_idx] & ADDR_MASK;
            const pd: *PageTable = tablePtr(pd_phys);

            for (0..512) |pd_idx| {
                if (pd.entries[pd_idx] & Flags.PRESENT == 0) continue;
                if (pd.entries[pd_idx] & Flags.HUGE_PAGE != 0) {
                    // 2MB huge page — part of identity map, don't free
                    continue;
                }
                const pt_phys = pd.entries[pd_idx] & ADDR_MASK;
                const pt: *PageTable = tablePtr(pt_phys);

                // Free leaf (4KB) pages that have USER flag
                for (0..512) |pt_idx| {
                    if (pt.entries[pt_idx] & Flags.PRESENT == 0) continue;
                    if (pt.entries[pt_idx] & Flags.USER != 0) {
                        pmm.freePage(pt.entries[pt_idx] & ADDR_MASK);
                    }
                }

                // Free the PT page itself if it has USER flag in PD entry
                if (pd.entries[pd_idx] & Flags.USER != 0) {
                    pmm.freePage(pt_phys);
                }
            }

            // Free the PD page itself if it has USER flag in PDPT entry
            if (pdpt.entries[pdpt_idx] & Flags.USER != 0) {
                pmm.freePage(pd_phys);
            }
        }

        // Free the PDPT page
        pmm.freePage(pdpt_phys);
    }

    // Free the PML4 page itself
    const pml4_phys = @intFromPtr(pml4) - if (@intFromPtr(pml4) >= mem.KERNEL_VIRT_BASE) mem.KERNEL_VIRT_BASE else 0;
    pmm.freePage(pml4_phys);
}
