"""SMP stress tests: concurrent pipes, fork storms, parallel IPC."""
from .config import log_pass, log_fail


def test_smp_stress(qemu):
    """Run SMP stress tests (pipes, IPC, fork/exit under concurrent load)."""
    try:
        # 1. Run the native smp-test program (pipe churn, IPC file stress, etc.)
        qemu.send_line("smp-test; echo __SMP_DONE__")
        qemu.expect(r"ALL PASSED", timeout=60)
        qemu.expect(r"__SMP_DONE__", timeout=5)

        # 2. Pipeline stress: concurrent pipes across cores
        #    Each iteration: echo → cat → cat → wc -c (3 pipes, 4 processes)
        for i in range(5):
            marker = f"__PIPE{i}__"
            qemu.send_line(f"echo test_data_{i} | cat | wc -c; echo {marker}")
            qemu.expect(r"\d+", timeout=15)
            qemu.expect(marker, timeout=5)

        # 3. Fork storm: rapid process creation and destruction
        #    Each echo spawns a child (fsh → echo), tests process table churn
        qemu.send_cmd(
            "for i in 1 2 3 4 5 6 7 8 9 10; do echo $i > /dev/null; done"
        )

        # 4. Concurrent file I/O through fxfs IPC
        qemu.send_cmd("echo aaa > /tmp/smp_a")
        qemu.send_cmd("echo bbb > /tmp/smp_b")
        qemu.send_cmd("echo ccc > /tmp/smp_c")
        qemu.send_line("cat /tmp/smp_a /tmp/smp_b /tmp/smp_c; echo __FCAT__")
        qemu.expect(r"aaa", timeout=10)
        qemu.expect(r"bbb", timeout=10)
        qemu.expect(r"ccc", timeout=10)
        qemu.expect(r"__FCAT__", timeout=5)

        # 5. Verify process table isn't exhausted after all that churn
        qemu.send_line("ps > /dev/null; echo __PS_OK__")
        qemu.expect(r"__PS_OK__", timeout=10)

        # Cleanup
        qemu.send_cmd("rm -f /tmp/smp_a /tmp/smp_b /tmp/smp_c")

        log_pass("test_smp_stress")
        return True
    except (TimeoutError, RuntimeError) as e:
        log_fail("test_smp_stress", str(e))
        return False
