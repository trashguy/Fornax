#!/usr/bin/env python3
"""Ad-hoc iperf throughput benchmark across architectures.

Boots QEMU with a TAP network interface, starts a host-side TCP sink,
runs iperf client in the guest, and reports throughput.

Requires sudo for TAP interface creation. The guest obtains its IP
via DHCP from a built-in server on the TAP interface.

Usage:
    python tests/run_iperf.py [--arch x86_64|riscv64|aarch64] [--duration 5] [--runs 3] [--port 5201]
    python tests/run_iperf.py --slirp  # Use SLiRP instead of TAP (no sudo)

Not a permanent test — just a diagnostic tool for comparing TCP
throughput across architectures and isolating data delivery issues.
"""
import argparse
import io
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time

# Add project root so we can import the harness
PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, PROJECT_DIR)

from tests.harness.qemu import QemuDriver
from tests.harness.disk import create_test_disk, prepare_rootfs
from tests.harness.config import find_ovmf, find_aavmf, log, RED, GREEN, YELLOW, BOLD, RESET
from tests.harness.tap import TapNetwork


class TcpSink:
    """Host-side TCP sink that accepts one connection and measures throughput."""

    def __init__(self, port, bind_addr="0.0.0.0"):
        self.port = port
        self.bind_addr = bind_addr
        self.srv = None
        self.thread = None
        self.total_bytes = 0
        self.elapsed = 0.0
        self.done = threading.Event()

    def start(self):
        self.srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.srv.settimeout(120)
        # Try requested port first, fall back to nearby ports if in use
        for p in range(self.port, self.port + 100):
            try:
                self.srv.bind((self.bind_addr, p))
                self.port = p
                break
            except OSError:
                continue
        else:
            raise OSError(f"No free port in range {self.port}-{self.port + 99}")
        self.srv.listen(1)
        self.thread = threading.Thread(target=self._accept_loop, daemon=True)
        self.thread.start()

    def _accept_loop(self):
        log_f = open("/tmp/fornax-sink.log", "a")
        log_f.write(f"\n[sink] listening on {self.bind_addr}:{self.port}\n")
        log_f.flush()
        try:
            conn, addr = self.srv.accept()
        except (socket.timeout, OSError) as e:
            log_f.write(f"[sink] accept failed: {e}\n")
            log_f.flush()
            self.done.set()
            return

        log_f.write(f"[sink] accepted from {addr}\n")
        log_f.flush()
        total = 0
        start = time.monotonic()
        try:
            with conn:
                conn.settimeout(30)
                while True:
                    try:
                        data = conn.recv(65536)
                    except socket.timeout:
                        log_f.write(f"[sink] recv timeout, total={total}\n")
                        log_f.flush()
                        break
                    if not data:
                        log_f.write(f"[sink] EOF, total={total}\n")
                        log_f.flush()
                        break
                    total += len(data)
        except Exception as e:
            log_f.write(f"[sink] recv error: {e}, total={total}\n")
            log_f.flush()

        self.elapsed = time.monotonic() - start
        self.total_bytes = total
        log_f.write(f"[sink] done: {total} bytes, {self.elapsed:.2f}s\n")
        log_f.flush()
        log_f.close()
        self.done.set()

    def wait(self, timeout=180):
        self.done.wait(timeout)

    def stop(self):
        if self.srv:
            self.srv.close()

    @property
    def throughput_kbps(self):
        if self.elapsed < 0.001:
            return 0.0
        return self.total_bytes / 1024.0 / self.elapsed

    @property
    def throughput_mbps(self):
        if self.elapsed < 0.001:
            return 0.0
        return self.total_bytes * 8.0 / 1024.0 / 1024.0 / self.elapsed




def build(arch, extra_flags=None):
    """Build Fornax for the given architecture."""
    target = {"aarch64": "aarch64", "riscv64": "riscv64"}.get(arch, "x86_64")
    cmd = ["zig", "build", target]
    if extra_flags:
        cmd.extend(extra_flags)
    log("BUILD", f"Building {target}...")
    result = subprocess.run(cmd, cwd=PROJECT_DIR, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"{RED}Build failed:{RESET}\n{result.stderr}", file=sys.stderr)
        return False

    # Host tools
    result = subprocess.run(
        ["zig", "build", "mkgpt", "mkfxfs"],
        cwd=PROJECT_DIR, capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"{RED}Host tools build failed:{RESET}\n{result.stderr}", file=sys.stderr)
        return False

    log("BUILD", "OK")
    return True


class _DevNull:
    """Dummy stderr replacement that swallows everything.

    QemuDriver writes to sys.stderr.buffer (binary) and the harness
    log helpers write to sys.stderr (text).  This object handles both.
    """
    buffer = property(lambda self: self)  # .buffer returns self

    def write(self, data):
        return len(data) if isinstance(data, (bytes, bytearray)) else len(data)

    def flush(self):
        pass

    def fileno(self):
        return os.open(os.devnull, os.O_WRONLY)

_devnull_singleton = _DevNull()
_real_stderr = sys.stderr


def _mute():
    sys.stderr = _devnull_singleton

def _unmute():
    sys.stderr = _real_stderr


def expect_quiet(qemu, pattern, timeout=30):
    """Like qemu.expect() but suppresses serial echo to stderr."""
    _mute()
    try:
        return qemu.expect(pattern, timeout=timeout)
    finally:
        _unmute()


def send_line_quiet(qemu, text):
    """Send a line without the serial echo."""
    _mute()
    try:
        qemu.send_line(text)
    finally:
        _unmute()


def install_dhcp_config(rootfs_dir):
    """Install a DHCP-mode net.conf into the rootfs."""
    etc_dir = os.path.join(rootfs_dir, "etc")
    os.makedirs(etc_dir, exist_ok=True)
    conf_path = os.path.join(etc_dir, "net.conf")
    with open(conf_path, "w") as f:
        f.write("# DHCP mode for TAP networking\ndhcp\n")


def run_iperf_test(arch, duration, port, serial_log, use_tap=True, runs=3):
    """Boot QEMU, run iperf client, measure throughput."""
    # Find firmware
    if arch == "aarch64":
        fw = find_aavmf()
        if not fw:
            print(f"{RED}AAVMF firmware not found{RESET}", file=sys.stderr)
            return False
    elif arch == "riscv64":
        fw = None
    else:
        fw = find_ovmf()
        if not fw:
            print(f"{RED}OVMF firmware not found{RESET}", file=sys.stderr)
            return False

    with tempfile.TemporaryDirectory(prefix="fornax-iperf-") as tmpdir:
        # Prepare rootfs and disk
        rootfs_suffix = {"aarch64": "-aarch64", "riscv64": "-riscv64"}.get(arch, "")
        rootfs_dir = os.path.join(PROJECT_DIR, "zig-out", f"rootfs{rootfs_suffix}")
        prepare_rootfs(rootfs_dir)

        # For TAP mode, install DHCP config so netd uses DHCP
        if use_tap:
            install_dhcp_config(rootfs_dir)

        disk_img = create_test_disk(tmpdir, rootfs_dir)
        log("DISK", "OK")

        # Determine bind address and target IP for the sink
        if use_tap:
            host_ip = "10.0.2.2"
            guest_target = "10.0.2.2"
        else:
            host_ip = "127.0.0.1"
            guest_target = "10.0.2.2"

        # QEMU kwargs
        extra_kw = {}
        if arch == "riscv64":
            extra_kw["kernel"] = os.path.join(PROJECT_DIR, "zig-out", "esp-riscv64", "fornax-riscv64")
            extra_kw["initrd"] = os.path.join(PROJECT_DIR, "zig-out", "esp-riscv64", "INITRD")

        esp_suffix = {"aarch64": "-aarch64"}.get(arch, "")
        esp_dir = os.path.join(PROJECT_DIR, "zig-out", f"esp{esp_suffix}")
        smp = 1 if arch == "riscv64" else 4

        # Use TAP or SLiRP context
        tap_ctx = TapNetwork("fornax0") if use_tap else None
        qemu = None

        try:
            if tap_ctx:
                tap_ctx.__enter__()
                host_ip = tap_ctx.host_ip
                guest_target = tap_ctx.host_ip
                log("TAP", f"Bridged fornax0 to network (host={host_ip})")

            qemu = QemuDriver(
                fw, esp_dir, disk_img, smp=smp, memory="4G", arch=arch,
                tap_iface="fornax0" if use_tap else None,
                **extra_kw,
            )
            qemu.start()
            mode_str = "TAP+bridge" if use_tap else "SLiRP"
            log("QEMU", f"Booting {arch} (smp={smp}, net={mode_str})...")

            # Wait for login
            qemu.expect(r"fornax login:", timeout=120)
            qemu.send_line("root")
            qemu.expect(r"root@fornax", timeout=15)
            log("BOOT", "Logged in")

            # Wait for network — poll /net/status for a non-zero IP.
            # Can't rely on "DHCP BOUND" serial match because it may
            # print during boot before we start looking.
            log("NET", "Waiting for network...")
            net_up = False
            for attempt in range(15):
                marker = f"__NET{attempt}__"
                qemu.send_line(f"cat /net/status; echo {marker}")
                m = qemu.expect(rf"{marker}\r?\n", timeout=10)
                # Check the log buffer for an IP line before the marker
                log_tail = qemu.full_log[-2048:].decode(errors="replace")
                for line in log_tail.splitlines():
                    stripped = line.strip()
                    if stripped.startswith("ip "):
                        ip = stripped.split()[1]
                        if ip != "0.0.0.0":
                            log("NET", f"Network up: {ip}")
                            if use_tap:
                                guest_target = tap_ctx.host_ip
                            net_up = True
                            break
                if net_up:
                    break
                time.sleep(2)
            if not net_up:
                raise RuntimeError("Network did not come up (no IP after 30s)")

            # Ping gateway to warm ARP
            qemu.send_cmd(f"ping -c 1 {guest_target}", timeout=15)
            log("NET", "Gateway reachable")

            # --- Run iperf tests (serial muted) ---
            log("IPERF", f"Starting benchmark ({duration}s x {runs} runs, serial muted)...")

            results = []
            guest_reports = []

            for run_num in range(1, runs + 1):
                # Start host-side sink — bind 0.0.0.0 so we accept
                # connections arriving on any interface (bridge, etc.)
                sink = TcpSink(port, bind_addr="0.0.0.0")
                sink.start()
                actual_port = sink.port
                time.sleep(1.0)

                # Run iperf client in guest (quiet — no serial spam)
                iperf_marker = f"__IPERF{run_num}__"
                cmd = f"iperf -c {guest_target} -p {actual_port} -t {duration}"
                send_line_quiet(qemu, f"{cmd}; echo {iperf_marker}")

                # Wait for completion — match marker+newline to avoid
                # false-matching the shell's character-by-character echo
                # of the command itself.
                timed_out = False
                try:
                    expect_quiet(qemu, rf"{iperf_marker}\r?\n", timeout=duration + 30)
                except TimeoutError:
                    timed_out = True

                sink.wait(timeout=duration + 15)
                sink.stop()

                # Extract guest-side report from serial log
                guest_report = ""
                if qemu.full_log:
                    log_text = qemu.full_log.decode(errors="replace")
                    # Find last iperf report block
                    report_marker = "--- iperf client results ---"
                    idx = log_text.rfind(report_marker)
                    if idx >= 0:
                        end = log_text.find(f"__IPERF{run_num}__", idx)
                        if end > idx:
                            guest_report = log_text[idx:end].strip()

                if timed_out:
                    results.append(None)
                    guest_reports.append("TIMED OUT")
                else:
                    results.append({
                        "bytes": sink.total_bytes,
                        "elapsed": sink.elapsed,
                        "kbps": sink.throughput_kbps,
                        "mbps": sink.throughput_mbps,
                    })
                    guest_reports.append(guest_report)

                # Pause between runs — let TCP FIN exchange complete
                time.sleep(3)

            # Shutdown (quiet)
            time.sleep(0.5)
            send_line_quiet(qemu, "shutdown")
            try:
                _mute()
                qemu.wait_exit(timeout=15)
            except Exception:
                pass
            finally:
                _unmute()

            # Save full serial log
            if serial_log:
                with open(serial_log, "wb") as f:
                    f.write(qemu.full_log)

            # --- Print clean results table AFTER serial is done ---
            _unmute()
            out = _real_stderr
            print(file=out)
            w = 62
            print(f"{BOLD}{'='*w}{RESET}", file=out)
            print(f"{BOLD}  iperf throughput benchmark — {arch} (smp={smp}, {mode_str}){RESET}", file=out)
            print(f"{BOLD}{'='*w}{RESET}", file=out)
            print(f"  Duration: {duration}s per run, {runs} runs", file=out)
            print(f"  Host sink: {host_ip}:{actual_port}  Guest target: {guest_target}:{actual_port}", file=out)
            if serial_log:
                print(f"  Serial log: {serial_log}", file=out)
            print(f"{'='*w}", file=out)
            print(f"  {'Run':<5} {'Status':<10} {'Duration':>9} {'Bytes':>12} {'KB/s':>9} {'Mbps':>9}", file=out)
            print(f"  {'-'*56}", file=out)

            for i, r in enumerate(results):
                run_num = i + 1
                if r is None:
                    print(f"  {run_num:<5} {RED}{'TIMEOUT':<10}{RESET} {'—':>9} {'—':>12} {'—':>9} {'—':>9}", file=out)
                elif r["bytes"] == 0:
                    print(f"  {run_num:<5} {YELLOW}{'NO DATA':<10}{RESET} {r['elapsed']:>8.2f}s {'0':>12} {'0.0':>9} {'0.000':>9}", file=out)
                else:
                    print(
                        f"  {run_num:<5} {GREEN}{'OK':<10}{RESET} "
                        f"{r['elapsed']:>8.2f}s {r['bytes']:>12,} {r['kbps']:>9.1f} {r['mbps']:>9.3f}",
                        file=out,
                    )

            # Summary
            valid = [r for r in results if r is not None and r["bytes"] > 0]
            print(f"  {'-'*56}", file=out)
            if valid:
                avg_kbps = sum(r["kbps"] for r in valid) / len(valid)
                avg_mbps = sum(r["mbps"] for r in valid) / len(valid)
                total_bytes = sum(r["bytes"] for r in valid)
                print(f"  {'Avg':<5} {'':10} {'':>9} {total_bytes:>12,} {avg_kbps:>9.1f} {avg_mbps:>9.3f}", file=out)
            else:
                print(f"  {RED}All runs failed — no data transferred{RESET}", file=out)

            # Guest-side reports
            print(f"\n  {BOLD}Guest reports:{RESET}", file=out)
            for i, report in enumerate(guest_reports):
                if report:
                    for line in report.split("\n"):
                        print(f"    [{i+1}] {line.strip()}", file=out)
                else:
                    print(f"    [{i+1}] (no report captured)", file=out)

            # Diagnostic
            hangs = sum(1 for r in results if r is None)
            zero_data = sum(1 for r in results if r is not None and r["bytes"] == 0)
            write_errors = sum(1 for r in guest_reports if "write error" in r)
            print(file=out)
            if hangs:
                print(f"  {RED}DIAGNOSTIC: {hangs}/{runs} runs timed out — TCP data delivery hang{RESET}", file=out)
            if write_errors:
                print(f"  {YELLOW}DIAGNOSTIC: {write_errors}/{runs} runs had write errors — TCP send path issue{RESET}", file=out)
            if zero_data and not hangs:
                print(f"  {YELLOW}DIAGNOSTIC: {zero_data}/{runs} runs transferred no data{RESET}", file=out)
            if not hangs and not write_errors and not zero_data and valid:
                avg = sum(r["kbps"] for r in valid) / len(valid)
                if avg < 100:
                    print(f"  {YELLOW}DIAGNOSTIC: Throughput very low ({avg:.0f} KB/s) — possible congestion/retransmit issue{RESET}", file=out)
                else:
                    print(f"  {GREEN}DIAGNOSTIC: TCP data path appears functional{RESET}", file=out)

            print(f"{'='*w}\n", file=out)

            return hangs == 0

        except (TimeoutError, RuntimeError, PermissionError) as e:
            print(f"{RED}Error: {e}{RESET}", file=sys.stderr)
            return False
        finally:
            if qemu is not None:
                qemu.stop()
            if tap_ctx:
                tap_ctx.__exit__(None, None, None)


def main():
    parser = argparse.ArgumentParser(description="Fornax iperf throughput benchmark")
    parser.add_argument("--arch", default="x86_64", choices=["x86_64", "riscv64", "aarch64"],
                        help="Target architecture (default: x86_64)")
    parser.add_argument("--duration", type=int, default=5,
                        help="Seconds per iperf run (default: 5)")
    parser.add_argument("--runs", type=int, default=3,
                        help="Number of iperf runs (default: 3)")
    parser.add_argument("--port", type=int, default=5201,
                        help="TCP port for iperf sink (default: 5201)")
    parser.add_argument("--all-arch", action="store_true",
                        help="Run on all available architectures")
    parser.add_argument("--no-build", action="store_true",
                        help="Skip build step (use existing zig-out)")
    parser.add_argument("--slirp", action="store_true",
                        help="Use SLiRP instead of TAP (no sudo required)")
    parser.add_argument("--serial-log", default=None,
                        help="Save full serial log to this file (default: /tmp/iperf-<arch>.log)")
    args = parser.parse_args()

    arches = []
    if args.all_arch:
        arches = ["x86_64"]
        import shutil
        if find_aavmf():
            arches.append("aarch64")
        if shutil.which("qemu-system-riscv64"):
            arches.append("riscv64")
    else:
        arches = [args.arch]

    use_tap = not args.slirp

    all_ok = True
    for arch in arches:
        if not args.no_build:
            if not build(arch, ["-Dcontainers=true"]):
                all_ok = False
                continue

        serial_log = args.serial_log or f"/tmp/iperf-{arch}.log"
        if not run_iperf_test(arch, args.duration, args.port, serial_log, use_tap=use_tap, runs=args.runs):
            all_ok = False

    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
