"""QemuDriver — boots and interacts with Fornax via QEMU serial console."""
import fcntl
import os
import re
import select
import signal
import subprocess
import sys
import time

from .config import sanitize_serial



class QemuDriver:
    def __init__(self, ovmf, esp_dir, disk_img, smp=1, memory="4G", arch="x86_64",
                 kernel=None, initrd=None, tap_iface=None):
        self.ovmf = ovmf
        self.esp_dir = esp_dir
        self.disk_img = disk_img
        self.smp = smp
        self.memory = memory
        self.arch = arch
        self.kernel = kernel      # riscv64: path to kernel ELF
        self.initrd = initrd      # riscv64: path to initrd
        self.tap_iface = tap_iface  # TAP interface name (required)
        self.host_ip = None        # Set by caller (TapNetwork.host_ip)
        self.proc = None
        self.buf = b""
        self.full_log = b""

    @staticmethod
    def _kvm_available():
        """Check if KVM hardware acceleration is available."""
        try:
            return os.access("/dev/kvm", os.R_OK | os.W_OK)
        except OSError:
            return False

    def start(self):
        if not self.tap_iface:
            raise ValueError("tap_iface is required (SLiRP no longer supported)")
        netdev_arg = f"tap,id=net0,ifname={self.tap_iface},script=no,downscript=no"

        if self.arch == "aarch64":
            cmd = [
                "qemu-system-aarch64",
                "-machine", "virt",
                "-cpu", "cortex-a72",
                "-smp", str(self.smp),
                "-drive", f"if=pflash,format=raw,readonly=on,file={self.ovmf}",
                "-drive", f"format=raw,file=fat:rw:{self.esp_dir}",
                "-device", "ramfb",
                "-m", self.memory,
                "-serial", "stdio",
                "-display", "none",
                "-no-reboot",
                "-no-shutdown",
                "-device", "virtio-net-pci,disable-legacy=off,disable-modern=on,netdev=net0",
                "-netdev", netdev_arg,
                "-drive", f"file={self.disk_img},format=raw,if=none,id=blk0,cache=writeback",
                "-device", "virtio-blk-pci,drive=blk0",
            ]
        elif self.arch == "riscv64":
            cmd = [
                "qemu-system-riscv64",
                "-machine", "virt",
                "-cpu", "rv64",
                "-smp", str(self.smp),
                "-m", self.memory,
                "-bios", "default",
                "-kernel", self.kernel,
                "-device", f"loader,file={self.initrd},addr=0x84000000,force-raw=on",
                "-nographic",
                "-drive", f"file={self.disk_img},format=raw,if=none,id=blk0,cache=writeback",
                "-device", "virtio-blk-pci,drive=blk0",
                "-netdev", netdev_arg,
                "-device", "virtio-net-pci,netdev=net0",
            ]
        else:
            cmd = [
                "qemu-system-x86_64",
                "-smp", str(self.smp),
                "-drive", f"if=pflash,format=raw,readonly=on,file={self.ovmf}",
                "-drive", f"format=raw,file=fat:rw:{self.esp_dir}",
                "-m", self.memory,
                "-serial", "stdio",
                "-display", "none",
                "-no-reboot",
                "-device", "virtio-net-pci,netdev=net0",
                "-netdev", netdev_arg,
                "-device", "virtio-keyboard-pci",
                "-device", "nec-usb-xhci,id=xhci",
                "-device", "usb-kbd,bus=xhci.0",
                "-device", "usb-mouse,bus=xhci.0",
                "-drive", f"file={self.disk_img},format=raw,if=none,id=blk0,cache=writeback",
                "-device", "virtio-blk-pci,drive=blk0",
            ]
        # KVM gives correct SMP semantics but exposes a kernel SMP race that
        # intermittently crashes during boot.  Default TCG multi-threaded is
        # more forgiving (halted core doesn't block others).
        # TCG single-threaded is unusable: cpu.halt() on one vCPU blocks
        # the shared TCG thread, starving all other vCPUs.
        self._accel = "tcg"
        self.proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=open("/tmp/qemu-aarch64-stderr.log", "w") if self.arch == "aarch64" else subprocess.DEVNULL,
        )
        # Set stdout to non-blocking
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
                        # Strip all ANSI so serial can't corrupt scroll region
                        sys.stderr.buffer.write(sanitize_serial(chunk))
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
        """Send text + carriage return to serial console.

        Writes in small chunks with pacing to avoid overrunning the
        emulated 16550 UART's 16-byte receive FIFO.  QEMU's pipe-backed
        chardev delivers all bytes instantly (no baud-rate throttle),
        so we must pace ourselves.
        """
        payload = (text + "\r").encode()
        for byte in payload:
            self.proc.stdin.write(bytes([byte]))
            self.proc.stdin.flush()
            time.sleep(0.002)  # 2 ms per byte — gives UART IRQ time to drain
        # Extra settle time for the OS to echo / process
        time.sleep(0.05)

    def send_cmd(self, cmd, timeout=15):
        """Send a shell command and wait for completion using a unique marker.

        Appends '; echo __Dn__' to the command and waits for the marker
        followed by a newline. On SMP, kernel debug messages from other cores
        may appear on the same line before the marker, so we match the marker
        at end-of-line rather than start-of-line. Shell echo won't false-match
        because the echo includes trailing spaces/backspaces before the newline.
        """
        QemuDriver._cmd_seq += 1
        marker = f"__D{QemuDriver._cmd_seq}__"
        self.send_line(f"{cmd}; echo {marker}")
        self.expect(rf"{marker}\r?\n", timeout=timeout)

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
        except OSError:
            # Process already exited
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
