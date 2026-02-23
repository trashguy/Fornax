"""Host networking tests."""
from .config import log_pass, log_fail


def test_host_networking(qemu):
    """Verify host network stack is operational (netd running, /net/ accessible)."""
    try:
        # 1. Read /net/status — should show mac, ip, gateway
        qemu.send_line("cat /net/status; echo __NETSTATUS__")
        qemu.expect(r"mac", timeout=15)
        qemu.expect(r"__NETSTATUS__", timeout=5)

        # 2. ip command should display 10.0.2.15 (QEMU user-mode default)
        qemu.send_line("ip; echo __IP__")
        qemu.expect(r"10\.0\.2\.15", timeout=10)
        qemu.expect(r"__IP__", timeout=5)

        # 3. Verify /net/arp is readable (ARP cache)
        qemu.send_line("cat /net/arp; echo __ARP__")
        qemu.expect(r"__ARP__", timeout=10)

        log_pass("test_host_networking")
        return True
    except (TimeoutError, RuntimeError) as e:
        log_fail("test_host_networking", str(e))
        return False
