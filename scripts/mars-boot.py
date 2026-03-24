#!/usr/bin/env python3
"""mars-boot.py — Build, TFTP-serve, and boot Fornax on Milk-V Mars over serial.

Workflow:
  1. Build riscv64 kernel with -Dboard=milkv_mars
  2. Start an embedded TFTP server serving the kernel binary
  3. Connect to Mars serial console
  4. Interrupt U-Boot autoboot
  5. Send TFTP boot commands
  6. Hand off to interactive serial console

Requirements: pyserial (pip install pyserial)
TFTP server: uses Python's socketserver (no external deps)

Usage:
  ./scripts/mars-boot.py                    # defaults
  ./scripts/mars-boot.py -p /dev/ttyUSB1    # different serial port
  ./scripts/mars-boot.py --ip 10.0.0.5      # different host IP
  ./scripts/mars-boot.py --no-build         # skip build step
  ./scripts/mars-boot.py --no-tftp          # skip TFTP, assume SD card boot
  ./scripts/mars-boot.py --install          # build & flash SD card image
  ./scripts/mars-boot.py --monitor          # just connect to serial (no boot)
"""

import argparse
import binascii
import hashlib
import os
import select
import socket
import struct
import subprocess
import sys
import termios
import threading
import time
import tty

import serial

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KERNEL_PATH = os.path.join(PROJECT_DIR, "zig-out", "esp-riscv64", "fornax-riscv64")

# U-Boot defaults for StarFive VisionFive 2 / Milk-V Mars
UBOOT_PROMPT = b"StarFive #"
UBOOT_PROMPT_ALT = b"=> "  # some U-Boot builds use this
KERNEL_ADDR = "0x40200000"
BAUD_RATE = 115200


# ── Minimal TFTP server (RFC 1350) ──────────────────────────────────

class TftpServer(threading.Thread):
    """Single-file read-only TFTP server with RFC 2348 blksize negotiation."""

    TFTP_RRQ = 1
    TFTP_DATA = 3
    TFTP_ACK = 4
    TFTP_ERROR = 5
    TFTP_OACK = 6
    DEFAULT_BLOCK_SIZE = 512

    def __init__(self, filepath, bind_ip="0.0.0.0", port=69):
        super().__init__(daemon=True)
        self.filepath = filepath
        self.bind_ip = bind_ip
        self.port = port
        self.served = threading.Event()
        self._stop = threading.Event()
        self.sock = None

    def run(self):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.settimeout(1.0)
        try:
            self.sock.bind((self.bind_ip, self.port))
        except PermissionError:
            print(f"[tftp] Port {self.port} requires root. Trying 6969...")
            self.port = 6969
            self.sock.bind((self.bind_ip, self.port))

        print(f"[tftp] Serving {os.path.basename(self.filepath)} on :{self.port}")

        while not self._stop.is_set():
            try:
                data, addr = self.sock.recvfrom(2048)
            except socket.timeout:
                continue

            opcode = struct.unpack("!H", data[:2])[0]
            if opcode == self.TFTP_RRQ:
                print(f"[tftp] RRQ from {addr[0]}:{addr[1]}")
                self._handle_rrq(addr, data)

        self.sock.close()

    def _handle_rrq(self, client_addr, data):
        """Send file to client with optional blksize negotiation and block wrapping."""
        xfer = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        xfer.settimeout(5.0)

        try:
            with open(self.filepath, "rb") as f:
                file_data = f.read()
        except FileNotFoundError:
            err = struct.pack("!HH", self.TFTP_ERROR, 1) + b"File not found\x00"
            xfer.sendto(err, client_addr)
            xfer.close()
            return

        # Parse RRQ options: \x00\x01<filename>\x00<mode>\x00[<opt>\x00<val>\x00...]
        parts = data[2:].split(b"\x00")
        block_size = self.DEFAULT_BLOCK_SIZE
        oack_opts = b""

        # Options start at index 2 (after filename and mode)
        i = 2
        while i + 1 < len(parts):
            opt = parts[i].lower()
            val = parts[i + 1]
            if opt == b"blksize" and val:
                requested = int(val)
                block_size = min(max(requested, 8), 65464)
                oack_opts += b"blksize\x00" + str(block_size).encode() + b"\x00"
            elif opt == b"tsize" and val:
                oack_opts += b"tsize\x00" + str(len(file_data)).encode() + b"\x00"
            i += 2

        # Send OACK if client requested options
        if oack_opts:
            oack = struct.pack("!H", self.TFTP_OACK) + oack_opts
            acked = False
            for _ in range(5):
                xfer.sendto(oack, client_addr)
                try:
                    ack, _ = xfer.recvfrom(4)
                    ack_op, ack_blk = struct.unpack("!HH", ack[:4])
                    if ack_op == self.TFTP_ACK and ack_blk == 0:
                        acked = True
                        break
                except socket.timeout:
                    pass
            if not acked:
                print("[tftp] OACK not acknowledged, falling back to 512")
                block_size = self.DEFAULT_BLOCK_SIZE

        total = len(file_data)
        block = 1
        offset = 0

        while True:
            chunk = file_data[offset:offset + block_size]
            # Block number wraps at 16 bits (for transfers > 32 MB)
            wire_block = block & 0xFFFF
            pkt = struct.pack("!HH", self.TFTP_DATA, wire_block) + chunk
            retries = 0

            while retries < 5:
                xfer.sendto(pkt, client_addr)
                try:
                    ack, _ = xfer.recvfrom(4)
                    ack_op, ack_blk = struct.unpack("!HH", ack[:4])
                    if ack_op == self.TFTP_ACK and ack_blk == wire_block:
                        break
                except socket.timeout:
                    retries += 1

            if retries >= 5:
                print(f"\n[tftp] Transfer failed at block {block}")
                break

            offset += block_size
            block += 1

            # Progress (update every 256 blocks to reduce overhead)
            if block % 256 == 0 or len(chunk) < block_size:
                pct = min(100, offset * 100 // total) if total > 0 else 100
                mb = offset / (1024 * 1024)
                print(f"\r[tftp] {mb:.1f}/{total/(1024*1024):.1f} MiB ({pct}%)",
                      end="", flush=True)

            if len(chunk) < block_size:
                print(f"\n[tftp] Transfer complete ({total} bytes, blksize={block_size})")
                self.served.set()
                break

        xfer.close()

    def stop(self):
        self._stop.set()


# ── Serial helpers ──────────────────────────────────────────────────

def serial_ok(ser):
    """Check if serial port is still connected."""
    try:
        _ = ser.in_waiting
        return True
    except (OSError, serial.SerialException):
        return False


def serial_reconnect(ser):
    """Wait for serial port to reappear after unplug/reset."""
    port = ser.port
    baud = ser.baudrate
    print(f"\n[serial] Lost connection — waiting for {port}...")
    ser.close()
    while True:
        time.sleep(0.5)
        if os.path.exists(port):
            try:
                new_ser = serial.Serial(port, baud, timeout=0.1, dsrdtr=True)
                new_ser.dtr = False  # Don't assert DTR — it resets the Mars
                print(f"[serial] Reconnected to {port}")
                return new_ser
            except serial.SerialException:
                pass
    return None


def wait_for(ser, patterns, timeout=30, logfile=None):
    """Read serial until one of `patterns` is seen. Returns (index, accumulated_data)."""
    if isinstance(patterns, (bytes, str)):
        patterns = [patterns]
    patterns = [p.encode() if isinstance(p, str) else p for p in patterns]

    buf = b""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if ser.in_waiting:
                chunk = ser.read(ser.in_waiting)
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
                if logfile:
                    logfile.write(chunk)
                    logfile.flush()
                buf += chunk
                for i, pat in enumerate(patterns):
                    if pat in buf:
                        return i, buf
            else:
                time.sleep(0.01)
        except (OSError, serial.SerialException):
            return -1, buf
    return -1, buf


def send_cmd(ser, cmd, echo=True):
    """Send a command string to serial, appending newline."""
    line = cmd.encode() if isinstance(cmd, str) else cmd
    try:
        ser.write(line + b"\r\n")
        ser.flush()
    except (OSError, serial.SerialException):
        pass
    if echo:
        print(f"[cmd] {cmd}")


def interrupt_uboot(ser, timeout=30):
    """Spam keys to interrupt U-Boot autoboot countdown.
    Returns (success, ser) — ser may be a new object after reconnect."""
    print("[boot] Waiting for U-Boot prompt (press reset on Mars if needed)...")
    deadline = time.monotonic() + timeout
    buf = b""
    saw_countdown = False
    while time.monotonic() < deadline:
        if not serial_ok(ser):
            ser = serial_reconnect(ser)
            deadline = time.monotonic() + timeout  # reset timeout after reconnect
            buf = b""

        try:
            ser.write(b" ")
            ser.flush()
        except (OSError, serial.SerialException):
            continue
        time.sleep(0.05)

        try:
            if not ser.in_waiting:
                continue
            chunk = ser.read(ser.in_waiting)
        except (OSError, serial.SerialException):
            continue

        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()
        buf += chunk
        # Keep buf from growing unbounded
        if len(buf) > 8192:
            buf = buf[-4096:]

        if b"Hit any key" in chunk or b"autoboot" in chunk:
            saw_countdown = True

        # Only declare success when we see an actual U-Boot prompt
        if UBOOT_PROMPT in buf or UBOOT_PROMPT_ALT in buf:
            # Drain any remaining output
            time.sleep(0.2)
            try:
                if ser.in_waiting:
                    rest = ser.read(ser.in_waiting)
                    sys.stdout.buffer.write(rest)
                    sys.stdout.buffer.flush()
            except (OSError, serial.SerialException):
                pass
            print("\n[boot] U-Boot prompt confirmed")
            return True, ser

    if saw_countdown:
        print("\n[boot] Saw countdown but never got prompt — boot may have continued")
    print("\n[boot] Timeout waiting for U-Boot")
    return False, ser


class RestartRequested(Exception):
    """Raised when Ctrl-R is pressed in the interactive console."""
    pass


def interactive_console(ser, logfile=None, reconnect=False):
    """Pass-through serial console with raw terminal input.

    Returns normally on Ctrl-D / Ctrl-].
    Raises RestartRequested on Ctrl-R (rebuild + reinstall cycle).
    """
    print("[console] Interactive serial console (Ctrl-D or Ctrl-] to exit, Ctrl-R to rebuild+reinstall)")

    old_settings = termios.tcgetattr(sys.stdin)
    try:
        tty.setraw(sys.stdin.fileno())
        while True:
            if not serial_ok(ser):
                if not reconnect:
                    return
                # Temporarily restore terminal so reconnect messages are readable
                termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)
                ser = serial_reconnect(ser)
                tty.setraw(sys.stdin.fileno())
                continue

            try:
                r, _, _ = select.select([sys.stdin, ser], [], [], 0.1)
            except (OSError, ValueError):
                if not reconnect:
                    return
                termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)
                ser = serial_reconnect(ser)
                tty.setraw(sys.stdin.fileno())
                continue

            for src in r:
                if src is sys.stdin:
                    ch = os.read(sys.stdin.fileno(), 1)
                    if not ch or ch in (b"\x04", b"\x1d"):  # EOF, Ctrl-D, Ctrl-]
                        return
                    if ch == b"\x12":  # Ctrl-R
                        raise RestartRequested()
                    try:
                        ser.write(ch)
                        ser.flush()
                    except (OSError, serial.SerialException):
                        pass
                elif src is ser:
                    try:
                        if ser.in_waiting:
                            data = ser.read(ser.in_waiting)
                            os.write(sys.stdout.fileno(), data)
                            if logfile:
                                logfile.write(data)
                                logfile.flush()
                    except (OSError, serial.SerialException):
                        pass
    except KeyboardInterrupt:
        pass
    finally:
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)
        print("\n[console] Disconnected")


# ── Auto-detect host IP on the Mars-facing interface ────────────────

def detect_host_ip():
    """Guess the host IP that the Mars can reach (non-loopback)."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "192.168.1.100"


# ── SD card image builder ────────────────────────────────────────────

# SD image layout (512-byte sectors):
#   LBA 0:        Protective MBR
#   LBA 1:        Primary GPT header
#   LBA 2-33:     GPT partition entries
#   LBA 2048:     Kernel binary (raw, loaded by U-Boot)
#   LBA 8192:     INITRD (raw, loaded by U-Boot)
#   LBA 20480:    Partition 1 "Fornax Root" (fxfs filesystem)
#   End:          Backup GPT entries + header

INSTALL_ADDR = "0x50000000"
IMG_KERNEL_LBA = 2048       # 1 MiB offset
IMG_INITRD_LBA = 8192       # 4 MiB offset
IMG_ROOT_LBA = 20480        # 10 MiB offset
IMG_ROOT_SIZE_MB = 80       # 80 MiB fxfs partition
SECTOR = 512
GPT_ENTRY_COUNT = 128
GPT_ENTRY_SIZE = 128
GPT_ENTRIES_SECTORS = (GPT_ENTRY_COUNT * GPT_ENTRY_SIZE + SECTOR - 1) // SECTOR

# Linux filesystem GUID (mixed-endian per UEFI spec)
LINUX_FS_GUID = bytes([
    0xAF, 0x3D, 0xC6, 0x0F,
    0x83, 0x84,
    0x72, 0x47,
    0x8E, 0x79,
    0x3D, 0x69, 0xD8, 0x47, 0x7D, 0xE4,
])


def build_sdimg(kernel_bin_path, initrd_path, rootfs_dir, mkfxfs_path):
    """Build a complete SD card image: GPT + kernel + initrd + fxfs rootfs."""

    root_sectors = IMG_ROOT_SIZE_MB * 1024 * 1024 // SECTOR
    last_data_lba = IMG_ROOT_LBA + root_sectors - 1
    total_sectors = last_data_lba + 1 + GPT_ENTRIES_SECTORS + 1
    total_size = total_sectors * SECTOR

    print(f"[install] Image: {total_size // (1024*1024)} MiB ({total_sectors} sectors)")

    # Read kernel and initrd
    with open(kernel_bin_path, "rb") as f:
        kernel_data = f.read()
    with open(initrd_path, "rb") as f:
        initrd_data = f.read()

    kernel_sectors = (len(kernel_data) + SECTOR - 1) // SECTOR
    initrd_sectors = (len(initrd_data) + SECTOR - 1) // SECTOR

    print(f"[install] Kernel: {len(kernel_data)} bytes ({kernel_sectors} sectors) at LBA {IMG_KERNEL_LBA}")
    print(f"[install] Initrd: {len(initrd_data)} bytes ({initrd_sectors} sectors) at LBA {IMG_INITRD_LBA}")

    # Sanity checks
    if IMG_KERNEL_LBA + kernel_sectors > IMG_INITRD_LBA:
        print(f"[error] Kernel too large! {kernel_sectors} > {IMG_INITRD_LBA - IMG_KERNEL_LBA} sectors")
        sys.exit(1)
    if IMG_INITRD_LBA + initrd_sectors > IMG_ROOT_LBA:
        print(f"[error] Initrd too large! {initrd_sectors} > {IMG_ROOT_LBA - IMG_INITRD_LBA} sectors")
        sys.exit(1)

    # Create blank image
    img = bytearray(total_size)

    # Copy kernel and initrd at their LBA offsets
    koff = IMG_KERNEL_LBA * SECTOR
    img[koff:koff + len(kernel_data)] = kernel_data
    ioff = IMG_INITRD_LBA * SECTOR
    img[ioff:ioff + len(initrd_data)] = initrd_data

    # ── GPT ──────────────────────────────────────────────────────────
    last_usable_lba = total_sectors - 1 - 1 - GPT_ENTRIES_SECTORS
    first_usable_lba = 2 + GPT_ENTRIES_SECTORS  # LBA 34

    # Deterministic GUIDs
    disk_guid = bytearray(hashlib.md5(b"fornax-mars-disk").digest())
    disk_guid[6] = (disk_guid[6] & 0x0F) | 0x40
    disk_guid[8] = (disk_guid[8] & 0x3F) | 0x80
    part_guid = bytearray(hashlib.md5(b"fornax-mars-root").digest())
    part_guid[6] = (part_guid[6] & 0x0F) | 0x40
    part_guid[8] = (part_guid[8] & 0x3F) | 0x80

    # Partition entry array (32 sectors = 16384 bytes, 128 entries × 128 bytes)
    entries = bytearray(GPT_ENTRIES_SECTORS * SECTOR)
    entries[0:16] = LINUX_FS_GUID
    entries[16:32] = part_guid
    struct.pack_into("<Q", entries, 32, IMG_ROOT_LBA)
    struct.pack_into("<Q", entries, 40, last_usable_lba)
    struct.pack_into("<Q", entries, 48, 0)  # attributes
    for i, c in enumerate("Fornax Root"):
        entries[56 + i * 2] = ord(c)

    entries_crc = binascii.crc32(entries) & 0xFFFFFFFF

    # Primary GPT header at LBA 1
    hdr = bytearray(SECTOR)
    hdr[0:8] = b"EFI PART"
    struct.pack_into("<I", hdr, 8, 0x00010000)
    struct.pack_into("<I", hdr, 12, 92)
    struct.pack_into("<Q", hdr, 24, 1)
    struct.pack_into("<Q", hdr, 32, total_sectors - 1)
    struct.pack_into("<Q", hdr, 40, first_usable_lba)
    struct.pack_into("<Q", hdr, 48, last_usable_lba)
    hdr[56:72] = disk_guid
    struct.pack_into("<Q", hdr, 72, 2)
    struct.pack_into("<I", hdr, 80, GPT_ENTRY_COUNT)
    struct.pack_into("<I", hdr, 84, GPT_ENTRY_SIZE)
    struct.pack_into("<I", hdr, 88, entries_crc)
    struct.pack_into("<I", hdr, 16, 0)
    hdr_crc = binascii.crc32(bytes(hdr[:92])) & 0xFFFFFFFF
    struct.pack_into("<I", hdr, 16, hdr_crc)

    # Backup GPT header at last LBA
    backup_hdr = bytearray(hdr)
    struct.pack_into("<Q", backup_hdr, 24, total_sectors - 1)
    struct.pack_into("<Q", backup_hdr, 32, 1)
    struct.pack_into("<Q", backup_hdr, 72, total_sectors - 1 - GPT_ENTRIES_SECTORS)
    struct.pack_into("<I", backup_hdr, 16, 0)
    backup_crc = binascii.crc32(bytes(backup_hdr[:92])) & 0xFFFFFFFF
    struct.pack_into("<I", backup_hdr, 16, backup_crc)

    # Protective MBR at LBA 0
    img[450] = 0xEE
    img[451] = 0xFF
    img[452] = 0xFF
    img[453] = 0xFF
    struct.pack_into("<I", img, 454, 1)
    struct.pack_into("<I", img, 458, min(total_sectors - 1, 0xFFFFFFFF))
    img[510] = 0x55
    img[511] = 0xAA

    # Write GPT structures into image
    img[SECTOR:2 * SECTOR] = hdr
    img[2 * SECTOR:2 * SECTOR + len(entries)] = entries
    bk_lba = total_sectors - 1 - GPT_ENTRIES_SECTORS
    img[bk_lba * SECTOR:bk_lba * SECTOR + len(entries)] = entries
    img[(total_sectors - 1) * SECTOR:total_sectors * SECTOR] = backup_hdr

    # Write image file (mkfxfs needs it on disk)
    img_path = os.path.join(PROJECT_DIR, "zig-out", "fornax-mars.img")
    with open(img_path, "wb") as f:
        f.write(img)

    print(f"[install] GPT: 'Fornax Root' at LBA {IMG_ROOT_LBA}-{last_usable_lba}"
          f" ({(last_usable_lba - IMG_ROOT_LBA + 1) * SECTOR // (1024*1024)} MiB)")

    # Format fxfs partition with mkfxfs --populate
    root_offset = IMG_ROOT_LBA * SECTOR
    root_size = (last_usable_lba - IMG_ROOT_LBA + 1) * SECTOR
    result = subprocess.run([
        mkfxfs_path, img_path,
        "--offset", str(root_offset),
        "--size", str(root_size),
        "--populate", rootfs_dir,
    ])
    if result.returncode != 0:
        print("[error] mkfxfs failed")
        sys.exit(1)

    return img_path, total_sectors, kernel_sectors, initrd_sectors


# ── Main ────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Build, TFTP-serve, and boot Fornax on Milk-V Mars")
    parser.add_argument("-p", "--port", default="/dev/ttyUSB0",
                        help="Serial port (default: /dev/ttyUSB0, case-sensitive)")
    parser.add_argument("-b", "--baud", type=int, default=BAUD_RATE,
                        help="Baud rate (default: 115200)")
    parser.add_argument("--ip", default=None,
                        help="Host IP for TFTP (auto-detected if omitted)")
    parser.add_argument("--tftp-port", type=int, default=69,
                        help="TFTP port (default: 69, falls back to 6969)")
    parser.add_argument("--kernel", default=KERNEL_PATH,
                        help="Kernel binary path")
    parser.add_argument("--addr", default=KERNEL_ADDR,
                        help="U-Boot load address (default: 0x40200000)")
    parser.add_argument("--mars-ip", default=None,
                        help="Force Mars board IP (overrides DHCP)")
    parser.add_argument("--gateway", default=None,
                        help="Gateway IP (needed if host and Mars on different subnets)")
    parser.add_argument("--no-build", action="store_true",
                        help="Skip build step")
    parser.add_argument("--no-tftp", action="store_true",
                        help="Skip TFTP (use SD card or pre-loaded kernel)")
    parser.add_argument("--sd", action="store_true",
                        help="Boot from SD card instead of TFTP")
    parser.add_argument("--install", action="store_true",
                        help="Build & flash complete Fornax SD card image")
    parser.add_argument("--monitor", action="store_true",
                        help="Just connect to serial (no boot sequence)")
    parser.add_argument("--log", default=None, metavar="FILE",
                        help="Log all serial output to file")
    args = parser.parse_args()

    # Always log to boot.log (overwritten each install/restart); --log adds a second file
    boot_log_path = os.path.join(PROJECT_DIR, "boot.log")
    boot_log = open(boot_log_path, "wb")
    extra_log = open(args.log, "wb") if args.log else None

    class MultiLog:
        """Write to boot.log (always) + optional extra log file."""
        def write(self, data):
            boot_log.write(data)
            boot_log.flush()
            if extra_log:
                extra_log.write(data)
                extra_log.flush()
        def flush(self):
            boot_log.flush()
            if extra_log:
                extra_log.flush()
        def close(self):
            boot_log.close()
            if extra_log:
                extra_log.close()
        def reopen(self):
            """Truncate boot.log for a fresh restart cycle."""
            nonlocal boot_log
            boot_log.close()
            boot_log = open(boot_log_path, "wb")

    logfile = MultiLog()
    host_ip = args.ip or detect_host_ip()

    # If --mars-ip not given, derive one on the same /24 as host
    if not args.mars_ip and not args.sd and not args.monitor:
        prefix = host_ip.rsplit(".", 1)[0]
        args.mars_ip = f"{prefix}.230"
        print(f"[net] Auto: mars-ip={args.mars_ip} serverip={host_ip}")

    # ── Build ───────────────────────────────────────────────────────
    if not args.no_build and not args.monitor:
        print(f"[build] zig build riscv64 -Dboard=milkv_mars")
        result = subprocess.run(
            ["zig", "build", "riscv64", "-Dboard=milkv_mars"],
            cwd=PROJECT_DIR)
        if result.returncode != 0:
            print("[build] FAILED")
            sys.exit(1)
        print(f"[build] OK: {args.kernel}")

    if not os.path.exists(args.kernel) and not args.monitor:
        print(f"[error] Kernel not found: {args.kernel}")
        sys.exit(1)

    # ── Convert ELF to raw binary (U-Boot go doesn't parse ELF) ───
    kernel_bin = args.kernel + ".bin"
    if not args.monitor:
        result = subprocess.run(
            ["llvm-objcopy", "-O", "binary", args.kernel, kernel_bin])
        if result.returncode != 0:
            print("[error] llvm-objcopy failed — is it installed?")
            sys.exit(1)
        elf_size = os.path.getsize(args.kernel)
        bin_size = os.path.getsize(kernel_bin)
        print(f"[objcopy] {os.path.basename(args.kernel)}: ELF {elf_size} -> bin {bin_size}")

    # ── Install mode ───────────────────────────────────────────────
    if args.install:
        ser = None
        tftp = None

        def do_install(ser_in):
            """Build image, TFTP to Mars, write to SD card, boot.

            Returns (ser, tftp) for reuse on restart.
            """
            nonlocal args, host_ip, logfile, kernel_bin

            # Build mkfxfs host tool
            print("[build] zig build mkfxfs")
            result = subprocess.run(["zig", "build", "mkfxfs"], cwd=PROJECT_DIR)
            if result.returncode != 0:
                print("[error] mkfxfs build failed")
                sys.exit(1)

            # Rebuild kernel + userspace (picks up code changes)
            print(f"[build] zig build riscv64 -Dboard=milkv_mars")
            result = subprocess.run(
                ["zig", "build", "riscv64", "-Dboard=milkv_mars"],
                cwd=PROJECT_DIR)
            if result.returncode != 0:
                print("[build] FAILED")
                sys.exit(1)

            # Re-convert ELF to raw binary (kernel may have changed)
            subprocess.run(
                ["llvm-objcopy", "-O", "binary", args.kernel, kernel_bin],
                check=True)

            # Build SD card image
            mkfxfs_bin = os.path.join(PROJECT_DIR, "zig-out", "bin", "mkfxfs")
            initrd_path = os.path.join(PROJECT_DIR, "zig-out", "esp-riscv64", "INITRD")
            rootfs_dir = os.path.join(PROJECT_DIR, "zig-out", "rootfs-riscv64")

            for p, desc in [(kernel_bin, "kernel"), (initrd_path, "INITRD"),
                             (rootfs_dir, "rootfs"), (mkfxfs_bin, "mkfxfs")]:
                if not os.path.exists(p):
                    print(f"[error] {desc} not found: {p}")
                    sys.exit(1)

            img_path, total_sectors, kern_sectors, initrd_sectors = build_sdimg(
                kernel_bin, initrd_path, rootfs_dir, mkfxfs_bin)

            img_size = os.path.getsize(img_path)
            print(f"[install] Image ready: {img_path} ({img_size // (1024*1024)} MiB)")

            # Start/restart TFTP server with new image
            tftp_srv = TftpServer(img_path, port=args.tftp_port)
            tftp_srv.start()
            time.sleep(0.2)

            # Connect serial (reuse if already open)
            ser = ser_in
            if ser is None or not serial_ok(ser):
                try:
                    ser = serial.Serial(args.port, args.baud, timeout=0.1, dsrdtr=True)
                    ser.dtr = False
                except serial.SerialException as e:
                    print(f"[error] Cannot open {args.port}: {e}")
                    tftp_srv.stop()
                    sys.exit(1)
                print(f"[serial] Connected to {args.port} at {args.baud}")

            # Interrupt U-Boot (reset board via bootcmd → Ctrl-C, or just send newlines)
            # Send reset command to get back to U-Boot prompt
            send_cmd(ser, "reset")
            time.sleep(2)
            ok, ser = interrupt_uboot(ser, timeout=60)
            if not ok:
                print("[error] Could not reach U-Boot prompt")
                interactive_console(ser, logfile)
                ser.close()
                tftp_srv.stop()
                sys.exit(1)

            time.sleep(0.2)
            try:
                ser.read(ser.in_waiting)
            except (OSError, serial.SerialException):
                pass

            def uboot_setenv(ser, var, val):
                send_cmd(ser, f"setenv {var} {val}")
                time.sleep(0.3)
                wait_for(ser, [UBOOT_PROMPT, UBOOT_PROMPT_ALT], timeout=5, logfile=logfile)

            # Network setup
            if args.mars_ip:
                uboot_setenv(ser, "ipaddr", args.mars_ip)
            uboot_setenv(ser, "serverip", host_ip)
            if args.gateway:
                uboot_setenv(ser, "gatewayip", args.gateway)
            if tftp_srv.port != 69:
                uboot_setenv(ser, "tftpserverport", str(tftp_srv.port))

            # Ping to prime ARP
            send_cmd(ser, f"ping {host_ip}")
            wait_for(ser, [b"is alive", b"not alive",
                           UBOOT_PROMPT, UBOOT_PROMPT_ALT], timeout=30, logfile=logfile)

            # TFTP the SD image
            send_cmd(ser, f"tftpboot {INSTALL_ADDR} fornax-mars.img")
            print(f"[install] TFTP: {img_size // (1024*1024)} MiB image...")
            idx, _ = wait_for(ser,
                [b"Bytes transferred", b"ARP Retry count exceeded",
                 b"TFTP error", b"T T T T T"],
                timeout=600, logfile=logfile)
            if idx != 0:
                reasons = {1: "ARP failed", 2: "TFTP error", 3: "TFTP timeout", -1: "timeout"}
                print(f"\n[error] TFTP failed: {reasons.get(idx, 'unknown')}")
                interactive_console(ser, logfile)
                ser.close()
                tftp_srv.stop()
                sys.exit(1)
            wait_for(ser, [UBOOT_PROMPT, UBOOT_PROMPT_ALT], timeout=10, logfile=logfile)

            # Select SD card (mmc dev 1 = MMC1 = microSD on Mars)
            send_cmd(ser, "mmc dev 1")
            wait_for(ser, [UBOOT_PROMPT, UBOOT_PROMPT_ALT], timeout=10, logfile=logfile)

            # Write image to SD card
            total_hex = f"0x{total_sectors:X}"
            send_cmd(ser, f"mmc write {INSTALL_ADDR} 0 {total_hex}")
            print(f"[install] Writing {total_sectors} sectors to SD card...")
            idx, _ = wait_for(ser,
                [b"blocks written", UBOOT_PROMPT, UBOOT_PROMPT_ALT],
                timeout=300, logfile=logfile)
            if idx == -1:
                print("[error] mmc write timed out")

            # Set U-Boot bootcmd for standalone SD boot
            kern_hex = f"0x{kern_sectors:X}"
            initrd_hex = f"0x{initrd_sectors:X}"
            bootcmd = (
                f"mmc dev 1; "
                f"mmc read 0x40200000 0x{IMG_KERNEL_LBA:X} {kern_hex}; "
                f"mmc read 0x44000000 0x{IMG_INITRD_LBA:X} {initrd_hex}; "
                f"fdt addr ${{fdtcontroladdr}}; "
                f"fdt move ${{fdtcontroladdr}} 0x46000000; "
                f"go 0x40200000"
            )
            uboot_setenv(ser, "bootcmd", f"'{bootcmd}'")

            send_cmd(ser, "saveenv")
            wait_for(ser, [UBOOT_PROMPT, UBOOT_PROMPT_ALT], timeout=10, logfile=logfile)
            print("[install] U-Boot environment saved.")

            # Boot from the newly installed SD card
            print("[install] Installation complete — booting from SD card...")
            send_cmd(ser, "run bootcmd")

            return ser, tftp_srv

        # Initial install + restart loop
        while True:
            try:
                if tftp:
                    tftp.stop()
                ser, tftp = do_install(ser)
                time.sleep(0.5)
                interactive_console(ser, logfile, reconnect=True)
                break  # Normal exit (Ctrl-D / Ctrl-])
            except RestartRequested:
                print("\n[restart] Ctrl-R — rebuilding and reinstalling...")
                logfile.reopen()  # truncate boot.log for fresh cycle
                continue

        ser.close()
        if tftp:
            tftp.stop()
        if logfile:
            logfile.close()
        return

    # ── TFTP server ─────────────────────────────────────────────────
    tftp = None
    if not args.no_tftp and not args.sd and not args.monitor:
        tftp = TftpServer(kernel_bin, port=args.tftp_port)
        tftp.start()
        # Give it a moment to bind
        time.sleep(0.2)
        actual_port = tftp.port

    # ── Serial connection ───────────────────────────────────────────
    try:
        ser = serial.Serial(args.port, args.baud, timeout=0.1,
                             dsrdtr=False, rtscts=False)
        ser.dtr = False  # Don't assert DTR — it resets the Mars
        ser.rts = False
    except serial.SerialException as e:
        print(f"[error] Cannot open {args.port}: {e}")
        if tftp:
            tftp.stop()
        sys.exit(1)

    print(f"[serial] Connected to {args.port} at {args.baud}")

    if args.monitor:
        interactive_console(ser, logfile, reconnect=True)
        ser.close()
        if logfile:
            logfile.close()
        return

    # ── Interrupt U-Boot ────────────────────────────────────────────
    ok, ser = interrupt_uboot(ser, timeout=60)
    if not ok:
        print("[error] Could not reach U-Boot prompt")
        interactive_console(ser, logfile)
        ser.close()
        if tftp:
            tftp.stop()
        if logfile:
            logfile.close()
        sys.exit(1)

    # Small delay for U-Boot to settle
    time.sleep(0.2)
    try:
        ser.read(ser.in_waiting)  # drain
    except (OSError, serial.SerialException):
        pass

    # ── Send boot commands ──────────────────────────────────────────
    load_ok = False

    if args.sd:
        # SD card boot
        send_cmd(ser, f"fatload mmc 1:1 {args.addr} fornax-riscv64.bin")
        idx, buf = wait_for(ser, [b"bytes read", b"** Unable", UBOOT_PROMPT, UBOOT_PROMPT_ALT], timeout=30, logfile=logfile)
        load_ok = (idx == 0)
        if not load_ok:
            print("[error] SD card load failed")
    else:
        # TFTP boot — set Mars IP on same subnet as host
        def uboot_setenv(ser, var, val):
            send_cmd(ser, f"setenv {var} {val}")
            time.sleep(0.3)
            wait_for(ser, [UBOOT_PROMPT, UBOOT_PROMPT_ALT], timeout=5, logfile=logfile)

        if args.mars_ip:
            uboot_setenv(ser, "ipaddr", args.mars_ip)
        uboot_setenv(ser, "serverip", host_ip)
        if args.gateway:
            uboot_setenv(ser, "gatewayip", args.gateway)

        if tftp and tftp.port != 69:
            uboot_setenv(ser, "tftpserverport", str(tftp.port))

        # Ping host first to prime ARP cache and confirm link is up.
        # tftpboot triggers PHY re-negotiation; without a warm ARP entry
        # the first ARP request can be lost during link-up.
        send_cmd(ser, f"ping {host_ip}")
        idx, _ = wait_for(ser, [b"is alive", b"not alive",
                                 UBOOT_PROMPT, UBOOT_PROMPT_ALT], timeout=30, logfile=logfile)
        if idx != 0:
            print("[error] Cannot ping host — check cable/switch")
            # Fall through to TFTP anyway in case ping is unreliable

        send_cmd(ser, f"tftpboot {args.addr} fornax-riscv64.bin")
        print(f"[boot] TFTP: {args.mars_ip} -> {host_ip}...")
        idx, buf = wait_for(ser,
            [b"Bytes transferred", b"ARP Retry count exceeded",
             b"TFTP error", b"T T T T T", UBOOT_PROMPT, UBOOT_PROMPT_ALT],
            timeout=120, logfile=logfile)

        if idx == 0:
            load_ok = True
            # Wait for U-Boot prompt after transfer message
            wait_for(ser, [UBOOT_PROMPT, UBOOT_PROMPT_ALT], timeout=10, logfile=logfile)
        else:
            reasons = {1: "ARP failed (subnet mismatch?)", 2: "TFTP error",
                       3: "TFTP timeout", -1: "timeout"}
            print(f"\n[error] TFTP failed: {reasons.get(idx, 'unknown')}")
            print("[hint] Check: host and Mars on same subnet? Firewall blocking UDP 69?")

    if not load_ok:
        print("[boot] Skipping jump — dropping to serial console")
        interactive_console(ser, logfile)
        ser.close()
        if tftp:
            tftp.stop()
        if logfile:
            logfile.close()
        return

    # Copy U-Boot's FDT to a known address so the kernel can find it.
    # U-Boot's `go` command passes argc/argv in a0/a1, NOT hartid/DTB,
    # so the kernel uses fdt_fallback_addr (0x46000000) as a backup.
    print("[boot] Copying FDT to 0x46000000...")
    send_cmd(ser, "fdt addr $fdtcontroladdr")
    wait_for(ser, [UBOOT_PROMPT, UBOOT_PROMPT_ALT], timeout=5, logfile=logfile)
    send_cmd(ser, "fdt move $fdtcontroladdr 0x46000000")
    wait_for(ser, [UBOOT_PROMPT, UBOOT_PROMPT_ALT], timeout=5, logfile=logfile)

    # Jump to kernel
    send_cmd(ser, f"go {args.addr}")
    print("[boot] Jumping to kernel...")

    # ── Interactive console (kernel output + user input) ────────────
    time.sleep(0.5)
    interactive_console(ser, logfile, reconnect=True)

    # ── Cleanup ─────────────────────────────────────────────────────
    ser.close()
    if tftp:
        tftp.stop()
    if logfile:
        logfile.close()


if __name__ == "__main__":
    main()
