#!/usr/bin/env python3
"""Linux baseline iperf3 throughput test — same QEMU TAP+bridge setup as Fornax.

Boots an Alpine Linux cloud image in QEMU with identical network config
(virtio-net, TAP+bridge, smp=4, 4GB RAM) and runs iperf3 to establish
the throughput ceiling imposed by QEMU+TAP.

Usage:
    sudo python tests/linux_baseline_iperf.py [--duration 5] [--runs 3]

First run downloads Alpine cloud image (~60MB) to /tmp.
Requires iperf3 installed on the host (for the server side).
"""
import argparse
import fcntl
import os
import re
import select
import signal
import subprocess
import sys
import time

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, PROJECT_DIR)

from tests.harness.tap import TapNetwork

# Alpine cloud image URL (virt variant, tiny, has iperf3 in repos)
ALPINE_VERSION = "3.21"
ALPINE_RELEASE = "3.21.3"
ALPINE_IMG_NAME = f"alpine-virt-{ALPINE_RELEASE}-x86_64.iso"
ALPINE_IMG_URL = f"https://dl-cdn.alpinelinux.org/alpine/v{ALPINE_VERSION}/releases/x86_64/{ALPINE_IMG_NAME}"
ALPINE_CACHE = f"/tmp/{ALPINE_IMG_NAME}"

BOLD = "\033[1m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
RED = "\033[31m"
RESET = "\033[0m"


def log(tag, msg):
    print(f"  {BOLD}[{tag}]{RESET} {msg}", file=sys.stderr, flush=True)


def fetch_alpine():
    """Download Alpine ISO if not cached."""
    if os.path.exists(ALPINE_CACHE):
        log("IMG", f"Using cached {ALPINE_CACHE}")
        return ALPINE_CACHE
    log("IMG", f"Downloading Alpine {ALPINE_RELEASE}...")
    subprocess.run(["curl", "-fSL", "-o", ALPINE_CACHE, ALPINE_IMG_URL], check=True)
    log("IMG", "Download complete")
    return ALPINE_CACHE


class LinuxVM:
    """Boot Alpine Linux in QEMU with serial console interaction."""

    def __init__(self, iso_path, tap_iface, smp=4, memory="4G"):
        self.iso_path = iso_path
        self.tap_iface = tap_iface
        self.smp = smp
        self.memory = memory
        self.proc = None
        self.buf = b""
        self.full_log = b""

    def start(self):
        netdev = f"tap,id=net0,ifname={self.tap_iface},script=no,downscript=no"
        cmd = [
            "qemu-system-x86_64",
            "-enable-kvm",
            "-cpu", "host",
            "-smp", str(self.smp),
            "-m", self.memory,
            "-cdrom", self.iso_path,
            "-boot", "d",
            "-device", "virtio-net-pci,netdev=net0",
            "-netdev", netdev,
            "-serial", "stdio",
            "-display", "none",
            "-no-reboot",
            "-no-shutdown",
        ]
        self.proc = subprocess.Popen(
            cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        fd = self.proc.stdout.fileno()
        flags = fcntl.fcntl(fd, fcntl.F_GETFL)
        fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)

    def send_line(self, text):
        self.proc.stdin.write((text + "\n").encode())
        self.proc.stdin.flush()

    def expect(self, pattern, timeout=60):
        deadline = time.monotonic() + timeout
        regex = re.compile(pattern.encode() if isinstance(pattern, str) else pattern)
        while time.monotonic() < deadline:
            remaining = max(0.01, deadline - time.monotonic())
            r, _, _ = select.select([self.proc.stdout], [], [], min(remaining, 0.5))
            if r:
                try:
                    chunk = self.proc.stdout.read(4096)
                    if chunk:
                        self.buf += chunk
                        self.full_log += chunk
                except (IOError, OSError):
                    pass
            m = regex.search(self.buf)
            if m:
                self.buf = self.buf[m.end():]
                return m
        raise TimeoutError(f"Timed out waiting for: {pattern}")

    def send_cmd(self, cmd, timeout=30):
        """Send command and wait for next prompt."""
        self.send_line(cmd)
        self.expect(r"[#\$] ", timeout=timeout)

    def stop(self):
        if self.proc:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()


def find_free_port(start=5201):
    """Find a free TCP port starting from `start`."""
    import socket
    for p in range(start, start + 100):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(("0.0.0.0", p))
            s.close()
            return p
        except OSError:
            continue
    raise OSError(f"No free port in range {start}-{start+99}")


def parse_iperf3_output(text):
    """Extract sender throughput from iperf3 output text."""
    # Look for the summary line: "[ ID] ... sender"
    # Example: "[  5]   0.00-15.00  sec  5.24 GBytes  3.00 Gbits/sec    0             sender"
    for line in text.splitlines():
        if "sender" in line and ("Gbits/sec" in line or "Mbits/sec" in line or "Kbits/sec" in line):
            parts = line.split()
            for j, p in enumerate(parts):
                if p in ("Gbits/sec", "Mbits/sec", "Kbits/sec"):
                    try:
                        val = float(parts[j - 1])
                        if p == "Gbits/sec":
                            return val * 1000  # → Mbps
                        elif p == "Mbits/sec":
                            return val
                        elif p == "Kbits/sec":
                            return val / 1000
                    except (ValueError, IndexError):
                        pass
    return None


def run_baseline(duration, runs, port, serial_log=None):
    # Check host has iperf3
    if not subprocess.run(["which", "iperf3"], capture_output=True).returncode == 0:
        log("ERR", "iperf3 not found on host. Install it: sudo pacman -S iperf3")
        return False

    iso = fetch_alpine()

    tap_ctx = TapNetwork("fornax0")
    vm = None
    iperf_srv = None

    try:
        tap_ctx.__enter__()
        host_ip = tap_ctx.host_ip
        log("TAP", f"Bridged fornax0 (host={host_ip})")

        # Find a free port and start iperf3 server on host
        actual_port = find_free_port(port)
        iperf_srv = subprocess.Popen(
            ["iperf3", "-s", "-p", str(actual_port), "-1"],  # -1 = one-off for first test
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        # We'll restart it per run below; kill this initial one
        iperf_srv.terminate()
        iperf_srv.wait()
        iperf_srv = None
        log("HOST", f"iperf3 will use port {actual_port}")

        vm = LinuxVM(iso, "fornax0", smp=4, memory="4G")
        vm.start()
        log("QEMU", "Booting Alpine Linux...")

        # Wait for login prompt
        vm.expect(r"localhost login:", timeout=90)
        vm.send_line("root")
        vm.expect(r"[#\$] ", timeout=15)
        log("BOOT", "Logged in as root")

        # Configure network via DHCP
        vm.send_cmd("ip link set eth0 up", timeout=10)
        vm.send_cmd("udhcpc -i eth0 -t 5 -T 3 -n", timeout=30)
        time.sleep(2)

        # Show IP for verification
        vm.send_line("ip -4 addr show eth0")
        vm.expect(r"[#\$] ", timeout=10)
        log_tail = vm.full_log[-2048:].decode(errors="replace")
        for line in log_tail.splitlines():
            if "inet " in line and "eth0" in line:
                log("NET", line.strip())
                break

        # Configure repos and install iperf3
        log("SETUP", "Configuring Alpine repos...")
        vm.send_cmd(
            f"echo 'https://dl-cdn.alpinelinux.org/alpine/v{ALPINE_VERSION}/main' > /etc/apk/repositories",
            timeout=10,
        )
        log("SETUP", "Installing iperf3...")
        vm.send_cmd("apk add --no-cache iperf3", timeout=60)
        vm.send_cmd("which iperf3", timeout=5)
        log("SETUP", "iperf3 installed")

        # Run tests
        log("TEST", f"Starting benchmark ({duration}s x {runs} runs)...")
        results = []

        for run_num in range(1, runs + 1):
            # Start fresh iperf3 server on host for each run
            iperf_srv = subprocess.Popen(
                ["iperf3", "-s", "-p", str(actual_port), "-1"],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
            time.sleep(0.5)

            # Run iperf3 client in guest → host
            start_marker = f"__START{run_num}__"
            marker = f"__DONE{run_num}__"
            vm.send_line(
                f"echo {start_marker}; iperf3 -c {host_ip} -p {actual_port} -t {duration} 2>&1; echo {marker}"
            )

            timed_out = False
            try:
                vm.expect(rf"{marker}", timeout=duration + 30)
            except TimeoutError:
                timed_out = True

            # Wait for iperf3 server to finish
            try:
                iperf_srv.wait(timeout=duration + 10)
            except subprocess.TimeoutExpired:
                iperf_srv.terminate()

            # Extract guest-side iperf3 output from serial log
            guest_output = ""
            if vm.full_log:
                text = vm.full_log.decode(errors="replace")
                # Use start/end markers (plain alphanumeric, survives serial garbling)
                idx = text.rfind(start_marker)
                end = text.rfind(marker)
                if idx >= 0 and end > idx:
                    guest_output = text[idx + len(start_marker):end]

            mbps = parse_iperf3_output(guest_output) if not timed_out else None

            if timed_out:
                results.append({"status": "TIMEOUT"})
            elif mbps is not None:
                results.append({"status": "OK", "mbps": mbps, "guest_output": guest_output})
            else:
                results.append({"status": "PARSE_FAIL", "guest_output": guest_output})

            iperf_srv = None
            time.sleep(2)

        # Shutdown
        vm.send_line("poweroff")
        time.sleep(2)

        # Save full serial log
        serial_log_path = serial_log or "/tmp/iperf-baseline.log"
        with open(serial_log_path, "wb") as f:
            f.write(vm.full_log)

        # Print results
        w = 66
        out = sys.stderr
        print(f"\n{BOLD}{'='*w}{RESET}", file=out)
        print(f"{BOLD}  LINUX BASELINE — iperf3 (Alpine, virtio-net, TAP+bridge, smp=4){RESET}", file=out)
        print(f"{BOLD}{'='*w}{RESET}", file=out)
        print(f"  Duration: {duration}s per run, {runs} runs", file=out)
        print(f"  Host: {host_ip}:{actual_port}", file=out)
        print(f"  Serial log: {serial_log_path}", file=out)
        print(f"{'='*w}", file=out)
        print(f"  {'Run':<5} {'Status':<12} {'Mbps':>10}", file=out)
        print(f"  {'-'*30}", file=out)

        valid_mbps = []
        for i, r in enumerate(results):
            rn = i + 1
            if r["status"] == "OK":
                valid_mbps.append(r["mbps"])
                print(f"  {rn:<5} {GREEN}{'OK':<12}{RESET} {r['mbps']:>10.1f}", file=out)
            elif r["status"] == "TIMEOUT":
                print(f"  {rn:<5} {RED}{'TIMEOUT':<12}{RESET}", file=out)
            else:
                print(f"  {rn:<5} {YELLOW}{'PARSE_FAIL':<12}{RESET}", file=out)

        print(f"  {'-'*30}", file=out)
        if valid_mbps:
            avg = sum(valid_mbps) / len(valid_mbps)
            mn = min(valid_mbps)
            mx = max(valid_mbps)
            print(f"  {'Avg':<5} {'':12} {avg:>10.1f}", file=out)
            print(f"  {'Min':<5} {'':12} {mn:>10.1f}", file=out)
            print(f"  {'Max':<5} {'':12} {mx:>10.1f}", file=out)
            print(f"\n  {BOLD}This is the QEMU+TAP ceiling. Fornax should approach this.{RESET}", file=out)
        else:
            print(f"  {RED}No successful runs{RESET}", file=out)
        print(f"{'='*w}\n", file=out)

        # Print guest reports for debugging
        any_debug = False
        for i, r in enumerate(results):
            if r["status"] != "OK":
                lines = r.get("guest_output", "").strip().splitlines()
                if lines:
                    any_debug = True
                    print(f"  Guest output (run {i+1}):", file=out)
                    for line in lines[-5:]:
                        print(f"    {line.strip()}", file=out)

        # If no useful guest output was captured, dump serial log tail
        if not any_debug and not valid_mbps:
            print(f"\n  {YELLOW}No guest output captured — serial log tail:{RESET}", file=out)
            tail = vm.full_log[-4096:].decode(errors="replace")
            for line in tail.splitlines()[-30:]:
                clean = line.strip()
                if clean:
                    print(f"    {clean}", file=out)

        return len(valid_mbps) > 0

    except (TimeoutError, RuntimeError, PermissionError) as e:
        print(f"{RED}Error: {e}{RESET}", file=sys.stderr)
        return False
    finally:
        if iperf_srv:
            iperf_srv.terminate()
        if vm:
            vm.stop()
        tap_ctx.__exit__(None, None, None)


def main():
    parser = argparse.ArgumentParser(description="Linux baseline iperf3 throughput test")
    parser.add_argument("--duration", type=int, default=5,
                        help="Seconds per run (default: 5)")
    parser.add_argument("--runs", type=int, default=3,
                        help="Number of runs (default: 3)")
    parser.add_argument("--port", type=int, default=5201,
                        help="TCP port (default: 5201)")
    parser.add_argument("--serial-log", default=None,
                        help="Save full serial log to this file (default: /tmp/iperf-baseline.log)")
    args = parser.parse_args()
    return 0 if run_baseline(args.duration, args.runs, args.port, args.serial_log) else 1


if __name__ == "__main__":
    sys.exit(main())
