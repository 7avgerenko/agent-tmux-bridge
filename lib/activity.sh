#!/usr/bin/env bash
# =============================================================================
# activity.sh -- Activity state machine for agent-tmux-bridge
# =============================================================================
#
# This is the core logic that determines whether the user is actively typing.
# It combines two signals:
#   1. PROMPT_COMMAND timestamps (from shell integration) -- tells us when
#      a new prompt appeared (i.e., a command finished executing)
#   2. Cursor position polling -- tells us if something is moving the cursor
#
# By combining both, we can distinguish user typing (cursor moves while at
# prompt) from system output (cursor moves while a command is running).
# =============================================================================

# Activity state (runtime, not exported)
ACTIVITY_CURSOR_X=0
ACTIVITY_CURSOR_Y=0
ACTIVITY_CURSOR_PREV_X=0
ACTIVITY_CURSOR_PREV_Y=0
ACTIVITY_PROMPT_TIME=0
ACTIVITY_PROMPT_TIME_PREV=0
ACTIVITY_LAST_USER_ACTIVITY=0       # nanosecond timestamp
ACTIVITY_USER_AT_PROMPT=false
ACTIVITY_INITIALIZED=false

# Initialize activity state from current values
activity_init() {
    local cursor
    cursor=$(read_cursor)
    ACTIVITY_CURSOR_X=$(echo "$cursor" | awk '{print $1}')
    ACTIVITY_CURSOR_Y=$(echo "$cursor" | awk '{print $2}')
    ACTIVITY_CURSOR_PREV_X=$ACTIVITY_CURSOR_X
    ACTIVITY_CURSOR_PREV_Y=$ACTIVITY_CURSOR_Y
    ACTIVITY_PROMPT_TIME=$(read_prompt_timestamp)
    ACTIVITY_PROMPT_TIME_PREV=$ACTIVITY_PROMPT_TIME

    # Set initial state: assume at prompt if shell integration is active
    if is_shell_integration_active; then
        ACTIVITY_USER_AT_PROMPT=true
    else
        ACTIVITY_USER_AT_PROMPT=false
    fi

    # Initialize activity timestamp to now (allow immediate use)
    ACTIVITY_LAST_USER_ACTIVITY=$(date +%s%N 2>/dev/null || echo 0)

    ACTIVITY_INITIALIZED=true
}

# Main update function -- called each poll cycle
# Arguments: cursor_x cursor_y prompt_time agent_active_flag now_ns
activity_update() {
    local cx="$1"
    local cy="$2"
    local pt="$3"
    local agent_active="$4"
    local now_ns="$5"

    if [ "$ACTIVITY_INITIALIZED" != "true" ]; then
        activity_init
        return
    fi

    # --- Signal 1: New prompt detected ---
    # The shell integration writes a new timestamp every time a prompt is
    # displayed. If this value changed since last poll, a command just
    # finished and a fresh prompt appeared.
    if [ "$pt" != "$ACTIVITY_PROMPT_TIME_PREV" ] && [ "$pt" != "0" ]; then
        ACTIVITY_USER_AT_PROMPT=true
        ACTIVITY_PROMPT_TIME_PREV="$pt"
        ACTIVITY_PROMPT_TIME="$pt"
        # Reset cursor baseline to avoid false positive from prompt redraw
        ACTIVITY_CURSOR_PREV_X="$cx"
        ACTIVITY_CURSOR_PREV_Y="$cy"
        return
    fi

    ACTIVITY_PROMPT_TIME="$pt"

    # --- Signal 2: Agent is actively injecting ---
    # Don't count agent keystrokes as user activity.
    if [ "$agent_active" = "1" ] || [ "$agent_active" = "true" ]; then
        ACTIVITY_CURSOR_PREV_X="$cx"
        ACTIVITY_CURSOR_PREV_Y="$cy"
        return
    fi

    # --- Signal 3: Cursor movement ---
    local cursor_changed=false
    if [ "$cx" != "$ACTIVITY_CURSOR_PREV_X" ] || [ "$cy" != "$ACTIVITY_CURSOR_PREV_Y" ]; then
        cursor_changed=true
    fi

    if [ "$cursor_changed" = true ]; then
        if [ "$ACTIVITY_USER_AT_PROMPT" = true ]; then
            # Cursor moved while at prompt = user is typing
            ACTIVITY_LAST_USER_ACTIVITY="$now_ns"
        else
            # Cursor moved while command is running = system output
            # Do NOT update last_user_activity
            :
        fi
    fi

    # Update cursor tracking
    ACTIVITY_CURSOR_PREV_X="$cx"
    ACTIVITY_CURSOR_PREV_Y="$cy"

    # If shell integration is not active, we can't reliably distinguish
    # user typing from output. In this fallback mode, any cursor movement
    # counts as user activity (conservative).
    if ! is_shell_integration_active; then
        if [ "$cursor_changed" = true ]; then
            ACTIVITY_LAST_USER_ACTIVITY="$now_ns"
        fi
    fi
}

# Determine if the bridge is currently blocked
# Returns: "true" or "false" on stdout
activity_is_blocked() {
    local now_ns cooldown_ns last_activity elapsed_ms cooldown_ms

    now_ns=$(date +%s%N 2>/dev/null || echo 0)
    cooldown_ms="${COOLDOWN_SECONDS:-5}000"  # convert seconds to milliseconds
    cooldown_ns=$((cooldown_ms * 1000000))

    last_activity="${ACTIVITY_LAST_USER_ACTIVITY:-0}"

    if [ "$last_activity" = "0" ]; then
        echo "false"
        return
    fi

    # Calculate elapsed in nanoseconds
    elapsed_ms=$(( (now_ns - last_activity) / 1000000 ))

    if [ "$elapsed_ms" -lt "${cooldown_ms:-5000}" ]; then
        echo "true"
    else
        echo "false"
    fi
}

# Get remaining cooldown in milliseconds
activity_remaining_cooldown_ms() {
    local now_ns cooldown_ms cooldown_ns last_activity elapsed_ms remaining_ms

    now_ns=$(date +%s%N 2>/dev/null || echo 0)
    cooldown_ms="${COOLDOWN_SECONDS:-5}000"
    cooldown_ns=$((cooldown_ms * 1000000))
    last_activity="${ACTIVITY_LAST_USER_ACTIVITY:-0}"

    elapsed_ms=$(( (now_ns - last_activity) / 1000000 ))
    remaining_ms=$((cooldown_ms - elapsed_ms))

    if [ "$remaining_ms" -lt 0 ]; then
        echo "0"
    else
        echo "$remaining_ms"
    fi
}

# Write state to status file
activity_write_status() {
    if [ -z "${BRIDGE_RUN_DIR:-}" ]; then
        return
    fi

    local status_file="${BRIDGE_RUN_DIR}/daemon.status"
    local tmp_file="${status_file}.tmp.$$"

    local blocked
    blocked=$(activity_is_blocked)
    local remaining_ms
    remaining_ms=$(activity_remaining_cooldown_ms)
    local integration_active="false"
    if is_shell_integration_active; then
        integration_active="true"
    fi

    cat > "$tmp_file" <<STATUS
{
  "blocked": $blocked,
  "remaining_cooldown_ms": $remaining_ms,
  "cooldown_seconds": ${COOLDOWN_SECONDS:-5},
  "user_at_prompt": $ACTIVITY_USER_AT_PROMPT,
  "shell_integration_active": $integration_active,
  "cursor_x": $ACTIVITY_CURSOR_X,
  "cursor_y": $ACTIVITY_CURSOR_Y,
  "last_user_activity_ns": $ACTIVITY_LAST_USER_ACTIVITY,
  "last_prompt_ns": $ACTIVITY_PROMPT_TIME,
  "timestamp_ns": $(date +%s%N 2>/dev/null || echo 0)
}
STATUS

    # Atomic write
    mv "$tmp_file" "$status_file" 2>/dev/null
}
