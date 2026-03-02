"""Host networking tests."""
from .config import log_pass, log_fail


def test_host_networking(qemu):
    """Verify host network stack is operational (netd running, /net/ accessible)."""
    # riscv64 TCG emulation is ~10x slower than x86_64
    slow = qemu.arch == "riscv64"
    t = lambda secs: secs * (4 if slow else 1)

    try:
        # 1. Read /net/status — should show mac, ip, gateway
        qemu.send_line("cat /net/status; echo __NETSTATUS__")
        qemu.expect(r"mac", timeout=t(15))
        qemu.expect(r"__NETSTATUS__", timeout=t(5))

        # 2. ip command should display the TAP-assigned IP
        qemu.send_line("ip; echo __IP__")
        qemu.expect(r"\d+\.\d+\.\d+\.\d+", timeout=t(10))
        qemu.expect(r"__IP__", timeout=t(5))

        # 3. Verify /net/arp is readable (ARP cache)
        qemu.send_line("cat /net/arp; echo __ARP__")
        qemu.expect(r"__ARP__", timeout=t(10))

        # 4. Ping gateway — verify ICMP echo works
        qemu.send_line(f"ping -c 2 {qemu.host_ip}; echo __PING__")
        qemu.expect(r"2 packets transmitted, 2 received", timeout=t(15))
        qemu.expect(r"__PING__", timeout=t(5))

        log_pass("test_host_networking")
        return True
    except (TimeoutError, RuntimeError) as e:
        log_fail("test_host_networking", str(e))
        return False
