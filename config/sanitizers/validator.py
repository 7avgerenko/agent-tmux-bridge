#!/usr/bin/env python3
# =============================================================================
# validator.py -- Example Python validator for agent-tmux-bridge
# =============================================================================
# This is a TEMPLATE for building your own command validator in Python.
# It demonstrates the validator contract:
#   - Receives command as an argument (--input "command")
#   - Returns exit 0 = ALLOW
#   - Returns exit non-zero = REJECT
#   - Prints rejection reason to STDERR
#
# Usage with bridge:
#   VALIDATOR="./validator.py --input {}" bridge send "some command"
#
# The bridge replaces {} with the command text.
#
# You can extend this with:
#   - Shell parsing (shlex) for proper command analysis
#   - Allow/deny lists loaded from files
#   - Integration with security policies
#   - Logging of all attempted commands
#   - Rate limiting
#   - Command pattern matching
# =============================================================================

import argparse
import sys
import os
import json
from datetime import datetime


def log_attempt(command: str, allowed: bool, reason: str = "") -> None:
    """Log command attempt to a file for audit purposes."""
    log_dir = os.environ.get("BRIDGE_RUN_DIR", "/tmp/bridge/unknown")
    log_file = os.path.join(log_dir, "log", "validator.log")
    try:
        os.makedirs(os.path.dirname(log_file), exist_ok=True)
        entry = {
            "timestamp": datetime.now().isoformat(),
            "command": command,
            "allowed": allowed,
            "reason": reason,
            "session": os.environ.get("BRIDGE_SESSION", "unknown"),
        }
        with open(log_file, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except OSError:
        pass  # Logging failure should not block validation


def validate_command(command: str) -> tuple[bool, str]:
    """
    Validate a command. Returns (allowed: bool, reason: str).

    EXTEND THIS FUNCTION with your own validation logic.
    """
    # ------------------------------------------------------------------
    # Example: Block list of explicitly forbidden commands
    # ------------------------------------------------------------------
    FORBIDDEN_COMMANDS = [
        "rm -rf /",
        "mkfs.",
        "dd if=/dev/zero",
        ":(){ :|:& };:",
    ]

    for forbidden in FORBIDDEN_COMMANDS:
        if forbidden in command:
            return False, f"Forbidden command pattern: {forbidden}"

    # ------------------------------------------------------------------
    # Example: Allow list (if enabled, only these commands pass)
    # ------------------------------------------------------------------
    ALLOW_LIST_ENABLED = os.environ.get("VALIDATOR_ALLOW_LIST", "") == "1"
    ALLOWED_COMMANDS = os.environ.get("VALIDATOR_ALLOWED", "").split(":")

    if ALLOW_LIST_ENABLED and ALLOWED_COMMANDS:
        allowed = False
        for allowed_pattern in ALLOWED_COMMANDS:
            if allowed_pattern and allowed_pattern in command:
                allowed = True
                break
        if not allowed:
            return False, "Command not in allow list"

    # ------------------------------------------------------------------
    # Example: Require specific prefix
    # ------------------------------------------------------------------
    REQUIRED_PREFIX = os.environ.get("VALIDATOR_REQUIRED_PREFIX", "")
    if REQUIRED_PREFIX and not command.startswith(REQUIRED_PREFIX):
        return False, f"Command must start with: {REQUIRED_PREFIX}"

    # ------------------------------------------------------------------
    # Example: Block commands that pipe to bash/sh
    # ------------------------------------------------------------------
    DANGEROUS_PIPES = [
        "| bash",
        "| sh",
        "| zsh",
        "| /bin/bash",
        "| /bin/sh",
    ]
    for pipe_pattern in DANGEROUS_PIPES:
        if pipe_pattern in command:
            return False, f"Blocked: piping to shell interpreter ({pipe_pattern})"

    # ------------------------------------------------------------------
    # Default: allow
    # ------------------------------------------------------------------
    return True, "OK"


def main():
    parser = argparse.ArgumentParser(
        description="agent-tmux-bridge command validator"
    )
    parser.add_argument(
        "--input", "-i",
        type=str,
        required=True,
        help="Command to validate ({} in template is replaced with this)"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Validate without logging"
    )

    args = parser.parse_args()
    command = args.input

    allowed, reason = validate_command(command)

    # Log the attempt
    if not args.dry_run:
        log_attempt(command, allowed, reason)

    if allowed:
        # Output the command (can be modified if needed)
        print(command)
        sys.exit(0)
    else:
        # Reject: reason goes to stderr
        print(f"REJECTED: {reason}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
