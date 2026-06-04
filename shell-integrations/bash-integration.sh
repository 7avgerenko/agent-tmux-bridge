#!/usr/bin/env bash
# =============================================================================
# bash-integration.sh -- Bridge activity tracking for Bash
# =============================================================================
# Injects a PROMPT_COMMAND hook that writes a nanosecond timestamp every
# time a new prompt is displayed. The bridge daemon uses this to distinguish
# user typing (cursor moves at prompt) from command output (cursor moves
# during execution).
#
# This file is sourced by the user's shell during bridge-init.
# =============================================================================

# Guard against double-sourcing
if [ -n "${_BRIDGE_BASH_INTEGRATION_LOADED:-}" ]; then
    return 0
fi
_BRIDGE_BASH_INTEGRATION_LOADED=1

# Determine run directory (set by bridge-init via tmux environment)
if [ -z "${BRIDGE_RUN_DIR:-}" ]; then
    # Try to find from tmux environment
    BRIDGE_RUN_DIR=$(tmux show-environment -g BRIDGE_RUN_DIR 2>/dev/null | cut -d= -f2)
fi

if [ -z "${BRIDGE_RUN_DIR:-}" ]; then
    # Last resort: guess from session name
    _bridge_session=$(tmux display-message -p '#{session_name}' 2>/dev/null)
    BRIDGE_RUN_DIR="/tmp/bridge/${_bridge_session}"
fi

# Ensure run directory exists
mkdir -p "$BRIDGE_RUN_DIR" 2>/dev/null

# The hook function that records prompt timestamps
_bridge_prompt_hook() {
    # Write nanosecond timestamp
    date +%s%N > "$BRIDGE_RUN_DIR/last_prompt" 2>/dev/null || true
}

# Append our hook to PROMPT_COMMAND, preserving any existing hooks
if [ -z "${PROMPT_COMMAND:-}" ]; then
    PROMPT_COMMAND="_bridge_prompt_hook"
elif ! echo "$PROMPT_COMMAND" | grep -q "_bridge_prompt_hook"; then
    PROMPT_COMMAND="${PROMPT_COMMAND}; _bridge_prompt_hook"
fi

# Also set up a DEBUG trap to detect when commands start executing
# (cursor movement during execution = system output, not user typing)
_bridge_debug_trap() {
    # Write a marker that we're executing a command (not at prompt)
    date +%s%N > "$BRIDGE_RUN_DIR/last_command_start" 2>/dev/null || true
}
# Only set DEBUG trap if not already using it heavily
if [ -z "${_BRIDGE_DEBUG_TRAP_SET:-}" ]; then
    trap '_bridge_debug_trap' DEBUG 2>/dev/null || true
    _BRIDGE_DEBUG_TRAP_SET=1
fi

# Cleanup marker
_bridge_init_ts=$(date +%s%N 2>/dev/null || echo 0)
echo "$_bridge_init_ts" > "$BRIDGE_RUN_DIR/last_prompt" 2>/dev/null || true
