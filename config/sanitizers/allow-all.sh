#!/usr/bin/env bash
# =============================================================================
# allow-all.sh -- Pass-through validator (allow every command)
# =============================================================================
# This is the DEFAULT validator behavior. It allows all commands through.
#
# Can be used in template mode (receives command as $1):
#   VALIDATOR="./config/sanitizers/allow-all.sh {}"
#
# Or in legacy stdin mode:
#   VALIDATOR="stdin:./config/sanitizers/allow-all.sh"
#
# Or use the const equivalent:
#   VALIDATOR="true"    (same effect — always returns 0)
#
# Contract:
#   - Returns 0 = ALLOW
#   - Outputs the command on STDOUT (can modify it)
# =============================================================================

cmd="${1:-$(cat)}"
echo "$cmd"
exit 0
