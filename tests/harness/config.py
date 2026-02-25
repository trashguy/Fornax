"""Constants, ANSI colors, logging helpers, and OVMF firmware discovery."""
import os
import re
import shutil
import sys

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# ANSI colors
GREEN = "\033[32m"
RED = "\033[31m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
DIM = "\033[2m"
RESET = "\033[0m"
BOLD = "\033[1m"

# Set by runner before each session
CURRENT_ARCH = "x86_64"
CURRENT_SESSION = ""


# ── Progress bar ─────────────────────────────────────────────────────
# Scroll region pins progress bar on the last row.
# Serial output is sanitized (all ANSI stripped) so it can never
# corrupt terminal state. Only clean text + \n reaches the screen.

_progress_total = 0
_progress_current = 0
_progress_passed = 0
_progress_failed = 0
_progress_session = ""
_progress_test = ""
_progress_enabled = False

# Strip all ANSI/CSI escape sequences from serial output
_ANSI_RE = re.compile(
    b"\033"           # ESC
    b"("
    b"\\[[0-9;?]*[A-Za-z]"   # CSI: ESC [ ... letter
    b"|\\][^\007]*\007"       # OSC: ESC ] ... BEL
    b"|\\([A-B0-9]"           # charset: ESC ( X
    b"|[=>NOM78cDHE]"         # simple: ESC c, ESC D, etc.
    b")"
)


def progress_init(total):
    """Initialize progress bar. Sets up terminal scroll region."""
    global _progress_total, _progress_current, _progress_passed, _progress_failed
    global _progress_enabled
    _progress_total = total
    _progress_current = 0
    _progress_passed = 0
    _progress_failed = 0
    _progress_enabled = sys.stderr.isatty() and total > 0
    if _progress_enabled:
        _setup_scroll_region()
        _render_progress()


def progress_set_test(session, test_name):
    """Update progress bar with current session and test name."""
    global _progress_session, _progress_test
    _progress_session = session
    _progress_test = test_name
    _render_progress()


def progress_advance(passed):
    """Advance progress by one test. passed=True for pass, False for fail."""
    global _progress_current, _progress_passed, _progress_failed
    _progress_current += 1
    if passed:
        _progress_passed += 1
    else:
        _progress_failed += 1
    _render_progress()


def progress_skip(count):
    """Mark tests as skipped (advances current without changing pass/fail)."""
    global _progress_current
    _progress_current += count
    _render_progress()


def progress_cleanup():
    """Remove progress bar and reset terminal scroll region."""
    global _progress_enabled
    if _progress_enabled:
        rows = shutil.get_terminal_size().lines
        sys.stderr.write(f"\033[{rows};1H\033[K\033[r")
        sys.stderr.flush()
        _progress_enabled = False


def sanitize_serial(data):
    """Strip all ANSI escape sequences from serial bytes and normalize
    line endings. Returns clean text safe for the scroll region."""
    if not _progress_enabled:
        return data
    clean = _ANSI_RE.sub(b"", data)
    # Normalize \r\n → \n, strip bare \r (cursor-home in serial)
    clean = clean.replace(b"\r\n", b"\n").replace(b"\r", b"")
    return clean


def _setup_scroll_region():
    rows = shutil.get_terminal_size().lines
    # Scroll region = rows 1..(rows-1), cursor starts at bottom of region
    sys.stderr.write(f"\033[1;{rows - 1}r\033[{rows - 1};1H")
    sys.stderr.flush()


def _render_progress():
    if not _progress_enabled or _progress_total == 0:
        return
    cols = shutil.get_terminal_size().columns
    rows = shutil.get_terminal_size().lines
    pct = _progress_current / _progress_total
    bar_width = min(30, cols - 50)
    if bar_width < 5:
        bar_width = 5
    filled = int(bar_width * pct)
    bar = "\u2588" * filled + "\u2591" * (bar_width - filled)

    counts = f"{_progress_current}/{_progress_total}"
    pct_str = f"{int(pct * 100)}%"
    status = f" [{bar}] {counts} ({pct_str})"
    if _progress_passed > 0:
        status += f"  {GREEN}\u2713{_progress_passed}{RESET}"
    if _progress_failed > 0:
        status += f"  {RED}\u2717{_progress_failed}{RESET}"
    if _progress_session:
        label = _progress_test if _progress_test else _progress_session
        arch_str = f"{CURRENT_ARCH}/" if CURRENT_ARCH else ""
        status += f"  {DIM}{arch_str}{_progress_session}: {label}{RESET}"

    # Save cursor, jump to last row, clear it, print bar, restore cursor
    sys.stderr.write(f"\033[s\033[{rows};1H\033[K{BOLD}{status}{RESET}\033[u")
    sys.stderr.flush()


# ── Logging ──────────────────────────────────────────────────────────

def log(tag, msg, color=CYAN):
    print(f"{color}[{tag}]{RESET} {msg}", file=sys.stderr, flush=True)
    _render_progress()


def log_pass(name):
    print(f"{GREEN}[TEST]{RESET} {name}... {GREEN}PASS{RESET}", file=sys.stderr, flush=True)
    _render_progress()


def log_fail(name, reason):
    print(f"{RED}[TEST]{RESET} {name}... {RED}FAIL{RESET}: {reason}", file=sys.stderr, flush=True)
    _render_progress()


# ── OVMF firmware discovery ──────────────────────────────────────────

OVMF_CANDIDATES = [
    "/usr/share/edk2/x64/OVMF_CODE.4m.fd",
    "/usr/share/edk2/x64/OVMF.4m.fd",
    "/usr/share/edk2-ovmf/x64/OVMF_CODE.fd",
    "/usr/share/OVMF/OVMF_CODE.fd",
    "/usr/share/edk2/ovmf/OVMF_CODE.fd",
    "/usr/share/qemu/OVMF.fd",
    # macOS
    "/opt/homebrew/share/qemu/edk2-x86_64-code.fd",
    "/opt/homebrew/share/OVMF/OVMF_CODE.fd",
    "/usr/local/share/qemu/edk2-x86_64-code.fd",
    "/usr/local/share/OVMF/OVMF_CODE.fd",
]


def find_ovmf():
    for path in OVMF_CANDIDATES:
        if os.path.isfile(path):
            return path
    return None


# ── AAVMF (AArch64 UEFI) firmware discovery ─────────────────────────

AAVMF_CANDIDATES = [
    # Prefer QEMU_CODE.fd (64 MB, pflash-compatible) over QEMU_EFI.fd (3 MB compact)
    "/usr/share/edk2/aarch64/QEMU_CODE.fd",
    "/usr/share/edk2/aarch64/QEMU_EFI.fd",
    "/usr/share/edk2-armvirt/aarch64/QEMU_CODE.fd",
    "/usr/share/edk2-armvirt/aarch64/QEMU_EFI.fd",
    "/usr/share/AAVMF/AAVMF_CODE.fd",
    "/usr/share/qemu-efi-aarch64/QEMU_EFI.fd",
    # macOS
    "/opt/homebrew/share/qemu/edk2-aarch64-code.fd",
    "/opt/homebrew/share/AAVMF/AAVMF_CODE.fd",
    "/usr/local/share/qemu/edk2-aarch64-code.fd",
    "/usr/local/share/AAVMF/AAVMF_CODE.fd",
]


def find_aavmf():
    for path in AAVMF_CANDIDATES:
        if os.path.isfile(path):
            return path
    return None
