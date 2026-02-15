/// ELF64 loader for Fornax.
///
/// Loads PT_LOAD segments from an ELF binary into a process's address space.
/// Only supports statically-linked ELF64 executables.
const console = @import("console.zig");
const pmm = @import("pmm.zig");
const mem = @import("mem.zig");

const paging = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("arch/x86_64/paging.zig"),
    else => struct {
        pub const PageTable = struct { entries: [512]u64 };
        pub const Flags = struct {
            pub const PRESENT: u64 = 1;
            pub const WRITABLE: u64 = 2;
            pub const USER: u64 = 4;
        };
        pub fn mapPage(_: anytype, _: u64, _: u64, _: u64) ?void {}
        pub inline fn physPtr(phys: u64) [*]u8 {
            return @ptrFromInt(phys);
        }
    },
};

// ELF64 constants
const ELF_MAGIC = [4]u8{ 0x7F, 'E', 'L', 'F' };
const ELFCLASS64 = 2;
const ELFDATA2LSB = 1;
const ET_EXEC = 2;
const EM_X86_64 = 62;
const PT_LOAD = 1;
const PF_W = 2;
const PF_X = 1;

/// ELF64 file header.
const Elf64Header = extern struct {
    e_ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u64,
    e_phoff: u64,
    e_shoff: u64,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

/// ELF64 program header.
const Elf64Phdr = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

pub const LoadError = error{
    InvalidMagic,
    Not64Bit,
    NotExecutable,
    WrongArch,
    NoSegments,
    OutOfMemory,
};

pub const LoadResult = struct {
    entry_point: u64,
    brk: u64, // highest loaded address (for initial brk)
};

/// Load an ELF64 binary into the given page table.
/// `elf_data` is the raw bytes of the ELF file.
pub fn load(page_table: *paging.PageTable, elf_data: []const u8) LoadError!LoadResult {
    if (elf_data.len < @sizeOf(Elf64Header)) return error.InvalidMagic;

    const header: *align(1) const Elf64Header = @ptrCast(elf_data.ptr);

    // Validate ELF magic
    if (!std.mem.eql(u8, header.e_ident[0..4], &ELF_MAGIC)) return error.InvalidMagic;
    if (header.e_ident[4] != ELFCLASS64) return error.Not64Bit;
    if (header.e_type != ET_EXEC) return error.NotExecutable;
    if (header.e_machine != EM_X86_64) return error.WrongArch;
    if (header.e_phnum == 0) return error.NoSegments;

    var highest_addr: u64 = 0;

    // Iterate program headers
    var i: u16 = 0;
    while (i < header.e_phnum) : (i += 1) {
        const ph_offset = header.e_phoff + @as(u64, i) * header.e_phentsize;
        if (ph_offset + @sizeOf(Elf64Phdr) > elf_data.len) continue;

        const phdr: *align(1) const Elf64Phdr = @ptrCast(elf_data.ptr + ph_offset);

        if (phdr.p_type != PT_LOAD) continue;

        // Load this segment
        loadSegment(page_table, elf_data, phdr) orelse return error.OutOfMemory;

        const seg_end = phdr.p_vaddr + phdr.p_memsz;
        if (seg_end > highest_addr) highest_addr = seg_end;
    }

    // Align brk to page boundary
    const brk = (highest_addr + mem.PAGE_SIZE - 1) & ~@as(u64, mem.PAGE_SIZE - 1);

    return .{
        .entry_point = header.e_entry,
        .brk = brk,
    };
}

const std = @import("std");

/// Load a single PT_LOAD segment: allocate pages, map them, copy data.
fn loadSegment(page_table: *paging.PageTable, elf_data: []const u8, phdr: *align(1) const Elf64Phdr) ?void {
    const vaddr_start = phdr.p_vaddr & ~@as(u64, mem.PAGE_SIZE - 1);
    const vaddr_end = (phdr.p_vaddr + phdr.p_memsz + mem.PAGE_SIZE - 1) & ~@as(u64, mem.PAGE_SIZE - 1);

    // Determine page flags
    var flags: u64 = paging.Flags.PRESENT | paging.Flags.USER;
    if (phdr.p_flags & PF_W != 0) flags |= paging.Flags.WRITABLE;

    // Map pages for this segment
    var vaddr = vaddr_start;
    while (vaddr < vaddr_end) : (vaddr += mem.PAGE_SIZE) {
        const phys = pmm.allocPage() orelse return null;

        // Zero the page first (use higher-half to avoid identity-map conflicts)
        const page_ptr: [*]u8 = paging.physPtr(phys);
        @memset(page_ptr[0..mem.PAGE_SIZE], 0);

        // Copy data from ELF file if this page overlaps the file data region
        const file_start = phdr.p_vaddr;
        const file_end = phdr.p_vaddr + phdr.p_filesz;

        if (vaddr + mem.PAGE_SIZE > file_start and vaddr < file_end) {
            // Calculate overlap between this page and the file data
            const copy_start = if (vaddr > file_start) vaddr else file_start;
            const copy_end = if (vaddr + mem.PAGE_SIZE < file_end) vaddr + mem.PAGE_SIZE else file_end;
            const copy_len = copy_end - copy_start;

            const page_offset: usize = @intCast(copy_start - vaddr);
            const file_offset: usize = @intCast(phdr.p_offset + (copy_start - phdr.p_vaddr));

            if (file_offset + copy_len <= elf_data.len) {
                const dest = page_ptr[page_offset..][0..@intCast(copy_len)];
                const src = elf_data[file_offset..][0..@intCast(copy_len)];
                @memcpy(dest, src);
            }
        }

        // Map into the process's address space
        paging.mapPage(page_table, vaddr, phys, flags) orelse return null;
    }
}
