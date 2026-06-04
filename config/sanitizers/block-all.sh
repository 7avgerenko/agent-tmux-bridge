#!/usr/bin/env bash
# =============================================================================
# block-all.sh -- Block all commands (emergency safety / read-only mode)
# =============================================================================
# This validator REJECTS every command. Use when you want the agent to
# only READ from the shell (bridge read) but never inject commands.
#
# Can be used in template mode (receives command as $1):
#   VALIDATOR="./config/sanitizers/block-all.sh {}"
#
# Or in legacy stdin mode:
#   VALIDATOR="stdin:./config/sanitizers/block-all.sh"
#
# Or use the const equivalent:
#   VALIDATOR="false"    (same effect — always returns 1)
#
# Contract:
#   - Returns non-zero = REJECT
#   - Outputs rejection reason on STDERR
# =============================================================================

cmd="${1:-$(cat)}"
echo "BLOCKED: all commands are blocked by block-all validator: $cmd" >&2
exit 1
