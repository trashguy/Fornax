#!/usr/bin/env python3
"""Quick diagnostic: sequential curl downloads to test TCP RX path reliability.

Starts a host-side HTTP server with test files, boots QEMU with TAP,
and runs curl multiple times to see if subsequent TCP connections work.

Usage:
    sudo python tests/run_curl_test.py [--no-build]
"""
import argparse
import http.server
import os
import subprocess
import sys
import tempfile
import threading
import time

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, PROJECT_DIR)

from tests.harness.qemu import QemuDriver
from tests.harness.disk import create_test_disk, prepare_rootfs
from tests.harness.config import find_ovmf, log, RED, GREEN, YELLOW, BOLD, RESET
from tests.harness.tap import TapNetwork


def build():
    log("BUILD", "Building x86_64...")
    r = subprocess.run(["zig", "build", "x86_64", "-Dcontainers=true"],
                       cwd=PROJECT_DIR, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"{RED}Build failed:{RESET}\n{r.stderr}", file=sys.stderr)
        return False
    r = subprocess.run(["zig", "build", "mkgpt", "mkfxfs"],
                       cwd=PROJECT_DIR, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"{RED}Host tools build failed:{RESET}\n{r.stderr}", file=sys.stderr)
        return False
    log("BUILD", "OK")
    return True


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # suppress logs


def start_http_server(directory, port, bind_addr="0.0.0.0"):
    """Start a simple HTTP server serving files from directory."""
    handler = lambda *a, **kw: QuietHandler(*a, directory=directory, **kw)
    srv = http.server.HTTPServer((bind_addr, port), handler)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    return srv


def install_dhcp_config(rootfs_dir):
    etc_dir = os.path.join(rootfs_dir, "etc")
    os.makedirs(etc_dir, exist_ok=True)
    with open(os.path.join(etc_dir, "net.conf"), "w") as f:
        f.write("dhcp\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--no-build", action="store_true")
    args = parser.parse_args()

    if not args.no_build:
        if not build():
            return 1

    fw = find_ovmf()
    if not fw:
        print(f"{RED}OVMF not found{RESET}", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="fornax-curl-") as tmpdir:
        # Create test files of various sizes
        test_dir = os.path.join(tmpdir, "www")
        os.makedirs(test_dir)
        sizes = {
            "1k.bin": 1024,
            "100k.bin": 100 * 1024,
            "1m.bin": 1024 * 1024,
            "10m.bin": 10 * 1024 * 1024,
        }
        for name, size in sizes.items():
            with open(os.path.join(test_dir, name), "wb") as f:
                f.write(os.urandom(size))
        log("HTTP", f"Test files created: {', '.join(sizes.keys())}")

        # Prepare rootfs and disk
        rootfs_dir = os.path.join(PROJECT_DIR, "zig-out", "rootfs")
        prepare_rootfs(rootfs_dir)
        install_dhcp_config(rootfs_dir)
        disk_img = create_test_disk(tmpdir, rootfs_dir)
        log("DISK", "OK")

        esp_dir = os.path.join(PROJECT_DIR, "zig-out", "esp")
        tap_ctx = TapNetwork("fornax0")
        qemu = None

        try:
            tap_ctx.__enter__()
            host_ip = tap_ctx.host_ip
            log("TAP", f"Bridged (host={host_ip})")

            # Start HTTP server
            http_port = 8080
            http_srv = start_http_server(test_dir, http_port)
            log("HTTP", f"Serving on {host_ip}:{http_port}")

            qemu = QemuDriver(fw, esp_dir, disk_img, smp=4, memory="4G",
                             tap_iface="fornax0")
            qemu.start()
            log("QEMU", "Booting x86_64...")

            # Wait for login
            qemu.expect(r"fornax login:", timeout=120)
            qemu.send_line("root")
            qemu.expect(r"root@fornax", timeout=15)
            log("BOOT", "Logged in")

            # Wait for network
            log("NET", "Waiting for DHCP...")
            net_up = False
            for attempt in range(15):
                marker = f"__NET{attempt}__"
                qemu.send_line(f"cat /net/status; echo {marker}")
                qemu.expect(rf"{marker}\r?\n", timeout=10)
                log_tail = qemu.full_log[-2048:].decode(errors="replace")
                for line in log_tail.splitlines():
                    s = line.strip()
                    if s.startswith("ip ") and s.split()[1] != "0.0.0.0":
                        log("NET", f"Up: {s.split()[1]}")
                        net_up = True
                        break
                if net_up:
                    break
                time.sleep(2)
            if not net_up:
                raise RuntimeError("Network not up")

            # Ping to warm ARP
            qemu.send_cmd(f"ping -c 1 {host_ip}", timeout=15)
            log("NET", "Gateway reachable")

            # Run curl tests - sequential downloads
            print(file=sys.stderr)
            print(f"{BOLD}{'='*62}{RESET}", file=sys.stderr)
            print(f"{BOLD}  curl download test — sequential TCP connections{RESET}", file=sys.stderr)
            print(f"{'='*62}", file=sys.stderr)
            print(f"  {'Run':<5} {'File':<12} {'Size':>10} {'Status':<10} {'Time':>8}", file=sys.stderr)
            print(f"  {'-'*50}", file=sys.stderr)

            run = 0
            # Test each file size, 2 rounds
            for round_num in range(2):
                for name, expected_size in sizes.items():
                    run += 1
                    url = f"http://{host_ip}:{http_port}/{name}"
                    marker = f"__CURL{run}__"

                    # curl -o /dev/null -w "time=%{{time_total}}" URL
                    # But our curl might not support -w. Let's just time it
                    # with the shell and check output size.
                    cmd = f"curl -s -o /dev/null {url}; echo {marker}"
                    qemu.send_line(cmd)

                    timed_out = False
                    t0 = time.monotonic()
                    try:
                        qemu.expect(rf"{marker}\r?\n", timeout=30)
                    except TimeoutError:
                        timed_out = True
                    elapsed = time.monotonic() - t0

                    if timed_out:
                        status = f"{RED}TIMEOUT{RESET}"
                        time_str = ">30s"
                    else:
                        # Estimate throughput
                        if elapsed > 0.001:
                            mbps = expected_size * 8 / elapsed / 1024 / 1024
                            status = f"{GREEN}OK{RESET}"
                            time_str = f"{elapsed:.2f}s"
                        else:
                            status = f"{GREEN}OK{RESET}"
                            time_str = "<0.01s"

                    size_str = f"{expected_size // 1024}K" if expected_size < 1024*1024 else f"{expected_size // (1024*1024)}M"
                    print(f"  {run:<5} {name:<12} {size_str:>10} {status:<10} {time_str:>8}", file=sys.stderr)

                    time.sleep(1)  # brief pause between runs

            print(f"  {'-'*50}", file=sys.stderr)
            print(f"{'='*62}\n", file=sys.stderr)

            # Shutdown
            qemu.send_line("shutdown")
            try:
                qemu.wait_exit(timeout=15)
            except Exception:
                pass

            http_srv.shutdown()
            return 0

        except (TimeoutError, RuntimeError, PermissionError) as e:
            print(f"{RED}Error: {e}{RESET}", file=sys.stderr)
            return 1
        finally:
            if qemu is not None:
                qemu.stop()
            tap_ctx.__exit__(None, None, None)


if __name__ == "__main__":
    sys.exit(main())
