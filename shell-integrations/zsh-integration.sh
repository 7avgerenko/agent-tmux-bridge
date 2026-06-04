#!/usr/bin/env zsh
# =============================================================================
# zsh-integration.sh -- Bridge activity tracking for Zsh
# =============================================================================
# Uses Zsh's precmd hook to record a nanosecond timestamp each time a new
# prompt is displayed. The bridge daemon uses this to distinguish user typing
# from command output.
#
# This file is sourced by the user's shell during bridge-init.
# =============================================================================

# Guard against double-sourcing
if (( ${+_BRIDGE_ZSH_INTEGRATION_LOADED} )); then
    return 0
fi
_BRIDGE_ZSH_INTEGRATION_LOADED=1

# Determine run directory (set by bridge-init via tmux environment)
if [[ -z "${BRIDGE_RUN_DIR:-}" ]]; then
    BRIDGE_RUN_DIR=$(tmux show-environment -g BRIDGE_RUN_DIR 2>/dev/null | cut -d= -f2)
fi

if [[ -z "${BRIDGE_RUN_DIR:-}" ]]; then
    _bridge_session=$(tmux display-message -p '#{session_name}' 2>/dev/null)
    BRIDGE_RUN_DIR="/tmp/bridge/${_bridge_session}"
fi

mkdir -p "$BRIDGE_RUN_DIR" 2>/dev/null

# The hook function that records prompt timestamps
_bridge_precmd() {
    # Write nanosecond timestamp
    date +%s%N > "$BRIDGE_RUN_DIR/last_prompt" 2>/dev/null || true
}

# Register the precmd hook using zsh's add-zsh-hook for robust chaining
autoload -Uz add-zsh-hook 2>/dev/null
if (( ${+functions[add-zsh-hook]} )); then
    add-zsh-hook precmd _bridge_precmd
else
    # Fallback: manually chain to existing precmd functions
    if [[ -z "${precmd_functions[(r)_bridge_precmd]}" ]]; then
        precmd_functions+=(_bridge_precmd)
    fi
fi

# Also set up a preexec hook to detect command start
_bridge_preexec() {
    date +%s%N > "$BRIDGE_RUN_DIR/last_command_start" 2>/dev/null || true
}

if (( ${+functions[add-zsh-hook]} )); then
    add-zsh-hook preexec _bridge_preexec
else
    if [[ -z "${preexec_functions[(r)_bridge_preexec]}" ]]; then
        preexec_functions+=(_bridge_preexec)
    fi
fi

# Write initial timestamp
_bridge_init_ts=$(date +%s%N 2>/dev/null || echo 0)
echo "$_bridge_init_ts" > "$BRIDGE_RUN_DIR/last_prompt" 2>/dev/null || true
