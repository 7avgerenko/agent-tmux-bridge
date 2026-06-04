#!/usr/bin/env bash
# =============================================================================
# logging.sh -- Structured logging for agent-tmux-bridge
# =============================================================================

# Log levels: 0=debug, 1=info, 2=warn, 3=error
LOG_LEVEL_DEBUG=0
LOG_LEVEL_INFO=1
LOG_LEVEL_WARN=2
LOG_LEVEL_ERROR=3

_log_level_num() {
    case "${LOG_LEVEL:-info}" in
        debug) echo 0 ;;
        info)  echo 1 ;;
        warn)  echo 2 ;;
        error) echo 3 ;;
        *)     echo 1 ;;
    esac
}

_log_ts() {
    date '+%Y-%m-%dT%H:%M:%S.%N' | sed 's/....$//'
}

_should_log() {
    local msg_level=$1
    local current=$(_log_level_num)
    [ "$msg_level" -ge "$current" ]
}

_log() {
    local level_str="$1"
    local level_num="$2"
    local message="$3"
    local ts=$(_log_ts)

    if ! _should_log "$level_num"; then
        return
    fi

    local formatted="[$ts] [$level_str] [${BRIDGE_SESSION:-unset}] $message"

    # Write to log file if configured
    if [ -n "${LOG_FILE:-}" ] && [ -d "$(dirname "$LOG_FILE")" ]; then
        echo "$formatted" >> "$LOG_FILE"
    fi

    # If run dir is set, write to run dir log
    if [ -n "${BRIDGE_RUN_DIR:-}" ] && [ -d "${BRIDGE_RUN_DIR}/log" ]; then
        echo "$formatted" >> "${BRIDGE_RUN_DIR}/log/bridge.log"
    fi

    # Debug/info to stderr so it doesn't interfere with stdout data
    echo "$formatted" >&2
}

log_debug() { _log "DEBUG" "$LOG_LEVEL_DEBUG" "$*"; }
log_info()  { _log "INFO"  "$LOG_LEVEL_INFO"  "$*"; }
log_warn()  { _log "WARN"  "$LOG_LEVEL_WARN"  "$*"; }
log_error() { _log "ERROR" "$LOG_LEVEL_ERROR" "$*"; }

# Rotate log files if they exceed max size
rotate_logs_if_needed() {
    local log_file="${1:-${BRIDGE_RUN_DIR}/log/bridge.log}"
    local max_size="${LOG_MAX_SIZE:-10485760}"
    local max_files="${LOG_MAX_FILES:-3}"

    if [ ! -f "$log_file" ]; then
        return
    fi

    local size
    size=$(stat -c %s "$log_file" 2>/dev/null || echo 0)

    if [ "$size" -gt "$max_size" ]; then
        # Rotate: remove oldest, shift others
        for i in $(seq "$((max_files - 1))" -1 1); do
            if [ -f "${log_file}.${i}" ]; then
                mv "${log_file}.${i}" "${log_file}.$((i + 1))" 2>/dev/null
            fi
        done
        mv "$log_file" "${log_file}.1" 2>/dev/null
        touch "$log_file"
    fi
}
