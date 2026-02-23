"""Disk image creation, rootfs preparation, and Linux ELF builder."""
import os
import struct
import subprocess

from .config import PROJECT_DIR, log


def create_test_disk(tmpdir, rootfs_dir, disk_size_mb=8192):
    """Create a fresh test disk image with GPT + fxfs."""
    disk_img = os.path.join(tmpdir, "test-disk.img")
    mkgpt = os.path.join(PROJECT_DIR, "zig-out", "bin", "mkgpt")
    mkfxfs = os.path.join(PROJECT_DIR, "zig-out", "bin", "mkfxfs")

    # Create blank disk (non-sparse, fully allocated)
    log("DISK", f"Creating {disk_size_mb} MB test disk...")
    with open(disk_img, "wb") as f:
        chunk = b"\0" * (1024 * 1024)
        for _ in range(disk_size_mb):
            f.write(chunk)

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
