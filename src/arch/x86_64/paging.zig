/// x86_64 4-level paging: PML4 → PDPT → PD → PT.
///
/// Initial kernel mapping:
///   - Identity map first 4 GB with 2MB huge pages (for transition)
///   - Higher-half map at 0xFFFF_8000_0000_0000 with 2MB huge pages
///   - After switch, kernel runs in higher-half; identity map kept temporarily
///
/// Later: createAddressSpace() for per-process page tables.
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
    const pdpt = getOrAllocTable(pml4, pml4_idx) orelse return null;

    // Ensure PD exists
    const pd = getOrAllocTable(pdpt, pdpt_idx) orelse return null;

    // Set 2MB huge page entry
    pd.entries[pd_idx] = phys | Flags.PRESENT | Flags.WRITABLE | Flags.HUGE_PAGE;
}

/// Get the next-level page table at `index`, allocating if necessary.
fn getOrAllocTable(table: *PageTable, index: u64) ?*PageTable {
    const idx: usize = @intCast(index);
    if (table.entries[idx] & Flags.PRESENT != 0) {
        // Already exists — extract physical address
        const addr = table.entries[idx] & 0x000F_FFFF_FFFF_F000;
        return @ptrFromInt(addr);
    }

    // Allocate a new page table
    const page = pmm.allocPage() orelse return null;
    const new_table: *PageTable = @ptrFromInt(page);
    new_table.zero();
    table.entries[idx] = page | Flags.PRESENT | Flags.WRITABLE;
    return new_table;
}

/// Create a new address space (PML4) with the kernel half pre-mapped.
/// The upper 256 entries (indices 256-511) are copied from the kernel PML4
/// so that kernel memory is accessible in every address space.
pub fn createAddressSpace() ?*PageTable {
    const page = pmm.allocPage() orelse return null;
    const new_pml4: *PageTable = @ptrFromInt(page);
    new_pml4.zero();

    // Copy kernel half (PML4 entries 256-511) from kernel PML4
    const kernel_pml4: *PageTable = @ptrFromInt(kernel_pml4_phys);
    for (256..512) |i| {
        new_pml4.entries[i] = kernel_pml4.entries[i];
    }

    return new_pml4;
}

/// Map a single 4KB page in the given address space.
pub fn mapPage(pml4: *PageTable, virt: u64, phys: u64, flags: u64) ?void {
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pd_idx = (virt >> 21) & 0x1FF;
    const pt_idx = (virt >> 12) & 0x1FF;

    const pdpt = getOrAllocTable(pml4, pml4_idx) orelse return null;
    const pd = getOrAllocTable(pdpt, pdpt_idx) orelse return null;
    const pt = getOrAllocTable(pd, pd_idx) orelse return null;

    pt.entries[@intCast(pt_idx)] = phys | flags | Flags.PRESENT;
}

/// Unmap a single 4KB page.
pub fn unmapPage(pml4: *PageTable, virt: u64) void {
    const pml4_idx: usize = @intCast((virt >> 39) & 0x1FF);
    const pdpt_idx: usize = @intCast((virt >> 30) & 0x1FF);
    const pd_idx: usize = @intCast((virt >> 21) & 0x1FF);
    const pt_idx: usize = @intCast((virt >> 12) & 0x1FF);

    if (pml4.entries[pml4_idx] & Flags.PRESENT == 0) return;
    const pdpt: *PageTable = @ptrFromInt(pml4.entries[pml4_idx] & 0x000F_FFFF_FFFF_F000);

    if (pdpt.entries[pdpt_idx] & Flags.PRESENT == 0) return;
    const pd: *PageTable = @ptrFromInt(pdpt.entries[pdpt_idx] & 0x000F_FFFF_FFFF_F000);

    if (pd.entries[pd_idx] & Flags.PRESENT == 0) return;
    const pt: *PageTable = @ptrFromInt(pd.entries[pd_idx] & 0x000F_FFFF_FFFF_F000);

    pt.entries[pt_idx] = 0;

    // Invalidate TLB for this address
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (virt),
        : .{ .memory = true });
}

/// Switch to a different address space.
pub fn switchAddressSpace(pml4: *PageTable) void {
    const phys = @intFromPtr(pml4);
    asm volatile ("mov %[cr3], %%cr3"
        :
        : [cr3] "r" (phys),
        : .{ .memory = true });
}

/// Get the physical address of the kernel PML4.
pub fn getKernelPml4() *PageTable {
    return @ptrFromInt(kernel_pml4_phys);
}
