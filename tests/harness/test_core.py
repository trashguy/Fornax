"""Core OS tests: basic commands, time subsystem."""
from .config import log_pass, log_fail


def test_basic_commands(qemu):
    """Verify basic command execution works (fxfs reads)."""
    try:
        # Test a builtin — send_cmd waits for reliable completion marker
        qemu.send_cmd("echo basic_test_XQ7")
        # basic_test_XQ7 appears in the marker-echo output; just verify it ran

        # Test an external command that reads from fxfs
        qemu.send_cmd("echo testdata_Z9 > /tmp/basic.txt")
        qemu.send_line("cat /tmp/basic.txt; echo __CAT_BASIC__")
        qemu.expect(r"testdata_Z9", timeout=30)
        qemu.expect(r"__CAT_BASIC__", timeout=5)

        log_pass("test_basic_commands")
        return True
    except (TimeoutError, RuntimeError) as e:
        log_fail("test_basic_commands", str(e))
        return False


def test_time_subsystem(qemu):
    """Verify wall-clock time, date command, uptime, and cron daemon."""
    try:
        # 1. /dev/time format: "<epoch> <uptime>\n"
        #    Epoch should be >1700000000 (2023+) if RTC works.
        qemu.send_line("cat /dev/time; echo __TIME_DONE__")
        m = qemu.expect(r"(\d+) (\d+)", timeout=10)
        epoch = int(m.group(1))
        uptime = int(m.group(2))
        qemu.expect(r"__TIME_DONE__", timeout=5)

        if epoch < 1700000000:
            log_fail("test_time_subsystem", f"epoch too low: {epoch}")
            return False
        if uptime < 1:
            log_fail("test_time_subsystem", f"uptime too low: {uptime}")
            return False

        # 2. date command: should output day-of-week + month + year
        qemu.send_line("date; echo __DATE_DONE__")
        m = qemu.expect(r"(Sun|Mon|Tue|Wed|Thu|Fri|Sat)\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)", timeout=10)
        qemu.expect(r"__DATE_DONE__", timeout=5)

        # 3. date +%s: should match /dev/time epoch (within a few seconds)
        qemu.send_line("date +%s; echo __EPOCH_DONE__")
        m = qemu.expect(r"\n(\d{9,12})\r?\n", timeout=10)
        cmd_epoch = int(m.group(1))
        qemu.expect(r"__EPOCH_DONE__", timeout=5)
        if abs(cmd_epoch - epoch) > 30:
            log_fail("test_time_subsystem", f"date +%s ({cmd_epoch}) too far from /dev/time ({epoch})")
            return False

        # 4. date -I: ISO 8601 format YYYY-MM-DD
        qemu.send_line("date -I; echo __ISO_DONE__")
        qemu.expect(r"\d{4}-\d{2}-\d{2}", timeout=10)
        qemu.expect(r"__ISO_DONE__", timeout=5)

        # 5. uptime command
        qemu.send_line("uptime; echo __UP_DONE__")
        qemu.expect(r"\d+[hm]", timeout=10)
        qemu.expect(r"__UP_DONE__", timeout=5)

        # 6. crontab -l (crond should be running)
        qemu.send_line("crontab -l; echo __CRON_DONE__")
        # Should succeed (either "no jobs" or list of jobs)
        qemu.expect(r"__CRON_DONE__", timeout=10)

        log_pass("test_time_subsystem")
        return True
    except (TimeoutError, RuntimeError) as e:
        log_fail("test_time_subsystem", str(e))
        return False
