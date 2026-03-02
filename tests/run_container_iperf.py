#!/usr/bin/env python3
"""Container iperf3 throughput benchmark — measures TCP stack vs application gap.

Boots Fornax with a pre-baked container image containing a statically-linked
iperf3 binary, runs `fnx run` to execute iperf3 inside the container targeting
a host-side iperf3 server, and reports throughput.

The static iperf3 binary is built via podman (Alpine + musl, -static -no-pie)
because Fornax's ELF loader only supports ET_EXEC. The binary is cached at
/tmp/iperf3-static-fornax for reuse across runs.

Compares against:
  - Native Fornax iperf (~100 Mbps) via run_iperf.py
  - QEMU+TAP ceiling (~65 Gbps) via linux_baseline_iperf.py

Requires sudo for TAP, iperf3 on host, and podman for building the static binary.

Usage:
    sudo python tests/run_container_iperf.py
    sudo python tests/run_container_iperf.py --no-build --runs 5 --duration 10
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time

# Add project root so we can import the harness
PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, PROJECT_DIR)

from tests.harness.qemu import QemuDriver
from tests.harness.disk import create_test_disk, prepare_rootfs
from tests.harness.config import find_ovmf, log, RED, GREEN, YELLOW, BOLD, RESET
from tests.harness.tap import TapNetwork

# Cached static iperf3 binary (ET_EXEC, musl, -static -no-pie)
IPERF3_STATIC_CACHE = "/tmp/iperf3-static-fornax"
IPERF3_VERSION = "3.17.1"


# ── Serial muting (same as run_iperf.py) ─────────────────────────────

class _DevNull:
    """Dummy stderr replacement that swallows everything."""
    buffer = property(lambda self: self)

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


# ── Build ─────────────────────────────────────────────────────────────

def build():
    """Build Fornax x86_64 with container support + host tools."""
    cmd = ["zig", "build", "x86_64", "-Dcontainers=true"]
    log("BUILD", "Building x86_64 -Dcontainers=true...")
    result = subprocess.run(cmd, cwd=PROJECT_DIR, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"{RED}Build failed:{RESET}\n{result.stderr}", file=sys.stderr)
        return False

    result = subprocess.run(
        ["zig", "build", "mkgpt", "mkfxfs"],
        cwd=PROJECT_DIR, capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"{RED}Host tools build failed:{RESET}\n{result.stderr}", file=sys.stderr)
        return False

    log("BUILD", "OK")
    return True


# ── Static iperf3 binary (ET_EXEC via podman) ────────────────────────

def build_static_iperf3():
    """Build a static non-PIE iperf3 binary via podman, cached at IPERF3_STATIC_CACHE.

    Fornax's ELF loader only accepts ET_EXEC (not ET_DYN/PIE), so we build
    iperf3 from source with -static -no-pie using Alpine's musl toolchain.
    """
    if os.path.exists(IPERF3_STATIC_CACHE):
        # Verify it's still ET_EXEC
        result = subprocess.run(
            ["readelf", "-h", IPERF3_STATIC_CACHE],
            capture_output=True, text=True,
        )
        if result.returncode == 0 and "EXEC" in result.stdout:
            size = os.path.getsize(IPERF3_STATIC_CACHE)
            log("IMG", f"Using cached static iperf3 ({size} bytes)")
            return True

    # Check podman is available
    if subprocess.run(["which", "podman"], capture_output=True).returncode != 0:
        print(f"{RED}podman not found. Required to build static iperf3.{RESET}",
              file=sys.stderr)
        return False

    log("IMG", f"Building static iperf3 {IPERF3_VERSION} via podman...")

    dockerfile = f"""\
FROM alpine:3.21 AS builder
RUN apk add --no-cache build-base linux-headers curl
RUN curl -fSL https://github.com/esnet/iperf/archive/refs/tags/{IPERF3_VERSION}.tar.gz \
      -o /tmp/iperf3.tar.gz && cd /tmp && tar xzf iperf3.tar.gz
RUN cd /tmp/iperf-{IPERF3_VERSION} \
    && CFLAGS="-static -no-pie" LDFLAGS="-static -no-pie" \
       ./configure --enable-static --disable-shared --enable-static-bin \
       --without-openssl \
    && make -j$(nproc) \
    && strip src/iperf3
"""

    # Build image
    result = subprocess.run(
        ["podman", "build", "--dns=1.1.1.1", "-t", "fornax-iperf3-builder", "-f", "-", "."],
        input=dockerfile, capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"{RED}podman build failed:{RESET}\n{result.stderr}", file=sys.stderr)
        return False

    # Extract binary
    subprocess.run(
        ["podman", "rm", "-f", "fornax-iperf3-extract"],
        capture_output=True,
    )
    result = subprocess.run(
        ["podman", "create", "--name", "fornax-iperf3-extract",
         "fornax-iperf3-builder", "true"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"{RED}podman create failed:{RESET}\n{result.stderr}", file=sys.stderr)
        return False

    result = subprocess.run(
        ["podman", "cp", f"fornax-iperf3-extract:/tmp/iperf-{IPERF3_VERSION}/src/iperf3",
         IPERF3_STATIC_CACHE],
        capture_output=True, text=True,
    )
    subprocess.run(["podman", "rm", "fornax-iperf3-extract"], capture_output=True)

    if result.returncode != 0:
        print(f"{RED}podman cp failed:{RESET}\n{result.stderr}", file=sys.stderr)
        return False

    # Verify
    result = subprocess.run(
        ["readelf", "-h", IPERF3_STATIC_CACHE],
        capture_output=True, text=True,
    )
    if "EXEC" not in result.stdout:
        print(f"{RED}Built binary is not ET_EXEC — cannot use with Fornax{RESET}",
              file=sys.stderr)
        return False

    size = os.path.getsize(IPERF3_STATIC_CACHE)
    log("IMG", f"Static iperf3 built OK ({size} bytes, ET_EXEC)")
    return True


def prebake_container_image(rootfs_dir):
    """Pre-bake a container image with static iperf3 into the Fornax rootfs.

    Creates the fnx image directory structure:
      rootfs/var/lib/fnx/images/iperf3bench/rootfs/usr/bin/iperf3  (static binary)
      rootfs/var/lib/fnx/images/iperf3bench/config                  (default cmd)
      rootfs/var/lib/fnx/images/iperf3bench/compat                  (linux)
      rootfs/var/lib/fnx/containers/                                 (fnx expects it)
    """
    if not build_static_iperf3():
        return False

    image_dir = os.path.join(rootfs_dir, "var", "lib", "fnx", "images", "iperf3bench")
    image_rootfs = os.path.join(image_dir, "rootfs")
    containers_dir = os.path.join(rootfs_dir, "var", "lib", "fnx", "containers")

    # Clean and create directories
    if os.path.exists(image_dir):
        subprocess.run(["rm", "-rf", image_dir], check=True)
    os.makedirs(os.path.join(image_rootfs, "usr", "bin"), exist_ok=True)
    os.makedirs(containers_dir, exist_ok=True)

    # Create essential directories for musl/iperf3
    os.makedirs(os.path.join(image_rootfs, "tmp"), exist_ok=True)
    os.makedirs(os.path.join(image_rootfs, "etc"), exist_ok=True)

    # Provide /etc/localtime (UTC) — musl opens this for timezone
    with open(os.path.join(image_rootfs, "etc", "localtime"), "wb") as f:
        # Minimal TZif2 file for UTC
        f.write(b"TZif2" + b"\x00" * 39 + b"\x00" * 6 * 4)

    # Copy static iperf3 binary
    iperf3_dest = os.path.join(image_rootfs, "usr", "bin", "iperf3")
    shutil.copy2(IPERF3_STATIC_CACHE, iperf3_dest)
    os.chmod(iperf3_dest, 0o755)
    log("IMG", f"Installed iperf3 ({os.path.getsize(iperf3_dest)} bytes)")

    # Write config (default command)
    with open(os.path.join(image_dir, "config"), "w") as f:
        f.write("/usr/bin/iperf3\n")

    # Write compat file (Linux mode)
    with open(os.path.join(image_dir, "compat"), "w") as f:
        f.write("linux\n")

    log("IMG", "Container image pre-baked OK")
    return True


# ── DHCP config ───────────────────────────────────────────────────────

def install_dhcp_config(rootfs_dir):
    """Install a DHCP-mode net.conf into the rootfs."""
    etc_dir = os.path.join(rootfs_dir, "etc")
    os.makedirs(etc_dir, exist_ok=True)
    with open(os.path.join(etc_dir, "net.conf"), "w") as f:
        f.write("# DHCP mode for TAP networking\ndhcp\n")


# ── iperf3 output parsing (from linux_baseline_iperf.py) ─────────────

def _extract_mbps(parts):
    """Extract Mbps value from a split iperf3 line containing a rate unit."""
    for j, p in enumerate(parts):
        if p in ("Gbits/sec", "Mbits/sec", "Kbits/sec"):
            try:
                val = float(parts[j - 1])
                if p == "Gbits/sec":
                    return val * 1000
                elif p == "Mbits/sec":
                    return val
                else:
                    return val / 1000
            except (ValueError, IndexError):
                pass
    return None


def parse_iperf3_output(text):
    """Extract throughput (Mbps) from iperf3 output text.

    Looks for the summary "sender" or "receiver" line first.
    Falls back to averaging the last few per-second interval lines
    (useful when iperf3 terminates abnormally without printing a summary).
    Returns (mbps, role) or (None, None).
    """
    # Prefer summary lines
    for role in ("receiver", "sender"):
        for line in text.splitlines():
            if role in line and ("Gbits/sec" in line or "Mbits/sec" in line or "Kbits/sec" in line):
                mbps = _extract_mbps(line.split())
                if mbps is not None:
                    return mbps, role

    # Fallback: average the last N per-second interval lines
    interval_rates = []
    for line in text.splitlines():
        if ("Gbits/sec" in line or "Mbits/sec" in line or "Kbits/sec" in line):
            # Skip header/separator lines
            if "Interval" in line or "- - -" in line:
                continue
            mbps = _extract_mbps(line.split())
            if mbps is not None:
                interval_rates.append(mbps)

    if interval_rates:
        # Use last 5 intervals (or all if fewer) for a stable average
        tail = interval_rates[-5:]
        avg = sum(tail) / len(tail)
        return avg, "interval-avg"

    return None, None


# ── Main test ─────────────────────────────────────────────────────────

def run_container_iperf(duration, port, serial_log, runs=3):
    """Boot Fornax, run iperf3 inside a container, measure throughput."""
    fw = find_ovmf()
    if not fw:
        print(f"{RED}OVMF firmware not found{RESET}", file=sys.stderr)
        return False

    # Check host has iperf3
    if subprocess.run(["which", "iperf3"], capture_output=True).returncode != 0:
        print(f"{RED}iperf3 not found on host. Install: sudo pacman -S iperf3{RESET}",
              file=sys.stderr)
        return False

    with tempfile.TemporaryDirectory(prefix="fornax-ciperf-") as tmpdir:
        # Prepare rootfs
        rootfs_dir = os.path.join(PROJECT_DIR, "zig-out", "rootfs")
        prepare_rootfs(rootfs_dir)
        install_dhcp_config(rootfs_dir)

        # Pre-bake container image
        if not prebake_container_image(rootfs_dir):
            return False

        # Create disk (512 MB to fit the container image)
        disk_img = create_test_disk(tmpdir, rootfs_dir, disk_size_mb=512)
        log("DISK", "OK")

        esp_dir = os.path.join(PROJECT_DIR, "zig-out", "esp")
        tap_ctx = TapNetwork("fornax0")
        qemu = None
        host_ip = None

        try:
            tap_ctx.__enter__()
            host_ip = tap_ctx.host_ip
            log("TAP", f"Bridged fornax0 (host={host_ip})")

            qemu = QemuDriver(
                fw, esp_dir, disk_img, smp=4, memory="4G", arch="x86_64",
                tap_iface="fornax0",
            )
            qemu.start()
            log("QEMU", "Booting x86_64 (smp=4, TAP+bridge)...")

            # Wait for login
            qemu.expect(r"fornax login:", timeout=120)
            qemu.send_line("root")
            qemu.expect(r"root@fornax", timeout=15)
            log("BOOT", "Logged in")

            # Wait for network
            log("NET", "Waiting for network...")
            net_up = False
            for attempt in range(15):
                marker = f"__NET{attempt}__"
                qemu.send_line(f"cat /net/status; echo {marker}")
                qemu.expect(rf"{marker}\r?\n", timeout=10)
                log_tail = qemu.full_log[-2048:].decode(errors="replace")
                for line in log_tail.splitlines():
                    stripped = line.strip()
                    if stripped.startswith("ip "):
                        ip = stripped.split()[1]
                        if ip != "0.0.0.0":
                            log("NET", f"Network up: {ip}")
                            net_up = True
                            break
                if net_up:
                    break
                time.sleep(2)
            if not net_up:
                raise RuntimeError("Network did not come up (no IP after 30s)")

            # Ping gateway to warm ARP
            qemu.send_cmd(f"ping -c 1 {host_ip}", timeout=15)
            log("NET", "Gateway reachable")

            # --- Run iperf3 tests (serial muted) ---
            log("IPERF", f"Starting container benchmark ({duration}s x {runs} runs)...")

            results = []

            for run_num in range(1, runs + 1):
                # Start iperf3 server on host (one-shot mode)
                actual_port = port + run_num - 1
                iperf_srv = subprocess.Popen(
                    ["iperf3", "-s", "-p", str(actual_port), "-1"],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                )
                time.sleep(1.0)

                # Run iperf3 inside container
                start_marker = f"__CSTART{run_num}__"
                end_marker = f"__CDONE{run_num}__"
                fnx_cmd = (
                    f"fnx run --compat linux --name iperf-run{run_num} iperf3bench "
                    f"/usr/bin/iperf3 -c {host_ip} -p {actual_port} -t {duration}"
                )
                send_line_quiet(qemu, f"echo {start_marker}; {fnx_cmd}; echo {end_marker}")

                # Wait for completion. The guest may not self-terminate if its
                # timer thread fails (no select/timer support yet), so use a
                # bounded timeout and fall back to host-side throughput data.
                timed_out = False
                try:
                    expect_quiet(qemu, rf"{end_marker}\r?\n", timeout=duration + 30)
                except TimeoutError:
                    timed_out = True
                    # Guest hung — send shutdown to force TCP connection drop
                    # so the host iperf3 server exits with collected data.
                    try:
                        send_line_quiet(qemu, "shutdown")
                        time.sleep(2)
                    except Exception:
                        pass

                # Wait for host iperf3 server to finish
                host_output = ""
                try:
                    iperf_srv.wait(timeout=15)
                    host_output = iperf_srv.stdout.read().decode(errors="replace")
                except subprocess.TimeoutExpired:
                    iperf_srv.terminate()
                    try:
                        iperf_srv.wait(timeout=5)
                        host_output = iperf_srv.stdout.read().decode(errors="replace")
                    except Exception:
                        pass

                # Extract guest-side output from serial log
                guest_output = ""
                if qemu.full_log:
                    text = qemu.full_log.decode(errors="replace")
                    idx = text.rfind(start_marker)
                    end = text.rfind(end_marker)
                    if idx >= 0 and end > idx:
                        guest_output = text[idx + len(start_marker):end]

                # Parse throughput — prefer host receiver, fallback to guest sender
                host_mbps, host_role = parse_iperf3_output(host_output)
                guest_mbps, guest_role = parse_iperf3_output(guest_output)

                if timed_out and host_mbps is not None:
                    # Guest didn't terminate cleanly (timer thread issue)
                    # but host confirms data flowed — count as partial success
                    results.append({
                        "status": "OK",
                        "mbps": host_mbps,
                        "source": f"host-{host_role}",
                        "note": "guest timeout (timer thread)",
                        "host_output": host_output,
                        "guest_output": guest_output,
                    })
                elif timed_out:
                    results.append({
                        "status": "TIMEOUT",
                        "host_output": host_output,
                        "guest_output": guest_output,
                    })
                elif host_mbps is not None:
                    results.append({
                        "status": "OK",
                        "mbps": host_mbps,
                        "source": f"host-{host_role}",
                        "host_output": host_output,
                        "guest_output": guest_output,
                    })
                elif guest_mbps is not None:
                    results.append({
                        "status": "OK",
                        "mbps": guest_mbps,
                        "source": f"guest-{guest_role}",
                        "host_output": host_output,
                        "guest_output": guest_output,
                    })
                else:
                    results.append({
                        "status": "PARSE_FAIL",
                        "host_output": host_output,
                        "guest_output": guest_output,
                    })

                # Pause between runs
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

            # --- Print results table ---
            _unmute()
            out = _real_stderr
            w = 72
            print(file=out)
            print(f"{BOLD}{'='*w}{RESET}", file=out)
            print(f"{BOLD}  CONTAINER iperf3 — Alpine in Fornax (TAP+bridge, smp=4){RESET}", file=out)
            print(f"{BOLD}{'='*w}{RESET}", file=out)
            print(f"  Duration: {duration}s per run, {runs} runs", file=out)
            print(f"  Host: {host_ip}:{port}", file=out)
            if serial_log:
                print(f"  Serial log: {serial_log}", file=out)
            print(f"{'='*w}", file=out)
            print(f"  {'Run':<5} {'Status':<12} {'Mbps':>10} {'Source':<20}", file=out)
            print(f"  {'-'*50}", file=out)

            valid_mbps = []
            for i, r in enumerate(results):
                rn = i + 1
                if r["status"] == "OK":
                    valid_mbps.append(r["mbps"])
                    note = f" ({r['note']})" if r.get("note") else ""
                    print(
                        f"  {rn:<5} {GREEN}{'OK':<12}{RESET} "
                        f"{r['mbps']:>10.1f} {r['source']:<20}{note}",
                        file=out,
                    )
                elif r["status"] == "TIMEOUT":
                    print(f"  {rn:<5} {RED}{'TIMEOUT':<12}{RESET}", file=out)
                else:
                    print(f"  {rn:<5} {YELLOW}{'PARSE_FAIL':<12}{RESET}", file=out)

            print(f"  {'-'*50}", file=out)
            if valid_mbps:
                avg = sum(valid_mbps) / len(valid_mbps)
                mn = min(valid_mbps)
                mx = max(valid_mbps)
                print(f"  {'Avg':<5} {'':12} {avg:>10.1f}", file=out)
                print(f"  {'Min':<5} {'':12} {mn:>10.1f}", file=out)
                print(f"  {'Max':<5} {'':12} {mx:>10.1f}", file=out)
            else:
                print(f"  {RED}No successful runs — no throughput data{RESET}", file=out)

            # Diagnostics
            print(file=out)
            for i, r in enumerate(results):
                if r["status"] == "PARSE_FAIL":
                    print(f"  {YELLOW}Run {i+1} PARSE_FAIL — host output:{RESET}", file=out)
                    for line in (r["host_output"] or "(empty)").strip().splitlines()[-8:]:
                        print(f"    {line.strip()}", file=out)
                    print(f"  {YELLOW}Run {i+1} PARSE_FAIL — guest serial:{RESET}", file=out)
                    for line in (r["guest_output"] or "(empty)").strip().splitlines()[-8:]:
                        print(f"    {line.strip()}", file=out)

            if not valid_mbps and all(r["status"] == "TIMEOUT" for r in results):
                print(f"  {RED}All runs timed out — dumping serial log tail:{RESET}", file=out)
                tail = qemu.full_log[-4096:].decode(errors="replace")
                for line in tail.splitlines()[-30:]:
                    clean = line.strip()
                    if clean:
                        print(f"    {clean}", file=out)

            if valid_mbps:
                avg = sum(valid_mbps) / len(valid_mbps)
                if avg < 1.0:
                    print(f"  {YELLOW}DIAGNOSTIC: Very low throughput ({avg:.1f} Mbps) — "
                          f"container networking overhead may be significant{RESET}", file=out)
                else:
                    print(f"  {GREEN}DIAGNOSTIC: Container iperf3 path functional{RESET}", file=out)

            print(f"{'='*w}\n", file=out)

            return len(valid_mbps) > 0

        except (TimeoutError, RuntimeError, PermissionError) as e:
            print(f"{RED}Error: {e}{RESET}", file=sys.stderr)
            # Save serial log on failure too
            if serial_log and qemu and qemu.full_log:
                with open(serial_log, "wb") as f:
                    f.write(qemu.full_log)
                print(f"  Serial log saved to {serial_log}", file=sys.stderr)
            return False
        finally:
            if qemu is not None:
                qemu.stop()
            tap_ctx.__exit__(None, None, None)


def main():
    parser = argparse.ArgumentParser(description="Container iperf3 throughput benchmark")
    parser.add_argument("--duration", type=int, default=5,
                        help="Seconds per iperf3 run (default: 5)")
    parser.add_argument("--runs", type=int, default=3,
                        help="Number of runs (default: 3)")
    parser.add_argument("--port", type=int, default=5201,
                        help="Base TCP port for iperf3 (default: 5201)")
    parser.add_argument("--no-build", action="store_true",
                        help="Skip build step (use existing zig-out)")
    parser.add_argument("--serial-log", default=None,
                        help="Save serial log (default: /tmp/iperf-container.log)")
    args = parser.parse_args()

    if not args.no_build:
        if not build():
            return 1

    serial_log = args.serial_log or "/tmp/iperf-container.log"
    ok = run_container_iperf(args.duration, args.port, serial_log, runs=args.runs)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
