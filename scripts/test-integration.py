#!/usr/bin/env python3
"""Integration test harness for Fornax OS.

Boots QEMU headlessly with serial console, logs in, runs commands, and
verifies output. No external dependencies — stdlib only.

Usage:
    python3 scripts/test-integration.py
    make test
"""

import gzip
import hashlib
import http.server
import io
import json
import os
import re
import select
import signal
import subprocess
import sys
import tarfile
import tempfile
import threading
import time

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ANSI colors for output
GREEN = "\033[32m"
RED = "\033[31m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
RESET = "\033[0m"
BOLD = "\033[1m"


def log(tag, msg, color=CYAN):
    print(f"{color}[{tag}]{RESET} {msg}", file=sys.stderr, flush=True)


def log_pass(name):
    print(f"{GREEN}[TEST]{RESET} {name}... {GREEN}PASS{RESET}", file=sys.stderr, flush=True)


def log_fail(name, reason):
    print(f"{RED}[TEST]{RESET} {name}... {RED}FAIL{RESET}: {reason}", file=sys.stderr, flush=True)


# ── OVMF firmware discovery ──────────────────────────────────────────

OVMF_CANDIDATES = [
    "/usr/share/edk2/x64/OVMF_CODE.4m.fd",
    "/usr/share/edk2/x64/OVMF.4m.fd",
    "/usr/share/edk2-ovmf/x64/OVMF_CODE.fd",
    "/usr/share/OVMF/OVMF_CODE.fd",
    "/usr/share/edk2/ovmf/OVMF_CODE.fd",
    "/usr/share/qemu/OVMF.fd",
    # macOS
    "/opt/homebrew/share/qemu/edk2-x86_64-code.fd",
    "/opt/homebrew/share/OVMF/OVMF_CODE.fd",
    "/usr/local/share/qemu/edk2-x86_64-code.fd",
    "/usr/local/share/OVMF/OVMF_CODE.fd",
]


def find_ovmf():
    for path in OVMF_CANDIDATES:
        if os.path.isfile(path):
            return path
    return None


# ── QemuDriver ───────────────────────────────────────────────────────

class QemuDriver:
    def __init__(self, ovmf, esp_dir, disk_img):
        self.ovmf = ovmf
        self.esp_dir = esp_dir
        self.disk_img = disk_img
        self.proc = None
        self.buf = b""
        self.full_log = b""

    def start(self):
        # Try KVM first (hardware virt), fall back to TCG single-threaded.
        # TCG multi-threaded can starve the QEMU event loop during
        # tight poll loops in the guest, causing virtio-blk timeouts.
        accel = "kvm" if os.path.exists("/dev/kvm") else "tcg,thread=single"
        cmd = [
            "qemu-system-x86_64",
            "-accel", accel,
            "-cpu", "max",
            "-drive", f"if=pflash,format=raw,readonly=on,file={self.ovmf}",
            "-drive", f"format=raw,file=fat:rw:{self.esp_dir}",
            "-m", "1G",
            "-serial", "stdio",
            "-display", "none",
            "-no-reboot",
            "-device", "virtio-net-pci,netdev=net0",
            "-netdev", "user,id=net0",
            "-device", "virtio-keyboard-pci",
            "-device", "nec-usb-xhci,id=xhci",
            "-device", "usb-kbd,bus=xhci.0",
            "-device", "usb-mouse,bus=xhci.0",
            "-drive", f"file={self.disk_img},format=raw,if=none,id=blk0,cache=writeback",
            "-device", "virtio-blk-pci,drive=blk0",
        ]
        self.proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        # Set stdout to non-blocking
        import fcntl
        fd = self.proc.stdout.fileno()
        flags = fcntl.fcntl(fd, fcntl.F_GETFL)
        fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)

    def _read_available(self):
        """Read all currently available data from stdout."""
        fd = self.proc.stdout.fileno()
        data = b""
        while True:
            ready, _, _ = select.select([fd], [], [], 0)
            if not ready:
                break
            try:
                chunk = os.read(fd, 4096)
                if not chunk:
                    break
                data += chunk
            except BlockingIOError:
                break
        return data

    def expect(self, pattern, timeout=30):
        """Wait for regex pattern to match in accumulated output.

        Returns the match object. Raises TimeoutError if not found within
        timeout seconds.
        """
        deadline = time.monotonic() + timeout
        compiled = re.compile(pattern.encode() if isinstance(pattern, str) else pattern)

        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                # Dump recent buffer for debugging
                recent = self.buf[-500:] if len(self.buf) > 500 else self.buf
                raise TimeoutError(
                    f"Timed out waiting for {pattern!r}\n"
                    f"Last output:\n{recent.decode(errors='replace')}"
                )

            fd = self.proc.stdout.fileno()
            ready, _, _ = select.select([fd], [], [], min(remaining, 0.5))

            if ready:
                try:
                    chunk = os.read(fd, 4096)
                    if chunk:
                        self.buf += chunk
                        self.full_log += chunk
                        # Print to stderr for live monitoring
                        sys.stderr.buffer.write(chunk)
                        sys.stderr.buffer.flush()
                except BlockingIOError:
                    pass

            # Check for match
            m = compiled.search(self.buf)
            if m:
                # Trim buffer up to end of match to avoid re-matching
                self.buf = self.buf[m.end():]
                return m

            # Check if QEMU died
            if self.proc.poll() is not None:
                raise RuntimeError(
                    f"QEMU exited unexpectedly (code {self.proc.returncode})"
                )

    _cmd_seq = 0

    def send_line(self, text):
        """Send text + carriage return to serial console."""
        self.proc.stdin.write((text + "\r").encode())
        self.proc.stdin.flush()
        # Small delay so the OS has time to echo
        time.sleep(0.1)

    def send_cmd(self, cmd, timeout=15):
        """Send a shell command and wait for completion using a unique marker.

        Appends '; echo __Dn__' to the command and waits for the marker
        to appear on its own line in the output. This avoids false-positive
        matches against kernel debug messages or shell echo artifacts.
        """
        QemuDriver._cmd_seq += 1
        marker = f"__D{QemuDriver._cmd_seq}__"
        self.send_line(f"{cmd}; echo {marker}")
        self.expect(rf"\n{marker}", timeout=timeout)

    def stop(self):
        """Stop QEMU gracefully, then force-kill if needed."""
        if self.proc is None:
            return
        try:
            self.proc.send_signal(signal.SIGTERM)
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self.proc = None

    def wait_exit(self, timeout=10):
        """Wait for QEMU to exit on its own."""
        try:
            self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self.proc = None


# ── Package builder ──────────────────────────────────────────────────

def build_xxd_package(xxd_binary_path, pkg_dir):
    """Create xxd-1.0.0-1.tar.gz with .PKGINFO and bin/xxd."""
    pkg_name = "xxd"
    pkg_ver = "1.0.0-1"
    tarball_name = f"{pkg_name}-{pkg_ver}.tar.gz"
    tarball_path = os.path.join(pkg_dir, tarball_name)

    pkginfo = json.dumps({
        "name": pkg_name,
        "version": pkg_ver,
        "description": "Hex dump and reverse hex dump utility",
        "depends": [],
    }).encode()

    with tarfile.open(tarball_path, "w:gz", format=tarfile.USTAR_FORMAT) as tf:
        # .PKGINFO
        info = tarfile.TarInfo(name=".PKGINFO")
        info.size = len(pkginfo)
        info.type = tarfile.REGTYPE
        tf.addfile(info, io.BytesIO(pkginfo))

        # bin/ directory
        dir_info = tarfile.TarInfo(name="bin/")
        dir_info.type = tarfile.DIRTYPE
        dir_info.mode = 0o755
        tf.addfile(dir_info)

        # bin/xxd
        tf.add(xxd_binary_path, arcname="bin/xxd")

    # Compute SHA-256
    sha256 = hashlib.sha256()
    with open(tarball_path, "rb") as f:
        while True:
            chunk = f.read(8192)
            if not chunk:
                break
            sha256.update(chunk)

    return tarball_name, sha256.hexdigest()


def generate_repo_json(pkg_dir, tarball_name, sha256_hex):
    """Generate repo.json for the test package repository."""
    repo = {
        "packages": {
            "xxd": {
                "version": "1.0.0-1",
                "description": "Hex dump and reverse hex dump utility",
                "url": f"/{tarball_name}",
                "sha256": sha256_hex,
                "depends": [],
            }
        }
    }
    repo_path = os.path.join(pkg_dir, "repo.json")
    with open(repo_path, "w") as f:
        json.dump(repo, f, indent=2)
    return repo_path


# ── HTTP server ──────────────────────────────────────────────────────

class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):
        log("HTTP", fmt % args, YELLOW)


def start_http_server(directory, port=8000):
    """Start a daemon HTTP server serving files from directory."""
    handler = lambda *a, **kw: QuietHandler(*a, directory=directory, **kw)
    http.server.HTTPServer.allow_reuse_address = True
    server = http.server.HTTPServer(("0.0.0.0", port), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


# ── Disk image builder ───────────────────────────────────────────────

def create_test_disk(tmpdir, rootfs_dir, disk_size_mb=256):
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


# ── Tests ────────────────────────────────────────────────────────────

def test_boot_login(qemu):
    """Wait for login prompt, log in as root."""
    try:
        qemu.expect(r"fornax login:", timeout=90)
        qemu.send_line("root")
        qemu.expect(r"root@fornax", timeout=10)
        log_pass("test_boot_login")
        return True
    except (TimeoutError, RuntimeError) as e:
        log_fail("test_boot_login", str(e))
        return False


def test_basic_commands(qemu):
    """Verify basic command execution works (fxfs reads)."""
    try:
        # Test a builtin — send_cmd waits for reliable completion marker
        qemu.send_cmd("echo basic_test_XQ7")
        # basic_test_XQ7 appears in the marker-echo output; just verify it ran

        # Test an external command that reads from fxfs
        qemu.send_cmd("echo testdata_Z9 > /tmp/basic.txt")
        qemu.send_line("cat /tmp/basic.txt; echo __CAT_BASIC__")
        qemu.expect(r"testdata_Z9", timeout=30)
        qemu.expect(r"__CAT_BASIC__", timeout=5)

        log_pass("test_basic_commands")
        return True
    except (TimeoutError, RuntimeError) as e:
        log_fail("test_basic_commands", str(e))
        return False


def test_time_subsystem(qemu):
    """Verify wall-clock time, date command, uptime, and cron daemon."""
    try:
        # 1. /dev/time format: "<epoch> <uptime>\n"
        #    Epoch should be >1700000000 (2023+) if RTC works.
        qemu.send_line("cat /dev/time; echo __TIME_DONE__")
        m = qemu.expect(r"(\d+) (\d+)", timeout=10)
        epoch = int(m.group(1))
        uptime = int(m.group(2))
        qemu.expect(r"__TIME_DONE__", timeout=5)

        if epoch < 1700000000:
            log_fail("test_time_subsystem", f"epoch too low: {epoch}")
            return False
        if uptime < 1:
            log_fail("test_time_subsystem", f"uptime too low: {uptime}")
            return False

        # 2. date command: should output day-of-week + month + year
        qemu.send_line("date; echo __DATE_DONE__")
        m = qemu.expect(r"(Sun|Mon|Tue|Wed|Thu|Fri|Sat)\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)", timeout=10)
        qemu.expect(r"__DATE_DONE__", timeout=5)

        # 3. date +%s: should match /dev/time epoch (within a few seconds)
        qemu.send_line("date +%s; echo __EPOCH_DONE__")
        m = qemu.expect(r"(\d+)", timeout=10)
        cmd_epoch = int(m.group(1))
        qemu.expect(r"__EPOCH_DONE__", timeout=5)
        if abs(cmd_epoch - epoch) > 30:
            log_fail("test_time_subsystem", f"date +%s ({cmd_epoch}) too far from /dev/time ({epoch})")
            return False

        # 4. date -I: ISO 8601 format YYYY-MM-DD
        qemu.send_line("date -I; echo __ISO_DONE__")
        qemu.expect(r"\d{4}-\d{2}-\d{2}", timeout=10)
        qemu.expect(r"__ISO_DONE__", timeout=5)

        # 5. uptime command
        qemu.send_line("uptime; echo __UP_DONE__")
        qemu.expect(r"\d+[hm]", timeout=10)
        qemu.expect(r"__UP_DONE__", timeout=5)

        # 6. crontab -l (crond should be running)
        qemu.send_line("crontab -l; echo __CRON_DONE__")
        # Should succeed (either "no jobs" or list of jobs)
        qemu.expect(r"__CRON_DONE__", timeout=10)

        log_pass("test_time_subsystem")
        return True
    except (TimeoutError, RuntimeError) as e:
        log_fail("test_time_subsystem", str(e))
        return False


def test_fay_install_xxd(qemu):
    """Sync repo, install xxd, verify it works."""
    try:
        # Sync package database
        qemu.send_line("fay sync")
        qemu.expect(r"downloaded \d+ bytes", timeout=30)
        qemu.expect(r"root@fornax[#$] ", timeout=10)

        # Install xxd
        qemu.send_line("fay install xxd")
        qemu.expect(r"xxd 1\.0\.0-1 installed", timeout=60)
        qemu.expect(r"root@fornax[#$] ", timeout=10)

        # Test xxd works: write a file, then xxd it
        qemu.send_cmd("echo hello > /tmp/xxd_test.txt")
        qemu.send_line("xxd /tmp/xxd_test.txt; echo __XXD_DONE__")
        qemu.expect(r"00000000", timeout=30)
        qemu.expect(r"__XXD_DONE__", timeout=5)

        log_pass("test_fay_install_xxd")
        return True
    except (TimeoutError, RuntimeError) as e:
        log_fail("test_fay_install_xxd", str(e))
        return False


def test_filesystem(qemu):
    """Test filesystem operations: write/read files of various sizes."""
    try:
        # 1. mkdir -p for test directory
        qemu.send_cmd("mkdir -p /tmp/fstest")

        # 2. Small file: write and read back via cat
        qemu.send_cmd("echo 'fs_hello_world' > /tmp/fstest/small.txt")
        qemu.send_line("cat /tmp/fstest/small.txt; echo __CAT1__")
        qemu.expect(r"fs_hello_world", timeout=10)
        qemu.expect(r"__CAT1__", timeout=5)

        # 3. Use dd to create a 64KB file from /dev/zero, check size with wc -c
        qemu.send_cmd("dd if=/dev/zero of=/tmp/fstest/medium.bin bs=4096 count=16")
        qemu.send_line("wc -c /tmp/fstest/medium.bin; echo __WC1__")
        qemu.expect(r"65536", timeout=10)
        qemu.expect(r"__WC1__", timeout=5)

        # 4. Larger file: 256KB
        qemu.send_cmd("dd if=/dev/zero of=/tmp/fstest/large.bin bs=4096 count=64", timeout=20)
        qemu.send_line("wc -c /tmp/fstest/large.bin; echo __WC2__")
        qemu.expect(r"262144", timeout=10)
        qemu.expect(r"__WC2__", timeout=5)

        # 5. Many small files in a directory
        qemu.send_cmd("mkdir /tmp/fstest/many")
        for i in range(5):
            qemu.send_cmd(f"echo content_{i} > /tmp/fstest/many/f{i}.txt")

        # Verify count with ls | wc -l
        qemu.send_line("ls /tmp/fstest/many | wc -l; echo __WCL__")
        qemu.expect(r"5", timeout=10)
        qemu.expect(r"__WCL__", timeout=5)

        # 6. Verify one of them reads back correctly
        qemu.send_line("cat /tmp/fstest/many/f3.txt; echo __CAT2__")
        qemu.expect(r"content_3", timeout=10)
        qemu.expect(r"__CAT2__", timeout=5)

        # 7. Rename test
        qemu.send_cmd("mv /tmp/fstest/small.txt /tmp/fstest/renamed.txt")
        qemu.send_line("cat /tmp/fstest/renamed.txt; echo __CAT3__")
        qemu.expect(r"fs_hello_world", timeout=10)
        qemu.expect(r"__CAT3__", timeout=5)

        # 8. Truncate test
        qemu.send_cmd("truncate /tmp/fstest/medium.bin 1024")
        qemu.send_line("wc -c /tmp/fstest/medium.bin; echo __WC3__")
        qemu.expect(r"\b1024\b", timeout=10)
        qemu.expect(r"__WC3__", timeout=5)

        # 9. Remove files
        qemu.send_cmd("rm -f /tmp/fstest/renamed.txt")
        qemu.send_cmd("rm -f /tmp/fstest/medium.bin")
        qemu.send_cmd("rm -f /tmp/fstest/large.bin")

        log_pass("test_filesystem")
        return True
    except (TimeoutError, RuntimeError) as e:
        log_fail("test_filesystem", str(e))
        return False


def test_shutdown(qemu):
    """Send shutdown command and wait for QEMU to exit."""
    try:
        # Wait a moment for any pending I/O to settle
        time.sleep(0.5)
        qemu.send_line("shutdown")
        qemu.wait_exit(timeout=15)
        log_pass("test_shutdown")
        return True
    except (TimeoutError, RuntimeError, subprocess.TimeoutExpired) as e:
        log_fail("test_shutdown", str(e))
        return False


# ── Main ─────────────────────────────────────────────────────────────

def main():
    passed = 0
    failed = 0
    qemu = None

    try:
        # 1. Find OVMF
        ovmf = find_ovmf()
        if not ovmf:
            print(f"{RED}Error: Could not find OVMF firmware.{RESET}", file=sys.stderr)
            print("Install with: pacman -S edk2-ovmf (Arch) / apt install ovmf (Debian)", file=sys.stderr)
            return 1
        log("SETUP", f"OVMF: {ovmf}")

        # 2. Check port 8000 availability
        import socket
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind(("0.0.0.0", 8000))
            sock.close()
        except OSError:
            print(f"{RED}Error: Port 8000 is already in use.{RESET}", file=sys.stderr)
            print("Stop the process using port 8000 and try again.", file=sys.stderr)
            return 1

        # 3. Build Fornax with POSIX + test packages
        log("BUILD", "Building Fornax with POSIX + test packages...")
        result = subprocess.run(
            ["zig", "build", "x86_64", "-Dposix=true", "-Dtest-packages=true"],
            cwd=PROJECT_DIR,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            print(f"{RED}Build failed:{RESET}\n{result.stderr}", file=sys.stderr)
            return 1
        log("BUILD", "OK")

        # Also build host tools
        log("BUILD", "Building mkgpt + mkfxfs...")
        result = subprocess.run(
            ["zig", "build", "mkgpt", "mkfxfs"],
            cwd=PROJECT_DIR,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            print(f"{RED}Host tools build failed:{RESET}\n{result.stderr}", file=sys.stderr)
            return 1

        # 4. Check xxd binary exists
        xxd_path = os.path.join(PROJECT_DIR, "zig-out", "test-packages", "xxd")
        if not os.path.isfile(xxd_path):
            print(f"{RED}Error: xxd binary not found at {xxd_path}{RESET}", file=sys.stderr)
            return 1

        with tempfile.TemporaryDirectory(prefix="fornax-test-") as tmpdir:
            # 5. Create package tarball
            log("PACKAGE", "Creating xxd-1.0.0-1.tar.gz...")
            pkg_dir = os.path.join(tmpdir, "packages")
            os.makedirs(pkg_dir)
            tarball_name, sha256_hex = build_xxd_package(xxd_path, pkg_dir)
            log("PACKAGE", f"OK (sha256: {sha256_hex[:16]}...)")

            # 6. Generate repo.json
            generate_repo_json(pkg_dir, tarball_name, sha256_hex)
            log("PACKAGE", "repo.json generated")

            # 7. Start HTTP server
            http_server = start_http_server(pkg_dir, port=8000)
            log("HTTP", "Serving test packages on :8000")

            # 8. Prepare rootfs and create test disk
            rootfs_dir = os.path.join(PROJECT_DIR, "zig-out", "rootfs")
            prepare_rootfs(rootfs_dir)
            disk_img = create_test_disk(tmpdir, rootfs_dir)
            log("DISK", "OK")

            # 9. Start QEMU
            esp_dir = os.path.join(PROJECT_DIR, "zig-out", "esp")
            qemu = QemuDriver(ovmf, esp_dir, disk_img)
            log("QEMU", "Starting Fornax (headless)...")
            qemu.start()

            # 10. Run tests
            if test_boot_login(qemu):
                passed += 1
            else:
                failed += 1

            if failed == 0:
                if test_basic_commands(qemu):
                    passed += 1
                else:
                    failed += 1

            if failed == 0:
                if test_time_subsystem(qemu):
                    passed += 1
                else:
                    failed += 1

            if failed == 0:
                if test_fay_install_xxd(qemu):
                    passed += 1
                else:
                    failed += 1

            if failed == 0:
                if test_filesystem(qemu):
                    passed += 1
                else:
                    failed += 1

            if failed == 0:
                if test_shutdown(qemu):
                    passed += 1
                else:
                    failed += 1

            # Cleanup
            http_server.shutdown()

    except KeyboardInterrupt:
        print(f"\n{YELLOW}Interrupted.{RESET}", file=sys.stderr)
        failed += 1
    except Exception as e:
        print(f"{RED}Unexpected error: {e}{RESET}", file=sys.stderr)
        failed += 1
    finally:
        if qemu:
            qemu.stop()

    # Summary
    print(file=sys.stderr)
    total = passed + failed
    if failed == 0:
        print(f"{GREEN}{BOLD}All {passed} tests passed.{RESET}", file=sys.stderr)
        return 0
    else:
        print(f"{RED}{BOLD}{failed}/{total} tests failed.{RESET}", file=sys.stderr)
        if qemu and qemu.full_log:
            log_path = os.path.join(PROJECT_DIR, "test-serial.log")
            with open(log_path, "wb") as f:
                f.write(qemu.full_log)
            print(f"Full serial log saved to: {log_path}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
