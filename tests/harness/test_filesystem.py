"""Filesystem operation tests."""
import time

from .config import log_pass, log_fail


def test_filesystem(qemu):
    """Test filesystem operations: write/read files of various sizes."""
    try:
        # 1. mkdir -p for test directory
        qemu.send_cmd("mkdir -p /tmp/fstest")

        # 2. Small file: write and read back via cat
        qemu.send_cmd("echo 'fs_hello_world' > /tmp/fstest/small.txt")
        qemu.send_line("cat /tmp/fstest/small.txt; echo __CAT1__")
        qemu.expect(r"fs_hello_world", timeout=10)
        qemu.expect(r"__CAT1__", timeout=5)

        # 3. Use dd to create a 64KB file from /dev/zero, check size with wc -c
        #    Redirect wc output to a file then cat it — avoids SMP serial interleaving
        qemu.send_cmd("dd if=/dev/zero of=/tmp/fstest/medium.bin bs=4096 count=16")
        qemu.send_cmd("wc -c /tmp/fstest/medium.bin > /tmp/wc_out")
        qemu.send_line("cat /tmp/wc_out; echo __WC1__")
        qemu.expect(r"65536", timeout=10)
        qemu.expect(r"__WC1__", timeout=5)

        # 4. Larger file: 256KB
        qemu.send_cmd("dd if=/dev/zero of=/tmp/fstest/large.bin bs=4096 count=64", timeout=30)
        qemu.send_cmd("wc -c /tmp/fstest/large.bin > /tmp/wc_out")
        qemu.send_line("cat /tmp/wc_out; echo __WC2__")
        qemu.expect(r"262144", timeout=10)
        qemu.expect(r"__WC2__", timeout=5)

        # 5. Many small files in a directory
        qemu.send_cmd("mkdir /tmp/fstest/many")
        for i in range(5):
            qemu.send_cmd(f"echo content_{i} > /tmp/fstest/many/f{i}.txt")

        # Verify count with ls | wc -l
        qemu.send_cmd("ls /tmp/fstest/many | wc -l > /tmp/wc_out")
        qemu.send_line("cat /tmp/wc_out; echo __WCL__")
        qemu.expect(r"5", timeout=10)
        qemu.expect(r"__WCL__", timeout=5)

        # 6. Verify one of them reads back correctly
        qemu.send_line("cat /tmp/fstest/many/f3.txt; echo __CAT2__")
        qemu.expect(r"content_3", timeout=10)
        qemu.expect(r"__CAT2__", timeout=5)

        # 7. Rename test
        qemu.send_cmd("mv /tmp/fstest/small.txt /tmp/fstest/renamed.txt")
        qemu.send_line("cat /tmp/fstest/renamed.txt; echo __CAT3__")
        qemu.expect(r"fs_hello_world", timeout=10)
        qemu.expect(r"__CAT3__", timeout=5)

        # 8. Truncate test
        qemu.send_cmd("truncate /tmp/fstest/medium.bin 1024")
        qemu.send_cmd("wc -c /tmp/fstest/medium.bin > /tmp/wc_out")
        qemu.send_line("cat /tmp/wc_out; echo __WC3__")
        qemu.expect(r"\b1024\b", timeout=10)
        qemu.expect(r"__WC3__", timeout=5)

        # 9. Remove files
        qemu.send_cmd("rm -f /tmp/fstest/renamed.txt")
        qemu.send_cmd("rm -f /tmp/fstest/medium.bin")
        qemu.send_cmd("rm -f /tmp/fstest/large.bin")

        log_pass("test_filesystem")
        return True
    except (TimeoutError, RuntimeError) as e:
        log_fail("test_filesystem", str(e))
        return False
