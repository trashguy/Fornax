"""Supervisor tests: /proc/supervisor status, ctl commands."""
from .config import log_pass, log_fail


def test_supervisor_status(qemu):
    """Verify /proc/supervisor shows registered services running."""
    try:
        # 1. Read /proc/supervisor — should show partfs and fxfs as running
        qemu.send_line("cat /proc/supervisor; echo __SV_DONE__")

        # Check for header line
        qemu.expect(r"NAME\s+PID\s+STATE", timeout=10)

        # Check partfs entry — running with 0 restarts
        qemu.expect(r"partfs\s+\d+\s+running\s+0", timeout=5)

        # Check fxfs entry — running with 0 restarts, depends on partfs
        qemu.expect(r"fxfs\s+\d+\s+running\s+0", timeout=5)

        qemu.expect(r"__SV_DONE__", timeout=5)

        # 2. Verify supervisor appears in /proc directory listing
        qemu.send_line("ls /proc; echo __LS_PROC__")
        qemu.expect(r"supervisor", timeout=10)
        qemu.expect(r"__LS_PROC__", timeout=5)

        # 3. Test "reset" ctl command (safe — just clears counters)
        qemu.send_cmd("echo reset partfs > /proc/supervisor/ctl")

        # Verify partfs is still running after reset
        qemu.send_line("cat /proc/supervisor; echo __SV_RESET__")
        qemu.expect(r"partfs\s+\d+\s+running\s+0", timeout=10)
        qemu.expect(r"__SV_RESET__", timeout=5)

        log_pass("test_supervisor_status")
        return True
    except (TimeoutError, RuntimeError) as e:
        log_fail("test_supervisor_status", str(e))
        return False
