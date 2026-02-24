"""Constants, ANSI colors, logging helpers, and OVMF firmware discovery."""
import os
import sys

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# ANSI colors
GREEN = "\033[32m"
RED = "\033[31m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
RESET = "\033[0m"
BOLD = "\033[1m"

# Set by runner before each session
CURRENT_ARCH = "x86_64"
CURRENT_SESSION = ""


def log(tag, msg, color=CYAN):
    print(f"{color}[{tag}]{RESET} {msg}", file=sys.stderr, flush=True)


def log_pass(name):
    tag = f"TEST {CURRENT_ARCH}"
    print(f"{GREEN}[{tag}]{RESET} {name}... {GREEN}PASS{RESET}", file=sys.stderr, flush=True)


def log_fail(name, reason):
    tag = f"TEST {CURRENT_ARCH}"
    print(f"{RED}[{tag}]{RESET} {name}... {RED}FAIL{RESET}: {reason}", file=sys.stderr, flush=True)


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
