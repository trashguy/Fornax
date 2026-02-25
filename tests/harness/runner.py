"""Test session orchestration, filtering, CLI args, and main entry point."""
import os
import socket
import subprocess
import sys
import tempfile

from . import config
from .config import (PROJECT_DIR, GREEN, RED, YELLOW, RESET, BOLD, log, find_ovmf,
                      find_aavmf, progress_init, progress_set_test,
                      progress_advance, progress_skip, progress_cleanup)
from .qemu import QemuDriver
from .disk import (create_test_disk, prepare_rootfs, create_linux_hello_elf,
                    create_linux_hello_elf_riscv64, create_linux_hello_elf_aarch64)
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
    test_container_pull,
    test_container_pull_real,
    test_container_pull_dockerhub,
)
from .test_smp import test_smp_stress
from .test_supervisor import test_supervisor_status
from .test_packages import test_fay_install_xxd
from .registry import (
    start_mock_registry,
    docker_available,
    start_real_registry,
    stop_real_registry,
)


# ── Test session runner ──────────────────────────────────────────────

def run_test_session(session_name, ovmf, build_flags, tests, tmpdir,
                     pre_disk_hook=None, pre_test_hook=None,
                     smp=1, memory="4G", arch="x86_64"):
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
        arch: Target architecture (default "x86_64")

    Returns:
        (passed, failed, full_log_bytes)
    """
    passed = 0
    failed = 0
    qemu = None
    full_log = b""

    # Set arch/session for test log output
    config.CURRENT_ARCH = arch
    config.CURRENT_SESSION = session_name

    try:
        # Show session header with arch/features/config
        features = [f.replace("-D", "") for f in build_flags]
        feat_str = ", ".join(features) if features else "none"
        header = f"Session: {session_name}"
        details = f"arch={arch}  smp={smp}  ram={memory}  features=[{feat_str}]"
        sep = "=" * max(len(header), len(details))
        log("SESSION", sep, BOLD)
        log("SESSION", header, BOLD)
        log("SESSION", details, BOLD)
        log("SESSION", sep, BOLD)

        # Build
        build_target = {"aarch64": "aarch64", "riscv64": "riscv64"}.get(arch, "x86_64")
        build_cmd = ["zig", "build", build_target] + build_flags
        log("BUILD", f"Building {build_target} ({' '.join(build_flags)})...")
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
        rootfs_suffix = {"aarch64": "-aarch64", "riscv64": "-riscv64"}.get(arch, "")
        rootfs_dir = os.path.join(PROJECT_DIR, "zig-out", f"rootfs{rootfs_suffix}")
        prepare_rootfs(rootfs_dir)

        if pre_disk_hook:
            pre_disk_hook(rootfs_dir)

        disk_subdir = os.path.join(tmpdir, f"disk-{session_name}")
        os.makedirs(disk_subdir, exist_ok=True)
        disk_img = create_test_disk(disk_subdir, rootfs_dir)
        log("DISK", "OK")

        # Boot QEMU
        esp_suffix = {"aarch64": "-aarch64"}.get(arch, "")
        esp_dir = os.path.join(PROJECT_DIR, "zig-out", f"esp{esp_suffix}")
        extra_kw = {}
        if arch == "riscv64":
            extra_kw["kernel"] = os.path.join(PROJECT_DIR, "zig-out", "esp-riscv64", "fornax-riscv64")
            extra_kw["initrd"] = os.path.join(PROJECT_DIR, "zig-out", "esp-riscv64", "INITRD")
        qemu = QemuDriver(ovmf, esp_dir, disk_img, smp=smp, memory=memory, arch=arch, **extra_kw)
        qemu.start()
        log("QEMU", f"Starting Fornax ({session_name}, {smp} cores, {memory} RAM, {qemu._accel})...")

        if pre_test_hook:
            pre_test_hook(qemu)

        # Run tests sequentially, stop on first failure
        for i, test_fn in enumerate(tests):
            if failed > 0:
                # Skip remaining tests in this session
                remaining = len(tests) - i
                progress_skip(remaining)
                break
            test_name = test_fn.__name__.replace("test_", "")
            progress_set_test(session_name, test_name)
            if test_fn(qemu):
                passed += 1
                progress_advance(True)
            else:
                failed += 1
                progress_advance(False)

        full_log = qemu.full_log

    except KeyboardInterrupt:
        raise  # propagate to main
    except Exception as e:
        print(f"{RED}Session {session_name} error: {e}{RESET}", file=sys.stderr)
        failed += 1
    finally:
        if qemu:
            qemu.stop()
        # Clean up disk image to free space for subsequent sessions
        import shutil
        if os.path.isdir(disk_subdir):
            shutil.rmtree(disk_subdir, ignore_errors=True)

    log("SESSION", f"{session_name}: {passed} passed, {failed} failed\n")
    return passed, failed, full_log


# ── Test registry ────────────────────────────────────────────────────

ALL_TESTS = {
    "boot": test_boot_login,
    "basic": test_basic_commands,
    "supervisor": test_supervisor_status,
    "time": test_time_subsystem,
    "networking": test_host_networking,
    "filesystem": test_filesystem,
    "smp": test_smp_stress,
    "fay": test_fay_install_xxd,
    "container_native": test_container_native,
    "container_linux": test_container_linux_compat,
    "container_build": test_container_build,
    "container_net": test_container_networking,
    "container_pull": test_container_pull,
    "container_pull_real": test_container_pull_real,
    "container_pull_dockerhub": test_container_pull_dockerhub,
    "shutdown": test_shutdown,
}


def parse_args():
    """Parse CLI arguments: --filter, --session, --list."""
    import argparse
    p = argparse.ArgumentParser(description="Fornax integration tests")
    p.add_argument("--filter", "-f", help="Comma-separated test names or substring (e.g. 'container' or 'container_native,container_net')")
    p.add_argument("--session", "-s", choices=["core", "posix", "aarch64", "riscv64", "all"], default="all", help="Which session to run (default: all)")
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

        # 2. Check port availability (8000 for packages, 5000 for OCI registry)
        for check_port in [8000, 5000]:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                sock.bind(("0.0.0.0", check_port))
                sock.close()
            except OSError:
                print(f"{RED}Error: Port {check_port} is already in use.{RESET}", file=sys.stderr)
                print(f"Stop the process using port {check_port} and try again.", file=sys.stderr)
                return 1

        def make_stage_linux_elf(arch="x86_64"):
            """Return a pre_disk_hook that stages the correct arch's Linux ELF."""
            def stage_linux_elf(rootfs_dir):
                tmp_dir = os.path.join(rootfs_dir, "tmp")
                os.makedirs(tmp_dir, exist_ok=True)
                path = os.path.join(tmp_dir, "hello-linux")
                elf_builders = {
                    "x86_64": create_linux_hello_elf,
                    "riscv64": create_linux_hello_elf_riscv64,
                    "aarch64": create_linux_hello_elf_aarch64,
                }
                builder = elf_builders.get(arch, create_linux_hello_elf)
                with open(path, "wb") as f:
                    f.write(builder())
                os.chmod(path, 0o755)
                log("CONTAINER", f"Staged hello-linux ELF ({arch})")
            return stage_linux_elf

        with tempfile.TemporaryDirectory(prefix="fornax-test-") as tmpdir:

            # Start mock OCI registry (always available)
            registry_server = start_mock_registry(port=5000)
            log("REGISTRY", "Mock OCI registry on :5000")

            # Start real registry if podman/docker is available
            has_real_registry = False
            if docker_available():
                log("REGISTRY", "Container engine detected, starting real registry:2...")
                has_real_registry = start_real_registry(port=5001)
                if not has_real_registry:
                    log("REGISTRY", "Real registry setup failed, skipping real pull test", YELLOW)
            else:
                log("REGISTRY", "No container engine (podman/docker), skipping real pull test", YELLOW)

            core_tests_list = [
                test_boot_login,
                test_basic_commands,
                test_supervisor_status,
                test_time_subsystem,
                test_host_networking,
                test_filesystem,
                test_smp_stress,
                test_container_native,
                test_container_linux_compat,
                test_container_build,
                test_container_networking,
                test_container_pull,
                test_container_pull_dockerhub,
            ]
            if has_real_registry:
                core_tests_list.append(test_container_pull_real)
            core_tests_list.append(test_shutdown)
            core_tests = filter_tests(core_tests_list, cli.filter)

            posix_tests_list = [
                test_boot_login,
                test_basic_commands,
                test_supervisor_status,
                test_time_subsystem,
                test_host_networking,
                test_fay_install_xxd,
                test_filesystem,
                test_smp_stress,
                test_container_native,
                test_container_linux_compat,
                test_container_build,
                test_container_networking,
                test_container_pull,
            ]
            if has_real_registry:
                posix_tests_list.append(test_container_pull_real)
            posix_tests_list.append(test_shutdown)
            posix_tests = filter_tests(posix_tests_list, cli.filter)

            aa64_tests_list = [
                test_boot_login,
                test_basic_commands,
                test_supervisor_status,
                test_time_subsystem,
                test_host_networking,
                test_filesystem,
                test_container_native,
                test_container_linux_compat,
                test_container_build,
                test_container_networking,
                test_container_pull,
                test_shutdown,
            ]
            aa64_tests = filter_tests(aa64_tests_list, cli.filter)

            rv64_tests_list = [
                test_boot_login,
                test_basic_commands,
                test_supervisor_status,
                test_time_subsystem,
                test_host_networking,
                test_filesystem,
                test_container_native,
                test_container_linux_compat,
                test_container_build,
                test_container_networking,
                test_container_pull,
                test_shutdown,
            ]
            rv64_tests = filter_tests(rv64_tests_list, cli.filter)

            smp = cli.smp
            run_core = cli.session in ("core", "all")
            run_posix = cli.session in ("posix", "all")
            run_aarch64 = cli.session in ("aarch64", "all")
            run_riscv64 = cli.session in ("riscv64", "all")

            # Count total tests for progress bar
            planned_total = 0
            if run_core:
                planned_total += len(core_tests)
            if run_posix:
                planned_total += len(posix_tests)
            if run_aarch64:
                planned_total += len(aa64_tests)
            if run_riscv64:
                planned_total += len(rv64_tests)
            progress_init(planned_total)

            # ── Session 1: Core + Containers + TLS ───────────────
            if run_core:
                p, f, log_data = run_test_session(
                    "core",
                    ovmf,
                    ["-Dcontainers=true", "-Dtls=true"],
                    core_tests,
                    tmpdir,
                    pre_disk_hook=make_stage_linux_elf("x86_64"),
                    smp=smp, memory="4G",
                )
                total_passed += p
                total_failed += f
                if log_data:
                    last_log = log_data

            if total_failed > 0:
                log("SESSION", "Core session failed, skipping POSIX session", RED)
                if run_posix:
                    progress_skip(len(posix_tests))
                run_posix = False

            if run_posix:
                # ── Session 2: POSIX + Containers + Packages ─────
                # Build xxd test package
                xxd_path = os.path.join(PROJECT_DIR, "zig-out", "test-packages", "xxd")

                pkg_dir = os.path.join(tmpdir, "packages")
                os.makedirs(pkg_dir, exist_ok=True)

                http_server = None

                def setup_posix(rootfs_dir):
                    make_stage_linux_elf("x86_64")(rootfs_dir)

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

            # ── Session 3: AArch64 (boot + basic) ──────────────
            if run_aarch64:
                aavmf = find_aavmf()
                if not aavmf:
                    log("SESSION", "AAVMF firmware not found, skipping aarch64 session", YELLOW)
                    progress_skip(len(aa64_tests))
                else:
                    p, f, log_data = run_test_session(
                        "aarch64",
                        aavmf,
                        ["-Dcontainers=true"],
                        aa64_tests,
                        tmpdir,
                        pre_disk_hook=make_stage_linux_elf("aarch64"),
                        smp=1, memory="4G",
                        arch="aarch64",
                    )
                    total_passed += p
                    total_failed += f
                    if log_data:
                        last_log = log_data

            # ── Session 5: RISC-V 64 (boot + basic) ─────────────
            if run_riscv64:
                import shutil
                if not shutil.which("qemu-system-riscv64"):
                    log("SESSION", "qemu-system-riscv64 not found, skipping riscv64 session", YELLOW)
                    progress_skip(len(rv64_tests))
                else:
                    p, f, log_data = run_test_session(
                        "riscv64",
                        None,  # no UEFI firmware for riscv64 (uses -bios default)
                        ["-Dcontainers=true"],
                        rv64_tests,
                        tmpdir,
                        pre_disk_hook=make_stage_linux_elf("riscv64"),
                        smp=1, memory="4G",
                        arch="riscv64",
                    )
                    total_passed += p
                    total_failed += f
                    if log_data:
                        last_log = log_data

            registry_server.shutdown()

    except KeyboardInterrupt:
        progress_cleanup()
        print(f"\n{YELLOW}Interrupted.{RESET}", file=sys.stderr)
        total_failed += 1
    except Exception as e:
        progress_cleanup()
        print(f"{RED}Unexpected error: {e}{RESET}", file=sys.stderr)
        total_failed += 1
    finally:
        # Always clean up Docker registry container if we started one
        try:
            stop_real_registry()
        except Exception:
            pass

    # Clean up progress bar before summary
    progress_cleanup()

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
