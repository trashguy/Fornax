"""Disk image creation, rootfs preparation, and Linux ELF builder."""
import os
import struct
import subprocess

from .config import PROJECT_DIR, log


def create_test_disk(tmpdir, rootfs_dir, disk_size_mb=256):
    """Create a fresh test disk image with GPT + fxfs."""
    disk_img = os.path.join(tmpdir, "test-disk.img")
    mkgpt = os.path.join(PROJECT_DIR, "zig-out", "bin", "mkgpt")
    mkfxfs = os.path.join(PROJECT_DIR, "zig-out", "bin", "mkfxfs")

    # Create blank disk (sparse — only metadata uses real space)
    log("DISK", f"Creating {disk_size_mb} MB test disk...")
    with open(disk_img, "wb") as f:
        f.truncate(disk_size_mb * 1024 * 1024)

    # GPT partition table
    log("DISK", "Creating GPT partition table...")
    subprocess.run([mkgpt, disk_img], check=True, capture_output=True)

    # fxfs format
    disk_size = os.path.getsize(disk_img)
    part_offset = 1048576  # 1 MB
    part_size = disk_size - part_offset - 33 * 512
    log("DISK", f"Formatting fxfs (offset={part_offset}, size={part_size})...")
    subprocess.run(
        [mkfxfs, disk_img, "--offset", str(part_offset),
         "--size", str(part_size), "--populate", rootfs_dir],
        check=True, capture_output=True,
    )

    return disk_img


def prepare_rootfs(rootfs_dir):
    """Ensure rootfs has required /etc files (same as run-x86_64.sh)."""
    etc_dir = os.path.join(rootfs_dir, "etc")
    os.makedirs(etc_dir, exist_ok=True)
    for d in ["tmp", "proc", "dev", "net", "home", "var"]:
        os.makedirs(os.path.join(rootfs_dir, d), exist_ok=True)

    with open(os.path.join(etc_dir, "fstab"), "w") as f:
        f.write("# /etc/fstab - Fornax filesystem table\n# Root (/) and /dev/ are kernel-mounted\n")

    with open(os.path.join(etc_dir, "passwd"), "w") as f:
        f.write("root:x:0:0:System Administrator:/:/bin/fsh\n")

    with open(os.path.join(etc_dir, "shadow"), "w") as f:
        f.write("root:x\n")

    with open(os.path.join(etc_dir, "group"), "w") as f:
        f.write("root:x:0:root\nusers:x:100:\n")

    # Limit to 1 VT during tests to reduce SMP fault surface
    with open(os.path.join(etc_dir, "vts"), "w") as f:
        f.write("1\n")


def create_linux_hello_elf():
    """Create minimal static x86_64 Linux ELF: write(1,'hello-linux-compat\\n') + exit(0).

    Uses Linux syscall numbers (1=write, 60=exit) to test the kernel's
    Linux compatibility layer.  Loaded at 0x40000000 to match Fornax
    user address space conventions.
    """
    msg = b"hello-linux-compat\n"

    # x86_64 machine code
    code = bytes([
        0xb8, 0x01, 0x00, 0x00, 0x00,                     # mov eax, 1  (sys_write)
        0xbf, 0x01, 0x00, 0x00, 0x00,                     # mov edi, 1  (stdout)
        0x48, 0x8d, 0x35, 0x10, 0x00, 0x00, 0x00,         # lea rsi, [rip+16]
        0xba, len(msg), 0x00, 0x00, 0x00,                  # mov edx, <len>
        0x0f, 0x05,                                         # syscall
        0xb8, 0x3c, 0x00, 0x00, 0x00,                     # mov eax, 60 (sys_exit)
        0x31, 0xff,                                         # xor edi, edi
        0x0f, 0x05,                                         # syscall
    ]) + msg

    file_size = 64 + 56 + len(code)
    base = 0x40000000
    entry = base + 0x78  # code starts after ELF header + phdr

    # ELF header (64 bytes)
    elf = b'\x7fELF'
    elf += struct.pack('<BBBBB', 2, 1, 1, 0, 0) + b'\x00' * 7
    elf += struct.pack('<HHI', 2, 0x3e, 1)           # ET_EXEC, x86_64
    elf += struct.pack('<QQQ', entry, 64, 0)          # entry, phoff, shoff
    elf += struct.pack('<IHHHHHH', 0, 64, 56, 1, 0, 0, 0)

    # Program header (56 bytes) — single PT_LOAD
    elf += struct.pack('<II', 1, 5)                    # PT_LOAD, PF_R|PF_X
    elf += struct.pack('<QQQQQQ', 0, base, base, file_size, file_size, 0x1000)

    elf += code
    assert len(elf) == file_size
    return elf


def create_linux_hello_elf_riscv64():
    """Create minimal static riscv64 Linux ELF: write(1,'hello-linux-compat\\n') + exit(0).

    Uses generic Linux syscall numbers (64=write, 93=exit) with ecall.
    Loaded at 0x40000000 to match Fornax user address space conventions.
    """
    msg = b"hello-linux-compat\n"
    msg_len = len(msg)

    def addi(rd, rs1, imm12):
        """Encode ADDI rd, rs1, imm12"""
        return struct.pack('<I', ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0 << 12) | (rd << 7) | 0x13)

    def auipc(rd, imm20):
        """Encode AUIPC rd, imm20"""
        return struct.pack('<I', ((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0x17)

    def ecall():
        """Encode ECALL"""
        return struct.pack('<I', 0x00000073)

    # RISC-V register names: a0=x10, a1=x11, a2=x12, a7=x17
    # 9 instructions × 4 bytes = 36 bytes, msg at offset 36
    # auipc a1 is at offset 8, so msg offset from there = 36 - 8 = 28
    code = b''
    code += addi(17, 0, 64)   # li a7, 64  (sys_write)
    code += addi(10, 0, 1)    # li a0, 1   (stdout)
    code += auipc(11, 0)      # auipc a1, 0 (a1 = PC)
    code += addi(11, 11, 28)  # addi a1, a1, 28 (point to msg)
    code += addi(12, 0, msg_len)  # li a2, <len>
    code += ecall()           # ecall
    code += addi(17, 0, 93)   # li a7, 93  (sys_exit)
    code += addi(10, 0, 0)    # li a0, 0
    code += ecall()           # ecall
    code += msg

    file_size = 64 + 56 + len(code)
    base = 0x40000000
    entry = base + 0x78  # code starts after ELF header + phdr

    # ELF header (64 bytes)
    elf = b'\x7fELF'
    elf += struct.pack('<BBBBB', 2, 1, 1, 0, 0) + b'\x00' * 7
    elf += struct.pack('<HHI', 2, 0xF3, 1)           # ET_EXEC, EM_RISCV
    elf += struct.pack('<QQQ', entry, 64, 0)          # entry, phoff, shoff
    elf += struct.pack('<IHHHHHH', 0, 64, 56, 1, 0, 0, 0)

    # Program header (56 bytes) — single PT_LOAD
    elf += struct.pack('<II', 1, 5)                    # PT_LOAD, PF_R|PF_X
    elf += struct.pack('<QQQQQQ', 0, base, base, file_size, file_size, 0x1000)

    elf += code
    assert len(elf) == file_size
    return elf


def create_linux_hello_elf_aarch64():
    """Create minimal static aarch64 Linux ELF: write(1,'hello-linux-compat\\n') + exit(0).

    Uses generic Linux syscall numbers (64=write, 93=exit) with svc #0.
    Loaded at 0x40000000 to match Fornax user address space conventions.
    """
    msg = b"hello-linux-compat\n"
    msg_len = len(msg)

    def movz(rd, imm16):
        """Encode MOVZ Xrd, #imm16"""
        return struct.pack('<I', 0xd2800000 | (imm16 << 5) | rd)

    def adr(rd, offset):
        """Encode ADR Xrd, offset (PC-relative, ±1MB)"""
        immlo = offset & 3
        immhi = (offset >> 2) & 0x7FFFF
        return struct.pack('<I', 0x10000000 | (immlo << 29) | (immhi << 5) | rd)

    def svc0():
        """Encode SVC #0"""
        return struct.pack('<I', 0xd4000001)

    # 9 instructions × 4 bytes = 36 bytes, then msg follows
    # adr x1 offset: from instruction 2 (offset 8) to msg (offset 36) = 28
    code = b''
    code += movz(8, 64)       # mov x8, #64  (sys_write)
    code += movz(0, 1)        # mov x0, #1   (stdout)
    code += adr(1, 24)        # adr x1, msg  (24 bytes ahead from PC)
    code += movz(2, msg_len)  # mov x2, #len
    code += svc0()            # svc #0
    code += movz(8, 93)       # mov x8, #93  (sys_exit)
    code += movz(0, 0)        # mov x0, #0
    code += svc0()            # svc #0
    # padding to align (optional, not needed for this)
    code += msg

    file_size = 64 + 56 + len(code)
    base = 0x40000000
    entry = base + 0x78  # code starts after ELF header + phdr

    # ELF header (64 bytes)
    elf = b'\x7fELF'
    elf += struct.pack('<BBBBB', 2, 1, 1, 0, 0) + b'\x00' * 7
    elf += struct.pack('<HHI', 2, 0xB7, 1)           # ET_EXEC, EM_AARCH64
    elf += struct.pack('<QQQ', entry, 64, 0)          # entry, phoff, shoff
    elf += struct.pack('<IHHHHHH', 0, 64, 56, 1, 0, 0, 0)

    # Program header (56 bytes) — single PT_LOAD
    elf += struct.pack('<II', 1, 5)                    # PT_LOAD, PF_R|PF_X
    elf += struct.pack('<QQQQQQ', 0, base, base, file_size, file_size, 0x1000)

    elf += code
    assert len(elf) == file_size
    return elf
