#!/usr/bin/env bash
# =============================================================================
# tmux-helpers.sh -- Tmux interaction utilities for agent-tmux-bridge
# =============================================================================

# ---------------------------------------------------------------------------
# Pane discovery
# ---------------------------------------------------------------------------

# Get the user pane ID. Tries multiple strategies in order:
# 1. BRIDGE_USER_PANE env var
# 2. Pane with title "user-pane" in the bridge window
# 3. The other pane in the current window (if called from agent pane)
get_user_pane_id() {
    if [ -n "${BRIDGE_USER_PANE:-}" ]; then
        # Verify it still exists
        if tmux has-session -t "$BRIDGE_USER_PANE" 2>/dev/null || \
           tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF "$BRIDGE_USER_PANE"; then
            echo "$BRIDGE_USER_PANE"
            return 0
        fi
    fi

    # Try to find by title
    local pane
    pane=$(tmux list-panes -a -F '#{pane_id} #{pane_title}' 2>/dev/null | grep 'user-pane' | head -1 | awk '{print $1}')
    if [ -n "$pane" ]; then
        echo "$pane"
        return 0
    fi

    # Try: find the other pane in the current window
    local my_pane current_window all_panes
    my_pane=$(tmux display-message -p '#{pane_id}' 2>/dev/null)
    current_window=$(tmux display-message -p '#{window_id}' 2>/dev/null)
    if [ -n "$my_pane" ] && [ -n "$current_window" ]; then
        all_panes=$(tmux list-panes -t "$current_window" -F '#{pane_id}' 2>/dev/null)
        for pane in $all_panes; do
            if [ "$pane" != "$my_pane" ]; then
                echo "$pane"
                return 0
            fi
        done
    fi

    return 1
}

# Get the agent pane ID.
get_agent_pane_id() {
    if [ -n "${BRIDGE_AGENT_PANE:-}" ]; then
        if tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF "$BRIDGE_AGENT_PANE"; then
            echo "$BRIDGE_AGENT_PANE"
            return 0
        fi
    fi

    # Try to find by title
    local pane
    pane=$(tmux list-panes -a -F '#{pane_id} #{pane_title}' 2>/dev/null | grep 'agent-pane' | head -1 | awk '{print $1}')
    if [ -n "$pane" ]; then
        echo "$pane"
        return 0
    fi

    # If we're in a pane, assume we are the agent pane
    local my_pane
    my_pane=$(tmux display-message -p '#{pane_id}' 2>/dev/null)
    if [ -n "$my_pane" ]; then
        echo "$my_pane"
        return 0
    fi

    return 1
}

# Find pane by title
get_pane_by_title() {
    local title="$1"
    tmux list-panes -a -F '#{pane_id} #{pane_title}' 2>/dev/null | grep "$title" | head -1 | awk '{print $1}'
}

# ---------------------------------------------------------------------------
# Pane state queries
# ---------------------------------------------------------------------------

# Check if a pane exists and is alive
pane_exists() {
    local pane_id="${1:-}"
    if [ -z "$pane_id" ]; then
        return 1
    fi
    tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF "$pane_id"
}

# Check if pane is in copy/scroll mode
is_pane_in_mode() {
    local pane_id="${1:-}"
    if [ -z "$pane_id" ]; then
        pane_id=$(get_user_pane_id)
    fi
    local mode
    mode=$(tmux display-message -p -t "$pane_id" -F '#{pane_in_mode}' 2>/dev/null)
    [ "$mode" = "1" ]
}

# Get the current command running in a pane
get_pane_command() {
    local pane_id="${1:-}"
    if [ -z "$pane_id" ]; then
        pane_id=$(get_user_pane_id)
    fi
    tmux display-message -p -t "$pane_id" -F '#{pane_current_command}' 2>/dev/null
}

# Check if pane is in alternate screen (vim, less, etc.)
is_alternate_screen() {
    local pane_id="${1:-}"
    if [ -z "$pane_id" ]; then
        pane_id=$(get_user_pane_id)
    fi
    local flag
    flag=$(tmux display-message -p -t "$pane_id" -F '#{alternate_on}' 2>/dev/null)
    [ "$flag" = "1" ]
}

# ---------------------------------------------------------------------------
# Cursor position reading
# ---------------------------------------------------------------------------

# Read cursor position from a pane
# Returns: "cursor_x cursor_y"
read_cursor() {
    local pane_id="${1:-}"
    if [ -z "$pane_id" ]; then
        pane_id=$(get_user_pane_id)
    fi
    local x y
    x=$(tmux display-message -p -t "$pane_id" -F '#{cursor_x}' 2>/dev/null)
    y=$(tmux display-message -p -t "$pane_id" -F '#{cursor_y}' 2>/dev/null)
    echo "${x:-0} ${y:-0}"
}

# Get pane tty path
get_pane_tty() {
    local pane_id="${1:-}"
    if [ -z "$pane_id" ]; then
        pane_id=$(get_user_pane_id)
    fi
    tmux display-message -p -t "$pane_id" -F '#{pane_tty}' 2>/dev/null
}

# ---------------------------------------------------------------------------
# Prompt timestamp
# ---------------------------------------------------------------------------

# Read the last prompt timestamp (from shell integration)
read_prompt_timestamp() {
    if [ -z "${BRIDGE_RUN_DIR:-}" ]; then
        echo "0"
        return
    fi
    local prompt_file="${BRIDGE_RUN_DIR}/last_prompt"
    if [ -f "$prompt_file" ]; then
        cat "$prompt_file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Check if shell integration is active (last_prompt file updated within last 30s)
is_shell_integration_active() {
    if [ -z "${BRIDGE_RUN_DIR:-}" ]; then
        return 1
    fi
    local prompt_file="${BRIDGE_RUN_DIR}/last_prompt"
    if [ ! -f "$prompt_file" ]; then
        return 1
    fi
    local now mtime diff
    now=$(date +%s)
    mtime=$(stat -c %Y "$prompt_file" 2>/dev/null || echo 0)
    diff=$((now - mtime))
    [ "$diff" -lt 30 ]
}

# ---------------------------------------------------------------------------
# Daemon status
# ---------------------------------------------------------------------------

# Check if the daemon is running
daemon_running() {
    local pid_file="${BRIDGE_RUN_DIR:-/tmp/bridge/unknown}/daemon.pid"
    if [ ! -f "$pid_file" ]; then
        return 1
    fi
    local pid
    pid=$(cat "$pid_file" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Activity state files
# ---------------------------------------------------------------------------

# Check if agent is currently injecting
is_agent_active() {
    [ -f "${BRIDGE_RUN_DIR:-/tmp/bridge/unknown}/agent_active" ]
}

# Read the last injection timestamp (nanoseconds)
read_last_injection() {
    local inj_file="${BRIDGE_RUN_DIR:-/tmp/bridge/unknown}/last_injection"
    if [ -f "$inj_file" ]; then
        cat "$inj_file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Read the last user activity timestamp (nanoseconds, set by daemon)
read_last_user_activity() {
    local act_file="${BRIDGE_RUN_DIR:-/tmp/bridge/unknown}/last_user_activity"
    if [ -f "$act_file" ]; then
        cat "$act_file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# ---------------------------------------------------------------------------
# Pane content reading
# ---------------------------------------------------------------------------

# Capture pane content
capture_pane() {
    local pane_id="$1"
    local start="${2:--}"  # default: visible only
    local flags="-p"

    if [ "$start" = "-" ]; then
        # Full scrollback
        flags="-p -S -"
    elif [ "$start" != "" ]; then
        # Specific start line (negative = lines from end)
        flags="-p -S $start"
    fi

    tmux capture-pane -t "$pane_id" $flags 2>/dev/null
}

# Get pane dimensions
get_pane_dimensions() {
    local pane_id="${1:-}"
    if [ -z "$pane_id" ]; then
        pane_id=$(get_user_pane_id)
    fi
    local w h
    w=$(tmux display-message -p -t "$pane_id" -F '#{pane_width}' 2>/dev/null)
    h=$(tmux display-message -p -t "$pane_id" -F '#{pane_height}' 2>/dev/null)
    echo "${w:-80} ${h:-24}"
}

# ---------------------------------------------------------------------------
# Session/window info
# ---------------------------------------------------------------------------

# Get the bridge session name
get_bridge_session() {
    if [ -n "${BRIDGE_SESSION:-}" ]; then
        echo "$BRIDGE_SESSION"
        return
    fi
    # Try to find by session name pattern (matches UUID-based and custom names)
    tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E '^(agent-tmux-bridge|bridge-)' | head -1
}

# Check if we are inside the bridge session
is_in_bridge_session() {
    local sess
    sess=$(get_bridge_session)
    [ -n "$sess" ]
}
