#!/usr/bin/env fish
# =============================================================================
# fish-integration.sh -- Bridge activity tracking for Fish
# =============================================================================
# Uses Fish's fish_prompt event to record a timestamp each time a new prompt
# is displayed.
#
# This file is sourced by the user's shell during bridge-init.
# =============================================================================

# Guard against double-sourcing
if set -q _BRIDGE_FISH_INTEGRATION_LOADED
    return 0
end
set -g _BRIDGE_FISH_INTEGRATION_LOADED 1

# Determine run directory
if not set -q BRIDGE_RUN_DIR
    set BRIDGE_RUN_DIR (tmux show-environment -g BRIDGE_RUN_DIR 2>/dev/null | cut -d= -f2)
end

if test -z "$BRIDGE_RUN_DIR"
    set _bridge_session (tmux display-message -p '#{session_name}' 2>/dev/null)
    set BRIDGE_RUN_DIR "/tmp/bridge/$_bridge_session"
end

mkdir -p "$BRIDGE_RUN_DIR" 2>/dev/null

# Override fish_prompt to record timestamp
# Save the existing fish_prompt function if it exists
if functions -q fish_prompt
    functions -c fish_prompt _bridge_original_fish_prompt
else
    function _bridge_original_fish_prompt
        # default prompt
    end
end

# Create wrapper that calls original prompt and records timestamp
function fish_prompt
    _bridge_original_fish_prompt
    date +%s%N > "$BRIDGE_RUN_DIR/last_prompt" 2>/dev/null
end

# Also hook fish_preexec for command start detection
function _bridge_preexec --on-event fish_preexec
    date +%s%N > "$BRIDGE_RUN_DIR/last_command_start" 2>/dev/null
end

# Write initial timestamp
set _bridge_init_ts (date +%s%N 2>/dev/null || echo 0)
echo "$_bridge_init_ts" > "$BRIDGE_RUN_DIR/last_prompt" 2>/dev/null
