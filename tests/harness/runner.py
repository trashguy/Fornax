"""Test session orchestration, filtering, CLI args, and main entry point."""
import os
import socket
import subprocess
import sys
import tempfile

from .config import PROJECT_DIR, GREEN, RED, YELLOW, RESET, BOLD, log, find_ovmf
from .qemu import QemuDriver
from .disk import create_test_disk, prepare_rootfs, create_linux_hello_elf
from .packages import build_xxd_package, generate_repo_json, start_http_server

from .test_boot import test_boot_login, test_shutdown
from .test_core import test_basic_commands, test_time_subsystem
from .test_filesystem import test_filesystem
from .test_networking import test_host_networking
from .test_containers import (
    test_container_native,
    test_container_linux_compat,
    test_container_build,
    test_container_networking,
)
from .test_packages import test_fay_install_xxd


# ── Test session runner ──────────────────────────────────────────────

def run_test_session(session_name, ovmf, build_flags, tests, tmpdir,
                     pre_disk_hook=None, pre_test_hook=None,
                     smp=1, memory="4G"):
    """Build Fornax, create disk, boot QEMU, run tests, shutdown.

    Args:
        session_name: Display name (e.g. "core", "posix")
        ovmf: Path to OVMF firmware
        build_flags: Extra zig build flags (e.g. ["-Dposix=true"])
        tests: List of test functions to run in order
        tmpdir: Temporary directory for disk images
        pre_disk_hook: Called with (rootfs_dir) before disk creation
        pre_test_hook: Called with (qemu) before tests run (e.g. start HTTP server)
        smp: Number of QEMU vCPUs (default 1, use 4 for container tests)
        memory: QEMU memory (default "1G")

    Returns:
        (passed, failed, full_log_bytes)
    """
    passed = 0
    failed = 0
    qemu = None
    full_log = b""

    try:
        # Show session header with arch/features/config
        features = [f.replace("-D", "") for f in build_flags]
        feat_str = ", ".join(features) if features else "none"
        header = f"Session: {session_name}"
        details = f"arch=x86_64  smp={smp}  ram={memory}  features=[{feat_str}]"
        sep = "=" * max(len(header), len(details))
        log("SESSION", sep, BOLD)
        log("SESSION", header, BOLD)
        log("SESSION", details, BOLD)
        log("SESSION", sep, BOLD)

        # Build
        build_cmd = ["zig", "build", "x86_64"] + build_flags
        log("BUILD", f"Building ({' '.join(build_flags)})...")
        result = subprocess.run(
            build_cmd,
            cwd=PROJECT_DIR,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            print(f"{RED}Build failed:{RESET}\n{result.stderr}", file=sys.stderr)
            return 0, 1, b""
        log("BUILD", "OK")

        # Build host tools (only once, but harmless to repeat)
        result = subprocess.run(
            ["zig", "build", "mkgpt", "mkfxfs"],
            cwd=PROJECT_DIR,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            print(f"{RED}Host tools build failed:{RESET}\n{result.stderr}", file=sys.stderr)
            return 0, 1, b""

        # Prepare rootfs and disk
        rootfs_dir = os.path.join(PROJECT_DIR, "zig-out", "rootfs")
        prepare_rootfs(rootfs_dir)

        if pre_disk_hook:
            pre_disk_hook(rootfs_dir)

        disk_subdir = os.path.join(tmpdir, f"disk-{session_name}")
        os.makedirs(disk_subdir, exist_ok=True)
        disk_img = create_test_disk(disk_subdir, rootfs_dir)
        log("DISK", "OK")

        # Boot QEMU
        esp_dir = os.path.join(PROJECT_DIR, "zig-out", "esp")
        qemu = QemuDriver(ovmf, esp_dir, disk_img, smp=smp, memory=memory)
        qemu.start()
        log("QEMU", f"Starting Fornax ({session_name}, {smp} cores, {memory} RAM, {qemu._accel})...")

        if pre_test_hook:
            pre_test_hook(qemu)

        # Run tests sequentially, stop on first failure
        for test_fn in tests:
            if failed > 0:
                break
            if test_fn(qemu):
                passed += 1
            else:
                failed += 1

        full_log = qemu.full_log

    except KeyboardInterrupt:
        raise  # propagate to main
    except Exception as e:
        print(f"{RED}Session {session_name} error: {e}{RESET}", file=sys.stderr)
        failed += 1
    finally:
        if qemu:
            qemu.stop()

    log("SESSION", f"{session_name}: {passed} passed, {failed} failed\n")
    return passed, failed, full_log


# ── Test registry ────────────────────────────────────────────────────

ALL_TESTS = {
    "boot": test_boot_login,
    "basic": test_basic_commands,
    "time": test_time_subsystem,
    "networking": test_host_networking,
    "filesystem": test_filesystem,
    "fay": test_fay_install_xxd,
    "container_native": test_container_native,
    "container_linux": test_container_linux_compat,
    "container_build": test_container_build,
    "container_net": test_container_networking,
    "shutdown": test_shutdown,
}


def parse_args():
    """Parse CLI arguments: --filter, --session, --list."""
    import argparse
    p = argparse.ArgumentParser(description="Fornax integration tests")
    p.add_argument("--filter", "-f", help="Comma-separated test names or substring (e.g. 'container' or 'container_native,container_net')")
    p.add_argument("--session", "-s", choices=["core", "posix", "all"], default="all", help="Which session to run (default: all)")
    p.add_argument("--smp", type=int, default=4, help="Number of QEMU vCPUs (default: 4)")
    p.add_argument("--list", "-l", action="store_true", help="List available test names and exit")
    return p.parse_args()


def filter_tests(tests, filter_str):
    """Filter test list by comma-separated names or substring match.

    boot and shutdown are always included to ensure the VM boots/halts.
    """
    if not filter_str:
        return tests

    # Resolve filter terms to test function names
    terms = [t.strip() for t in filter_str.split(",")]
    keep = set()
    for fn in tests:
        name = fn.__name__
        for term in terms:
            # Match by dict key (short name) or substring of function name
            short = name.replace("test_", "")
            if term == short or term in name:
                keep.add(name)

    # Always include boot/shutdown so the VM comes up and goes down
    result = []
    for fn in tests:
        name = fn.__name__
        if name in keep or name in ("test_boot_login", "test_shutdown"):
            result.append(fn)
    return result


# ── Main ─────────────────────────────────────────────────────────────

def main():
    cli = parse_args()

    if cli.list:
        for name in ALL_TESTS:
            print(f"  {name:20s}  {ALL_TESTS[name].__doc__.split(chr(10))[0]}")
        return 0

    total_passed = 0
    total_failed = 0
    last_log = b""

    try:
        # 1. Find OVMF
        ovmf = find_ovmf()
        if not ovmf:
            print(f"{RED}Error: Could not find OVMF firmware.{RESET}", file=sys.stderr)
            print("Install with: pacman -S edk2-ovmf (Arch) / apt install ovmf (Debian)", file=sys.stderr)
            return 1
        log("SETUP", f"OVMF: {ovmf}")

        # 2. Check port 8000 availability
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind(("0.0.0.0", 8000))
            sock.close()
        except OSError:
            print(f"{RED}Error: Port 8000 is already in use.{RESET}", file=sys.stderr)
            print("Stop the process using port 8000 and try again.", file=sys.stderr)
            return 1

        def stage_linux_elf(rootfs_dir):
            """Stage minimal Linux hello ELF for container compat test."""
            tmp_dir = os.path.join(rootfs_dir, "tmp")
            os.makedirs(tmp_dir, exist_ok=True)
            path = os.path.join(tmp_dir, "hello-linux")
            with open(path, "wb") as f:
                f.write(create_linux_hello_elf())
            os.chmod(path, 0o755)
            log("CONTAINER", "Staged hello-linux ELF")

        with tempfile.TemporaryDirectory(prefix="fornax-test-") as tmpdir:

            core_tests = filter_tests([
                test_boot_login,
                test_basic_commands,
                test_time_subsystem,
                test_host_networking,
                test_filesystem,
                test_container_native,
                test_container_linux_compat,
                test_container_build,
                test_container_networking,
                test_shutdown,
            ], cli.filter)

            posix_tests = filter_tests([
                test_boot_login,
                test_basic_commands,
                test_time_subsystem,
                test_host_networking,
                test_fay_install_xxd,
                test_filesystem,
                test_container_native,
                test_container_linux_compat,
                test_container_build,
                test_container_networking,
                test_shutdown,
            ], cli.filter)

            smp = cli.smp
            run_core = cli.session in ("core", "all")
            run_posix = cli.session in ("posix", "all")

            # ── Session 1: Core + Containers (no POSIX) ──────────
            if run_core:
                p, f, log_data = run_test_session(
                    "core",
                    ovmf,
                    ["-Dcontainers=true"],
                    core_tests,
                    tmpdir,
                    pre_disk_hook=stage_linux_elf,
                    smp=smp, memory="4G",
                )
                total_passed += p
                total_failed += f
                if log_data:
                    last_log = log_data

            if total_failed > 0:
                log("SESSION", "Core session failed, skipping POSIX session", RED)
                run_posix = False

            if run_posix:
                # ── Session 2: POSIX + Containers + Packages ─────
                # Build xxd test package
                xxd_path = os.path.join(PROJECT_DIR, "zig-out", "test-packages", "xxd")

                pkg_dir = os.path.join(tmpdir, "packages")
                os.makedirs(pkg_dir, exist_ok=True)

                http_server = None

                def setup_posix(rootfs_dir):
                    stage_linux_elf(rootfs_dir)

                def start_pkg_server(qemu):
                    nonlocal http_server
                    # Build package tarball (xxd must exist from posix build)
                    if os.path.isfile(xxd_path):
                        tarball_name, sha256_hex = build_xxd_package(xxd_path, pkg_dir)
                        generate_repo_json(pkg_dir, tarball_name, sha256_hex)
                        http_server = start_http_server(pkg_dir, port=8000)
                        log("HTTP", "Serving test packages on :8000")

                p, f, log_data = run_test_session(
                    "posix",
                    ovmf,
                    ["-Dposix=true", "-Dtest-packages=true", "-Dcontainers=true"],
                    posix_tests,
                    tmpdir,
                    pre_disk_hook=setup_posix,
                    pre_test_hook=start_pkg_server,
                    smp=smp, memory="4G",
                )
                total_passed += p
                total_failed += f
                if log_data:
                    last_log = log_data

                if http_server:
                    http_server.shutdown()

    except KeyboardInterrupt:
        print(f"\n{YELLOW}Interrupted.{RESET}", file=sys.stderr)
        total_failed += 1
    except Exception as e:
        print(f"{RED}Unexpected error: {e}{RESET}", file=sys.stderr)
        total_failed += 1

    # Summary
    print(file=sys.stderr)
    total = total_passed + total_failed
    if total_failed == 0:
        print(f"{GREEN}{BOLD}All {total_passed} tests passed.{RESET}", file=sys.stderr)
        return 0
    else:
        print(f"{RED}{BOLD}{total_failed}/{total} tests failed.{RESET}", file=sys.stderr)
        if last_log:
            log_path = os.path.join(PROJECT_DIR, "test-serial.log")
            with open(log_path, "wb") as f:
                f.write(last_log)
            print(f"Full serial log saved to: {log_path}", file=sys.stderr)
        return 1
