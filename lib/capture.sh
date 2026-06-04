#!/usr/bin/env bash
# =============================================================================
# capture.sh -- Buffer capture and processing for agent-tmux-bridge
# =============================================================================
# Wraps tmux capture-pane with options for full/partial buffer capture,
# ANSI escape stripping, and content filtering.
# =============================================================================

# ---------------------------------------------------------------------------
# Core capture functions
# ---------------------------------------------------------------------------

# Capture the full scrollback buffer of the user pane
capture_full() {
    local pane_id
    pane_id=$(get_user_pane_id)
    if [ -z "$pane_id" ]; then
        log_error "Cannot find user pane for capture"
        return 1
    fi
    tmux capture-pane -t "$pane_id" -p -S - 2>/dev/null
}

# Capture only the visible portion of the user pane
capture_visible() {
    local pane_id
    pane_id=$(get_user_pane_id)
    if [ -z "$pane_id" ]; then
        log_error "Cannot find user pane for capture"
        return 1
    fi
    tmux capture-pane -t "$pane_id" -p 2>/dev/null
}

# Capture the last N lines from the user pane
capture_last_n() {
    local n="${1:-50}"
    local pane_id
    pane_id=$(get_user_pane_id)
    if [ -z "$pane_id" ]; then
        log_error "Cannot find user pane for capture"
        return 1
    fi
    local max_lines="${READ_MAX_LINES:-10000}"
    if [ "$n" -gt "$max_lines" ]; then
        n="$max_lines"
    fi
    tmux capture-pane -t "$pane_id" -p -S -"$n" 2>/dev/null
}

# Capture content since last occurrence of a pattern
capture_since() {
    local pattern="$1"
    local pane_id
    pane_id=$(get_user_pane_id)
    if [ -z "$pane_id" ]; then
        log_error "Cannot find user pane for capture"
        return 1
    fi
    local full
    full=$(tmux capture-pane -t "$pane_id" -p -S - 2>/dev/null)
    # Find last occurrence and output everything after it
    local line_num
    line_num=$(echo "$full" | grep -n "$pattern" | tail -1 | cut -d: -f1)
    if [ -n "$line_num" ]; then
        echo "$full" | tail -n +"$line_num"
    else
        echo "$full"
    fi
}

# ---------------------------------------------------------------------------
# ANSI / escape code stripping
# ---------------------------------------------------------------------------

# Strip ANSI escape sequences (color codes, cursor movements, etc.)
strip_ansi() {
    # Remove CSI sequences: ESC [ ... m (SGR), ESC [ ... H, ESC [ ... J, etc.
    sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' |
    # Remove OSC sequences: ESC ] ... ESC \ or ESC ] ... BEL
    sed 's/\x1b\][^\x1b]*\x1b\\//g' |
    sed 's/\x1b\][^\x07]*\x07//g' |
    # Remove other escape sequences
    sed 's/\x1b[=<>]//g' |
    # Remove carriage returns
    tr -d '\r'
}

# Strip OSC sequences only (hyperlinks, window title changes, etc.)
strip_osc() {
    sed 's/\x1b\][^\x1b]*\x1b\\//g' |
    sed 's/\x1b\][^\x07]*\x07//g'
}

# Strip known shell prompt patterns (optional, for cleaner output)
strip_prompts() {
    # Remove common prompt patterns (heuristic -- not perfect)
    # Matches lines that look like: user@host:path$ or user@host:path#
    sed -E 's/^[a-zA-Z0-9._-]+@[a-zA-Z0-9._-]+:[^$#]*[$#] ?//'
}

# ---------------------------------------------------------------------------
# Content processing pipeline
# ---------------------------------------------------------------------------

# Process captured content through the configured pipeline
process_capture() {
    local content="${1:-$(cat)}"

    if [ "${STRIP_OSC:-true}" = "true" ]; then
        content=$(echo "$content" | strip_osc)
    fi

    if [ "${STRIP_ANSI:-true}" = "true" ]; then
        content=$(echo "$content" | strip_ansi)
    fi

    echo "$content"
}

# ---------------------------------------------------------------------------
# Content extraction helpers
# ---------------------------------------------------------------------------

# Extract the output of the last command (between last two prompts)
extract_last_command_output() {
    local content
    content=$(capture_full)
    content=$(echo "$content" | process_capture)

    # Heuristic: find the last PS1-like line and return everything after it
    # This is a rough heuristic -- works for standard bash/zsh prompts
    local lines
    lines=$(echo "$content" | wc -l)

    # Find last line that looks like a prompt
    local last_prompt_line
    last_prompt_line=$(echo "$content" | grep -nE '(^\$ |^# |[a-zA-Z0-9._-]+@[a-zA-Z0-9._-]+:.*\$|^> )' | tail -2 | head -1 | cut -d: -f1)

    if [ -n "$last_prompt_line" ] && [ "$last_prompt_line" -gt 0 ]; then
        local next_line=$((last_prompt_line + 1))
        echo "$content" | sed -n "${next_line},\$p"
    else
        echo "$content"
    fi
}

# Check if the user shell appears to be waiting for input (idle at prompt)
is_shell_at_prompt() {
    local visible
    visible=$(capture_visible)
    visible=$(echo "$visible" | process_capture)
    # Check if the last character is a common prompt character
    echo "$visible" | tail -1 | grep -qE '[$#>~] ?$'
}
