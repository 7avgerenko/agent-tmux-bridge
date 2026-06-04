#!/usr/bin/env bash
# =============================================================================
# config.sh -- Configuration loading for agent-tmux-bridge
# =============================================================================

# Determine BRIDGE_HOME: the directory containing this project
if [ -z "${BRIDGE_HOME:-}" ]; then
    # Try to find relative to the script location
    _config_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    if [ -d "$_config_script_dir/../config" ]; then
        BRIDGE_HOME="$(cd "$_config_script_dir/.." && pwd)"
    else
        BRIDGE_HOME="/home/illia/Projects/agent-tmux-bridge"
    fi
fi

# ---------------------------------------------------------------------------
# Save runtime variables BEFORE sourcing config files.
# The config files set BRIDGE_SESSION="" etc. as defaults — we must not
# lose the values that were already set in the environment (by bridge-init).
# ---------------------------------------------------------------------------
_saved_session="${BRIDGE_SESSION:-}"
_saved_run_dir="${BRIDGE_RUN_DIR:-}"
_saved_user_pane="${BRIDGE_USER_PANE:-}"
_saved_agent_pane="${BRIDGE_AGENT_PANE:-}"
_saved_home="${BRIDGE_HOME:-}"

# Load default configuration
if [ -f "$BRIDGE_HOME/config/default.conf" ]; then
    source "$BRIDGE_HOME/config/default.conf"
else
    echo "[bridge] ERROR: default config not found at $BRIDGE_HOME/config/default.conf" >&2
fi

# Load user configuration overrides
_user_config="${XDG_CONFIG_HOME:-$HOME/.config}/agent-tmux-bridge/bridge.conf"
if [ -f "$_user_config" ]; then
    source "$_user_config"
fi

# Restore runtime variables that were set before config loading.
# These are set by bridge-init and MUST survive config reload.
[ -n "$_saved_session" ]    && BRIDGE_SESSION="$_saved_session"
[ -n "$_saved_run_dir" ]    && BRIDGE_RUN_DIR="$_saved_run_dir"
[ -n "$_saved_user_pane" ]  && BRIDGE_USER_PANE="$_saved_user_pane"
[ -n "$_saved_agent_pane" ] && BRIDGE_AGENT_PANE="$_saved_agent_pane"
[ -n "$_saved_home" ]       && BRIDGE_HOME="$_saved_home"

# Apply environment variable overrides (BRIDGE_<KEY>)
# This overrides any config file setting (except runtime vars) with the
# corresponding env var. Runtime vars are intentionally excluded — they
# can only be set by bridge-init, not by the environment.
_apply_env_overrides() {
    local var_name
    for var_name in $(compgen -v BRIDGE_ 2>/dev/null || env | grep '^BRIDGE_' | cut -d= -f1); do
        case "$var_name" in
            BRIDGE_HOME|BRIDGE_RUN_DIR|BRIDGE_SESSION|BRIDGE_USER_PANE|BRIDGE_AGENT_PANE)
                # Runtime vars: never override from env (set by init, restored above)
                ;;
            *)
                local config_key="${var_name#BRIDGE_}"
                if [ -n "${!var_name:-}" ]; then
                    printf -v "$config_key" '%s' "${!var_name}"
                fi
                ;;
        esac
    done
}
_apply_env_overrides

# Derive run directory if session name is known
if [ -n "${BRIDGE_SESSION:-}" ] && [ -z "${BRIDGE_RUN_DIR:-}" ]; then
    BRIDGE_RUN_DIR="/tmp/bridge/${BRIDGE_SESSION}"
fi

# Export all bridge vars for subprocesses
export BRIDGE_HOME BRIDGE_RUN_DIR BRIDGE_SESSION BRIDGE_USER_PANE BRIDGE_AGENT_PANE
export COOLDOWN_SECONDS POLL_INTERVAL_MS ACTIVITY_DETECTION
export SANITIZER SANITIZER_TIMEOUT
export LOG_LEVEL LOG_FILE LOG_MAX_SIZE LOG_MAX_FILES
export READ_MAX_LINES STRIP_ANSI STRIP_OSC
export INTERACTIVE_MODE INJECTION_DELAY_MS
export BLOCK_ON_COPY_MODE BLOCK_ON_ALTERNATE_SCREEN
export SESSION_NAME LAYOUT USER_PANE_SIZE AGENT_PANE_SIZE
