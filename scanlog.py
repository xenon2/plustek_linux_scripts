#!/usr/bin/env python3
"""Small, consistent logging helpers for the scan pipeline."""

import os
import sys

GREEN = "\033[32m"
WHITE = "\033[37m"
RESET = "\033[0m"


def log(component, message, *, file=sys.stdout):
    if hasattr(file, "isatty") and file.isatty() and not os.environ.get("NO_COLOR"):
        line = f"{GREEN}[{component}]{WHITE} {message}{RESET}"
    else:
        line = f"[{component}] {message}"
    print(line, file=file, flush=True)


def fail(component, message):
    log(component, f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)
