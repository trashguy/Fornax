"""PCI subsystem tests: lspci output, BAR sizes, multi-function devices."""
import re
from .config import log_pass, log_fail


def test_pci_enumeration(qemu):
    """Verify PCI enumeration, BAR size probing, and lspci output."""
    try:
        # 1. Run lspci and capture output
        qemu.send_line("lspci; echo __LSPCI_DONE__")
        m = qemu.expect(r"((?:.*\n)*?)__LSPCI_DONE__", timeout=15)
        output = m.group(1).decode(errors="replace")

        lines = [l.strip() for l in output.strip().splitlines() if l.strip()]
        if len(lines) < 2:
            log_fail("test_pci_enumeration", f"Too few PCI devices: {len(lines)}")
            return False

        # 2. Every line must have valid BDF format "BB:SS.F ..."
        bdf_re = re.compile(r"^[0-9a-f]{2}:[0-9a-f]{2}\.[0-7] ")
        for line in lines:
            if not bdf_re.match(line):
                log_fail("test_pci_enumeration", f"Bad BDF format: {line!r}")
                return False

        # 3. Check for expected device types (QEMU always has these)
        has_bridge = any("Host bridge" in l or "ISA bridge" in l or "PCI bridge" in l for l in lines)
        has_virtio = any("1af4:" in l.lower() for l in lines)

        if not has_bridge:
            log_fail("test_pci_enumeration", "No bridge device found")
            return False
        if not has_virtio:
            log_fail("test_pci_enumeration", "No virtio device found")
            return False

        # 4. Check that BAR sizes appear for at least one device
        bar_re = re.compile(r"BAR:\s+\d+=\d+[KMG]?")
        has_bar = any(bar_re.search(l) for l in lines)
        if not has_bar:
            log_fail("test_pci_enumeration", "No BAR sizes displayed")
            return False

        # 5. Verify /dev/pci raw output has extended format
        qemu.send_line("cat /dev/pci; echo __DEVPCI_DONE__")
        m2 = qemu.expect(r"((?:.*\n)*?)__DEVPCI_DONE__", timeout=10)
        raw = m2.group(1).decode(errors="replace")
        raw_lines = [l.strip() for l in raw.strip().splitlines() if l.strip()]

        # Each line should have BAR size block: "... [hex hex hex hex hex hex]"
        bar_block_re = re.compile(r"\[([0-9a-f]+ ){5}[0-9a-f]+\]")
        has_bar_block = any(bar_block_re.search(l) for l in raw_lines)
        if not has_bar_block:
            log_fail("test_pci_enumeration", "No BAR size blocks in /dev/pci output")
            return False

        log_pass("test_pci_enumeration")
        return True
    except (TimeoutError, RuntimeError) as e:
        log_fail("test_pci_enumeration", str(e))
        return False
