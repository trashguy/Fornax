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
  ./scripts/mars-boot.py --monitor          # just connect to serial (no boot)
"""

import argparse
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
    """Single-file read-only TFTP server. Serves one file, shuts down after."""

    TFTP_RRQ = 1
    TFTP_DATA = 3
    TFTP_ACK = 4
    TFTP_ERROR = 5
    BLOCK_SIZE = 512

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
                data, addr = self.sock.recvfrom(516)
            except socket.timeout:
                continue

            opcode = struct.unpack("!H", data[:2])[0]
            if opcode == self.TFTP_RRQ:
                print(f"[tftp] RRQ from {addr[0]}:{addr[1]}")
                self._handle_rrq(addr)

        self.sock.close()

    def _handle_rrq(self, client_addr):
        """Send file to client in 512-byte blocks."""
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

        total = len(file_data)
        block = 1
        offset = 0

        while True:
            chunk = file_data[offset:offset + self.BLOCK_SIZE]
            pkt = struct.pack("!HH", self.TFTP_DATA, block) + chunk
            retries = 0

            while retries < 5:
                xfer.sendto(pkt, client_addr)
                try:
                    ack, _ = xfer.recvfrom(4)
                    ack_op, ack_blk = struct.unpack("!HH", ack[:4])
                    if ack_op == self.TFTP_ACK and ack_blk == block:
                        break
                except socket.timeout:
                    retries += 1

            if retries >= 5:
                print(f"[tftp] Transfer failed at block {block}")
                break

            offset += self.BLOCK_SIZE
            block += 1

            # Progress
            pct = min(100, offset * 100 // total) if total > 0 else 100
            print(f"\r[tftp] {offset}/{total} bytes ({pct}%)", end="", flush=True)

            if len(chunk) < self.BLOCK_SIZE:
                print(f"\n[tftp] Transfer complete ({total} bytes)")
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
    while time.monotonic() < deadline:
        if not serial_ok(ser):
            ser = serial_reconnect(ser)
            deadline = time.monotonic() + timeout  # reset timeout after reconnect

        try:
            ser.write(b" ")
            ser.flush()
        except (OSError, serial.SerialException):
            continue
        time.sleep(0.1)

        try:
            if not ser.in_waiting:
                continue
            chunk = ser.read(ser.in_waiting)
        except (OSError, serial.SerialException):
            continue

        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()
        # Check for any U-Boot prompt variant
        if (UBOOT_PROMPT in chunk or UBOOT_PROMPT_ALT in chunk or
                b"Hit any key" in chunk or b"autoboot" in chunk):
            # Keep spamming briefly to ensure we caught it
            for _ in range(10):
                try:
                    ser.write(b" ")
                    ser.flush()
                except (OSError, serial.SerialException):
                    break
                time.sleep(0.05)
            # Drain and check for prompt
            time.sleep(0.3)
            try:
                if ser.in_waiting:
                    rest = ser.read(ser.in_waiting)
                    sys.stdout.buffer.write(rest)
                    sys.stdout.buffer.flush()
            except (OSError, serial.SerialException):
                pass
            print("\n[boot] U-Boot prompt detected")
            return True, ser

    print("\n[boot] Timeout waiting for U-Boot")
    return False, ser


def interactive_console(ser, logfile=None, reconnect=False):
    """Pass-through serial console with raw terminal input."""
    print("[console] Interactive serial console (Ctrl-D or Ctrl-] to exit)")

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
    parser.add_argument("--monitor", action="store_true",
                        help="Just connect to serial (no boot sequence)")
    parser.add_argument("--log", default=None, metavar="FILE",
                        help="Log all serial output to file")
    args = parser.parse_args()

    logfile = open(args.log, "wb") if args.log else None
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
        ser = serial.Serial(args.port, args.baud, timeout=0.1, dsrdtr=True)
        ser.dtr = False  # Don't assert DTR — it resets the Mars
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
