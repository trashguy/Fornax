"""Package manager (fay) tests."""
from .config import log_pass, log_fail, log, YELLOW


def test_fay_install_xxd(qemu):
    """Sync repo, install xxd, verify it works."""
    try:
        # Sync package database
        qemu.send_line("fay sync")
        qemu.expect(r"downloaded \d+ bytes", timeout=30)
        qemu.expect(r"root@fornax[#$] ", timeout=10)

        # Install xxd
        qemu.send_line("fay install xxd")
        qemu.expect(r"xxd 1\.0\.0-1 installed", timeout=60)
        qemu.expect(r"root@fornax[#$] ", timeout=10)

        # Verify the binary was written correctly
        qemu.send_line("wc -c < /bin/xxd; echo __WC__")
        qemu.expect(r"\d+", timeout=10)
        qemu.expect(r"__WC__", timeout=5)

        # Test xxd works: write a file, then xxd it
        qemu.send_cmd("echo hello > /tmp/xxd_test.txt")
        qemu.send_line("xxd /tmp/xxd_test.txt; echo __XXD_DONE__")
        qemu.expect(r"00000000", timeout=30)
        qemu.expect(r"__XXD_DONE__", timeout=5)

        log_pass("test_fay_install_xxd")
        return True
    except (TimeoutError, RuntimeError) as e:
        log_fail("test_fay_install_xxd", str(e))
        return False
