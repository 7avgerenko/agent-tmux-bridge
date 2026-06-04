#!/usr/bin/env bash
# =============================================================================
# require-confirm.sh -- Wrap command in interactive confirmation prompt
# =============================================================================
# Instead of blocking, wraps the command so the user must type "y" to execute.
#
# Usage:
#   Template mode:  VALIDATOR="./config/sanitizers/require-confirm.sh {}"
#   Stdin mode:     VALIDATOR="stdin:./config/sanitizers/require-confirm.sh"
#
# The command is transformed into:
#   read -p "Run '<command>'? [y/N] " && [ "$REPLY" = "y" ] && <command>
# =============================================================================

cmd="${1:-$(cat)}"

# Escape single quotes for the prompt string
escaped_cmd="${cmd//\'/\'\\\'\'}"

# Wrap in confirmation — the bridge types THIS into the user's shell
echo "read -p \$'Run \\\\\\047${escaped_cmd}\\\\\\047? [y/N] ' -r _bridge_reply && [ \"\$_bridge_reply\" = \"y\" ] && $cmd"

exit 0
