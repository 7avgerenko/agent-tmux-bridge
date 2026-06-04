#!/usr/bin/env python3
"""
sanitize.py — Pre-validation command sanitizer for agent-tmux-bridge.

This is the FIRST line of defense. It runs BEFORE the validator (and even
runs when no validator is configured). It receives the command as a raw
argument via argv[1] — Python's execve-based argument passing means the
command text is NEVER interpreted by a shell. It is pure data.

WHY PYTHON (not bash):
  A bash-based sanitizer processing attacker-controlled strings has the
  same attack surface it's supposed to protect against. Bash string
  handling, grep, printf '%q', and $() command substitution all have
  edge cases with binary data, control characters, and Unicode trickery.

  Python strings are binary-safe (except null bytes which are rejected
  upfront). Argument passing via execve is immune to shell injection.
  Regex matching operates on raw bytes without shell interpretation.

CONTRACT:
  - Receives command as sys.argv[1]
  - Exit 0: command is clean (print nothing or the cleaned command)
  - Exit non-zero: command is dangerous (print reason to stderr)

USAGE:
  python3 sanitize.py "the command to check"
  echo $?  # 0 = OK, non-0 = REJECTED
"""

import sys
import os
import re


# ---------------------------------------------------------------------------
# Configuration (overridable via environment)
# ---------------------------------------------------------------------------

MAX_LENGTH = int(os.environ.get("VALIDATOR_MAX_CMD_LENGTH", "102400"))  # 100KB
BLOCK_TABS = os.environ.get("VALIDATOR_BLOCK_TABS", "") == "1"


# ---------------------------------------------------------------------------
# Character class definitions
# ---------------------------------------------------------------------------

# Control characters that are ALWAYS dangerous in a command destined for
# tmux send-keys or a shell prompt:
#
#   0x03  Ctrl+C   -> SIGINT, kills foreground process
#   0x04  Ctrl+D   -> EOF, can close the shell
#   0x08  Ctrl+H   -> Backspace, can visually hide parts of command
#   0x0C  Ctrl+L   -> Clear screen, can hide command from view
#   0x11  Ctrl+Q   -> XON, re-enable output (rare but suspicious)
#   0x13  Ctrl+S   -> XOFF, freeze terminal
#   0x1A  Ctrl+Z   -> SIGTSTP, suspend process
#   0x1B  ESC      -> ANSI escape sequence prefix
#   0x7F  DEL      -> Delete character, can visually alter command
#
# These have NO legitimate use in a command string that will be typed
# into a shell.

FORBIDDEN_CONTROL = frozenset([
    0x03, 0x04, 0x08, 0x0C, 0x11, 0x13, 0x1A, 0x1B, 0x7F
])

# Newline and carriage return are handled separately
# because they have unique attack vectors:
#   \n (0x0A) -> presses Enter in send-keys, auto-executing command
#   \r (0x0D) -> overwrites prompt line visually


def reject(reason: str) -> None:
    """Print rejection reason to stderr and exit non-zero."""
    print(f"REJECTED: {reason}", file=sys.stderr)
    sys.exit(1)


def sanitize(command: str) -> None:
    """
    Validate the command. If it passes, exit 0 (print nothing).
    If it fails, print the reason to stderr and exit non-zero.
    """

    # --- Check 1: Empty or whitespace-only ---
    if not command or not command.strip():
        reject("empty command")

    # --- Check 2: Length limit ---
    if len(command) > MAX_LENGTH:
        reject(f"command too long ({len(command)} bytes, max {MAX_LENGTH})")

    # --- Check 3: Null bytes ---
    # Python can hold null bytes in strings, but they indicate an attack.
    # No legitimate shell command contains null bytes.
    if "\x00" in command:
        reject("command contains null bytes")

    # --- Check 4: Newlines ---
    # A newline in a command would act as Enter when sent via send-keys,
    # auto-executing whatever came before the newline.
    if "\n" in command:
        reject("command contains newline characters")

    # --- Check 5: Carriage return ---
    # Can overwrite the prompt line, hiding the command from the user.
    if "\r" in command:
        reject("command contains carriage return characters")

    # --- Check 6: Forbidden control characters ---
    for i, char in enumerate(command):
        code = ord(char)
        if code in FORBIDDEN_CONTROL:
            names = {
                0x03: "Ctrl+C", 0x04: "Ctrl+D", 0x08: "Backspace",
                0x0C: "Ctrl+L", 0x11: "Ctrl+Q", 0x13: "Ctrl+S",
                0x1A: "Ctrl+Z", 0x1B: "ESC", 0x7F: "DEL"
            }
            name = names.get(code, f"0x{code:02X}")
            reject(f"command contains forbidden control character: {name} at position {i}")

    # --- Check 7: Tab characters (optional, configurable) ---
    if BLOCK_TABS and "\t" in command:
        reject("command contains tab characters (blocked by config)")

    # --- Check 8: Unicode bidi override characters ---
    # RTL override (U+202E) and similar can make malicious commands
    # appear benign in the terminal.
    bidi_chars = {
        0x202A: "LRE", 0x202B: "RLE", 0x202C: "PDF",
        0x202D: "LRO", 0x202E: "RLO", 0x2066: "LRI",
        0x2067: "RLI", 0x2068: "FSI", 0x2069: "PDI",
    }
    for i, char in enumerate(command):
        code = ord(char)
        if code in bidi_chars:
            reject(
                f"command contains Unicode bidi override: "
                f"U+{code:04X} ({bidi_chars[code]}) at position {i}"
            )

    # --- Check 9: Zero-width and invisible characters used for smuggling ---
    # These characters are invisible but can be used to embed hidden
    # commands or bypass pattern matching:
    #   U+200B  Zero-width space
    #   U+200C  Zero-width non-joiner
    #   U+200D  Zero-width joiner
    #   U+FEFF  BOM / Zero-width no-break space
    #   U+2060  Word joiner
    #   U+2061-2064  Invisible operators
    zero_width = frozenset([0x200B, 0x200C, 0x200D, 0xFEFF, 0x2060,
                            0x2061, 0x2062, 0x2063, 0x2064])
    for i, char in enumerate(command):
        code = ord(char)
        if code in zero_width:
            reject(
                f"command contains zero-width/invisible character: "
                f"U+{code:04X} at position {i}"
            )

    # --- Check 10: Homoglyph detection for shell-significant characters ---
    # Characters that look like ASCII but aren't — could bypass
    # pattern-based validators while the shell still interprets them
    # differently (or the command fails but the injection succeeded).
    # This is a WARNING threshold — we don't reject outright but we
    # note it. Users who want strict mode can enable rejection.
    homoglyph_map = {
        ord(";"): [0x037E],   # Greek question mark looks like semicolon
        ord("$"): [0xFF04],   # Fullwidth dollar sign
        ord("|"): [0xFF5C],   # Fullwidth vertical bar
        ord("`"): [0xFF40],   # Fullwidth grave accent
        ord(" "): [0x00A0],   # Non-breaking space
    }
    strict = os.environ.get("VALIDATOR_STRICT_HOMOGLYPHS", "") == "1"
    for i, char in enumerate(command):
        code = ord(char)
        for ascii_code, lookalikes in homoglyph_map.items():
            if code in lookalikes:
                if strict:
                    reject(
                        f"command contains homoglyph for '{chr(ascii_code)}': "
                        f"U+{code:04X} at position {i}"
                    )
                else:
                    # In non-strict mode, log to stderr but still allow
                    # (the shell typically won't interpret these as the
                    # ASCII equivalents anyway, so they're more of a
                    # visual spoofing concern)
                    print(
                        f"WARNING: homoglyph for '{chr(ascii_code)}': "
                        f"U+{code:04X} at position {i}",
                        file=sys.stderr
                    )

    # --- All checks passed ---
    print(command)
    sys.exit(0)


def main():
    if len(sys.argv) < 2:
        # Called with no arguments
        reject("no command provided to sanitizer")

    command = sys.argv[1]
    sanitize(command)


if __name__ == "__main__":
    main()
