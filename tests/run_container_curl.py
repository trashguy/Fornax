#!/usr/bin/env python3
"""Container HTTP download test — verifies Linux compat networking.

Uses a tiny static C binary (httpget) that does raw-socket HTTP GET.
Much simpler than iperf3: no threads, no timers, no SIGALRM. Just:
  socket → connect → write(GET) → read loop → print bytes → exit

Usage:
    sudo python tests/run_container_curl.py
    sudo python tests/run_container_curl.py --no-build
"""
import argparse
import http.server
import os
import shutil
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

HTTPGET_CACHE = "/tmp/httpget-static-fornax"

# Minimal HTTP GET client in C — raw sockets, no dependencies
HTTPGET_C = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

int main(int argc, char *argv[]) {
    if (argc < 4) {
        write(2, "usage: httpget <ip> <port> <path>\n", 33);
        return 1;
    }

    const char *ip = argv[1];
    int port = atoi(argv[2]);
    const char *path = argv[3];

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { write(2, "socket failed\n", 14); return 1; }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    inet_pton(AF_INET, ip, &addr.sin_addr);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        write(2, "connect failed\n", 15);
        return 1;
    }

    /* Send HTTP GET request */
    char req[512];
    int reqlen = snprintf(req, sizeof(req),
        "GET %s HTTP/1.0\r\nHost: %s:%d\r\n\r\n", path, ip, port);
    write(fd, req, reqlen);

    /* Read response — count total bytes */
    char buf[8192];
    long total = 0;
    int n;
    while ((n = read(fd, buf, sizeof(buf))) > 0) {
        total += n;
    }

    close(fd);

    /* Print result for the test harness to parse */
    char out[64];
    int len = snprintf(out, sizeof(out), "HTTPGET_OK bytes=%ld\n", total);
    write(1, out, len);
    return 0;
}
"""


# ── Serial muting ────────────────────────────────────────────────────

class _DevNull:
    buffer = property(lambda self: self)
    def write(self, data): return len(data) if isinstance(data, (bytes, bytearray)) else len(data)
    def flush(self): pass
    def fileno(self): return os.open(os.devnull, os.O_WRONLY)

_devnull = _DevNull()
_real_stderr = sys.stderr

def _mute(): sys.stderr = _devnull
def _unmute(): sys.stderr = _real_stderr

def expect_quiet(qemu, pattern, timeout=30):
    _mute()
    try:
        return qemu.expect(pattern, timeout=timeout)
    finally:
        _unmute()

def send_line_quiet(qemu, text):
    _mute()
    try:
        qemu.send_line(text)
    finally:
        _unmute()


# ── Build ────────────────────────────────────────────────────────────

def build():
    log("BUILD", "Building x86_64 -Dcontainers=true...")
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


# ── Static httpget binary (ET_EXEC via podman) ───────────────────────

def build_static_httpget():
    """Build a tiny static HTTP GET binary via podman, cached."""
    if os.path.exists(HTTPGET_CACHE):
        result = subprocess.run(["readelf", "-h", HTTPGET_CACHE],
                                capture_output=True, text=True)
        if result.returncode == 0 and "EXEC" in result.stdout:
            size = os.path.getsize(HTTPGET_CACHE)
            log("IMG", f"Using cached static httpget ({size} bytes)")
            return True

    if subprocess.run(["which", "podman"], capture_output=True).returncode != 0:
        print(f"{RED}podman not found{RESET}", file=sys.stderr)
        return False

    log("IMG", "Building static httpget via podman...")

    with tempfile.TemporaryDirectory() as bdir:
        # Write C source
        src = os.path.join(bdir, "httpget.c")
        with open(src, "w") as f:
            f.write(HTTPGET_C)

        # Single-step build: compile + extract
        result = subprocess.run(
            ["podman", "run", "--rm",
             "-v", f"{bdir}:/build:Z",
             "alpine:3.21",
             "sh", "-c",
             "apk add --no-cache gcc musl-dev > /dev/null 2>&1 && "
             "gcc -static -no-pie -O2 -o /build/httpget /build/httpget.c && "
             "strip /build/httpget"],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            print(f"{RED}Build failed:{RESET}\n{result.stderr}", file=sys.stderr)
            return False

        shutil.copy2(os.path.join(bdir, "httpget"), HTTPGET_CACHE)

    # Verify ET_EXEC
    result = subprocess.run(["readelf", "-h", HTTPGET_CACHE],
                            capture_output=True, text=True)
    if "EXEC" not in result.stdout:
        print(f"{RED}Built binary is not ET_EXEC{RESET}", file=sys.stderr)
        return False

    size = os.path.getsize(HTTPGET_CACHE)
    log("IMG", f"Static httpget built OK ({size} bytes, ET_EXEC)")
    return True


def prebake_container_image(rootfs_dir):
    """Pre-bake container image with static httpget."""
    if not build_static_httpget():
        return False

    image_dir = os.path.join(rootfs_dir, "var", "lib", "fnx", "images", "curlbench")
    image_rootfs = os.path.join(image_dir, "rootfs")
    containers_dir = os.path.join(rootfs_dir, "var", "lib", "fnx", "containers")

    if os.path.exists(image_dir):
        subprocess.run(["rm", "-rf", image_dir], check=True)
    os.makedirs(os.path.join(image_rootfs, "usr", "bin"), exist_ok=True)
    os.makedirs(os.path.join(image_rootfs, "tmp"), exist_ok=True)
    os.makedirs(os.path.join(image_rootfs, "etc"), exist_ok=True)
    os.makedirs(containers_dir, exist_ok=True)

    # Minimal TZif2 for UTC (musl opens /etc/localtime)
    with open(os.path.join(image_rootfs, "etc", "localtime"), "wb") as f:
        f.write(b"TZif2" + b"\x00" * 39 + b"\x00" * 6 * 4)

    dest = os.path.join(image_rootfs, "usr", "bin", "httpget")
    shutil.copy2(HTTPGET_CACHE, dest)
    os.chmod(dest, 0o755)
    log("IMG", f"Installed httpget ({os.path.getsize(dest)} bytes)")

    with open(os.path.join(image_dir, "config"), "w") as f:
        f.write("/usr/bin/httpget\n")
    with open(os.path.join(image_dir, "compat"), "w") as f:
        f.write("linux\n")

    log("IMG", "Container image pre-baked OK")
    return True


# ── HTTP server ──────────────────────────────────────────────────────

class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

def start_http_server(directory, port, bind_addr="0.0.0.0"):
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


# ── Main test ────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Container HTTP download test")
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--serial-log", default="/tmp/curl-container.log")
    args = parser.parse_args()

    if not args.no_build:
        if not build():
            return 1

    fw = find_ovmf()
    if not fw:
        print(f"{RED}OVMF not found{RESET}", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="fornax-ccurl-") as tmpdir:
        # Create test files
        test_dir = os.path.join(tmpdir, "www")
        os.makedirs(test_dir)
        sizes = {
            "1k.bin": 1024,
            "100k.bin": 100 * 1024,
            "1m.bin": 1024 * 1024,
        }
        for name, size in sizes.items():
            with open(os.path.join(test_dir, name), "wb") as f:
                f.write(os.urandom(size))
        log("HTTP", f"Test files: {', '.join(sizes.keys())}")

        # Prepare rootfs + container image
        rootfs_dir = os.path.join(PROJECT_DIR, "zig-out", "rootfs")
        prepare_rootfs(rootfs_dir)
        install_dhcp_config(rootfs_dir)
        if not prebake_container_image(rootfs_dir):
            return 1

        disk_img = create_test_disk(tmpdir, rootfs_dir, disk_size_mb=512)
        log("DISK", "OK")

        esp_dir = os.path.join(PROJECT_DIR, "zig-out", "esp")
        tap_ctx = TapNetwork("fornax0")
        qemu = None

        try:
            tap_ctx.__enter__()
            host_ip = tap_ctx.host_ip
            log("TAP", f"Bridged (host={host_ip})")

            http_port = 8080
            http_srv = start_http_server(test_dir, http_port)
            log("HTTP", f"Serving on {host_ip}:{http_port}")

            qemu = QemuDriver(fw, esp_dir, disk_img, smp=4, memory="4G",
                             tap_iface="fornax0")
            qemu.start()
            log("QEMU", "Booting x86_64...")

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

            # --- Container httpget tests ---
            print(file=_real_stderr)
            print(f"{BOLD}{'='*66}{RESET}", file=_real_stderr)
            print(f"{BOLD}  Container HTTP test — static musl httpget in Fornax container{RESET}",
                  file=_real_stderr)
            print(f"{'='*66}", file=_real_stderr)
            print(f"  {'Run':<5} {'File':<12} {'Size':>10} {'Status':<12} {'Time':>8} {'Bytes':>10}",
                  file=_real_stderr)
            print(f"  {'-'*58}", file=_real_stderr)

            run = 0
            any_ok = False
            for name, expected_size in sizes.items():
                run += 1
                start_marker = f"__CS{run}__"
                end_marker = f"__CD{run}__"

                fnx_cmd = (
                    f"fnx run --compat linux --name ht{run} curlbench "
                    f"/usr/bin/httpget {host_ip} {http_port} /{name}"
                )
                send_line_quiet(qemu, f"echo {start_marker}; {fnx_cmd}; echo {end_marker}")

                timed_out = False
                t0 = time.monotonic()
                try:
                    expect_quiet(qemu, rf"{end_marker}\r?\n", timeout=60)
                except TimeoutError:
                    timed_out = True
                elapsed = time.monotonic() - t0

                # Parse guest output for HTTPGET_OK bytes=N
                rx_bytes = None
                if qemu.full_log:
                    text = qemu.full_log.decode(errors="replace")
                    idx = text.rfind(start_marker)
                    if idx >= 0:
                        chunk = text[idx:idx+2048]
                        for line in chunk.splitlines():
                            if "HTTPGET_OK" in line and "bytes=" in line:
                                try:
                                    rx_bytes = int(line.split("bytes=")[1].split()[0])
                                except (ValueError, IndexError):
                                    pass

                size_str = (f"{expected_size // 1024}K" if expected_size < 1024*1024
                           else f"{expected_size // (1024*1024)}M")

                if timed_out:
                    status = f"{RED}TIMEOUT{RESET}"
                    time_str = ">60s"
                    bytes_str = ""
                elif rx_bytes is not None and rx_bytes > 0:
                    any_ok = True
                    status = f"{GREEN}OK{RESET}"
                    time_str = f"{elapsed:.2f}s"
                    bytes_str = str(rx_bytes)
                else:
                    status = f"{YELLOW}NO_DATA{RESET}"
                    time_str = f"{elapsed:.2f}s"
                    bytes_str = str(rx_bytes) if rx_bytes is not None else "?"

                print(f"  {run:<5} {name:<12} {size_str:>10} {status:<12} {time_str:>8} {bytes_str:>10}",
                      file=_real_stderr)

                time.sleep(1)

            print(f"  {'-'*58}", file=_real_stderr)
            if any_ok:
                print(f"  {GREEN}Container networking functional!{RESET}", file=_real_stderr)
            else:
                print(f"  {RED}All downloads failed{RESET}", file=_real_stderr)
            print(f"{'='*66}\n", file=_real_stderr)

            # Shutdown
            send_line_quiet(qemu, "shutdown")
            try:
                _mute()
                qemu.wait_exit(timeout=15)
            except Exception:
                pass
            finally:
                _unmute()

            if args.serial_log:
                with open(args.serial_log, "wb") as f:
                    f.write(qemu.full_log)
                log("LOG", f"Serial log: {args.serial_log}")

            http_srv.shutdown()

            if not any_ok:
                tail = qemu.full_log[-4096:].decode(errors="replace")
                print(f"{RED}Serial log tail:{RESET}", file=_real_stderr)
                for line in tail.splitlines()[-30:]:
                    clean = line.strip()
                    if clean:
                        print(f"  {clean}", file=_real_stderr)

            return 0 if any_ok else 1

        except (TimeoutError, RuntimeError, PermissionError) as e:
            print(f"{RED}Error: {e}{RESET}", file=sys.stderr)
            if args.serial_log and qemu and qemu.full_log:
                with open(args.serial_log, "wb") as f:
                    f.write(qemu.full_log)
            return 1
        finally:
            if qemu is not None:
                qemu.stop()
            tap_ctx.__exit__(None, None, None)


if __name__ == "__main__":
    sys.exit(main())
