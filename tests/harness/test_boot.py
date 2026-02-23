"""Boot and shutdown tests."""
import subprocess
import time

from .config import log_pass, log_fail


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
