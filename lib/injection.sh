#!/usr/bin/env bash
# =============================================================================
# injection.sh -- Command injection logic for agent-tmux-bridge
# =============================================================================
# Handles the actual injection of commands into the user's shell via
# tmux send-keys, with cooldown gating, pane state checks, and the
# agent_active flag coordination that prevents the daemon from
# misinterpreting agent keystrokes as user activity.
# =============================================================================

# ---------------------------------------------------------------------------
# Pre-injection checks
# ---------------------------------------------------------------------------

# Check if the bridge is blocked (user typing within cooldown)
check_cooldown_gate() {
    local status_json blocked
    if status_json=$(cat "${BRIDGE_RUN_DIR}/daemon.status" 2>/dev/null); then
        blocked=$(echo "$status_json" | grep -o '"blocked": [a-z]*' | awk '{print $2}')
        if [ "$blocked" = "true" ]; then
            local remaining_ms
            remaining_ms=$(echo "$status_json" | grep -o '"remaining_cooldown_ms": [0-9]*' | awk '{print $2}')
            local remaining_sec=$((remaining_ms / 1000))
            log_info "Injection blocked: user typing within cooldown (${remaining_sec}s remaining)"
            return 1
        fi
    fi
    return 0
}

# Check if user pane is in a state where injection would be disruptive
check_pane_state() {
    local user_pane
    user_pane=$(get_user_pane_id)

    # Block if user is in tmux copy/scroll mode
    if [ "${BLOCK_ON_COPY_MODE:-true}" = "true" ]; then
        if is_pane_in_mode "$user_pane"; then
            log_info "Injection blocked: user is in copy/scroll mode"
            return 1
        fi
    fi

    # Block if user is on alternate screen (vim, less, man, etc.)
    if [ "${BLOCK_ON_ALTERNATE_SCREEN:-true}" = "true" ]; then
        if is_alternate_screen "$user_pane"; then
            log_info "Injection blocked: user is on alternate screen (vim/less/etc.)"
            return 1
        fi
    fi

    # Check if the current command in the pane is a shell (not vim, etc.)
    local pane_cmd
    pane_cmd=$(get_pane_command "$user_pane")
    case "$(basename "$pane_cmd")" in
        bash|zsh|fish|sh|dash)
            # OK, these are interactive shells
            ;;
        *)
            log_info "Injection blocked: pane is running '$pane_cmd', not an interactive shell"
            return 1
            ;;
    esac

    return 0
}

# ---------------------------------------------------------------------------
# Injection execution
# ---------------------------------------------------------------------------

# Inject a command into the user shell
# Arguments:
#   $1 - command to inject
#   $2 - interactive mode: "true" (no Enter) or "false" (auto-Enter)
#
# In interactive mode (default), the command is typed but Enter is NOT
# pressed. The user sees the command and decides whether to execute it.
inject_command() {
    local command="$1"
    local interactive="${2:-${INTERACTIVE_MODE:-true}}"
    local user_pane
    user_pane=$(get_user_pane_id)

    if [ -z "$user_pane" ]; then
        log_error "Cannot find user pane for injection"
        return 1
    fi

    # --- Step 1: Acquire injection lock ---
    # This tells the daemon "ignore cursor movement for the next few cycles"
    touch "${BRIDGE_RUN_DIR}/agent_active"

    # Record injection timestamp
    date +%s%N > "${BRIDGE_RUN_DIR}/last_injection" 2>/dev/null

    # --- Step 2: Inject the command ---
    # Log the injection
    echo "[$(date '+%Y-%m-%dT%H:%M:%S')] INJECT: $command (interactive=$interactive)" \
        >> "${BRIDGE_RUN_DIR}/log/injections.log" 2>/dev/null

    # Optional: small delay between keystrokes for visual feedback
    local delay_ms="${INJECTION_DELAY_MS:-0}"
    if [ "$delay_ms" -gt 0 ]; then
        # Character-by-character injection with delay
        local i
        for (( i=0; i<${#command}; i++ )); do
            local char="${command:$i:1}"
            tmux send-keys -t "$user_pane" "$char"
            sleep "$(echo "scale=3; $delay_ms / 1000" | bc 2>/dev/null || echo 0.01)"
        done
    else
        # Instant injection (all at once)
        tmux send-keys -t "$user_pane" -l "$command"
    fi

    local send_exit=$?

    # --- Step 3: Optionally press Enter ---
    if [ "$interactive" != "true" ]; then
        # Auto-execute mode: press Enter after the command
        # WARNING: this bypasses human-in-the-loop
        tmux send-keys -t "$user_pane" Enter
        log_warn "Auto-executed command (interactive=false): $command"
    fi

    # --- Step 4: Small delay to let daemon see the final cursor ---
    sleep 0.05

    # --- Step 5: Release injection lock ---
    rm -f "${BRIDGE_RUN_DIR}/agent_active"

    return $send_exit
}

# ---------------------------------------------------------------------------
# Full send pipeline
# ---------------------------------------------------------------------------
# Combines all checks + validator + injection into one flow.
#
# Arguments:
#   $1 - command to send
#
# Options (via env/globals):
#   VALIDATOR          - validator executable or template
#   COOLDOWN_SECONDS   - cooldown window
#   INTERACTIVE_MODE   - whether to auto-press Enter
#
# Returns:
#   0 - command injected successfully
#   1 - blocked by cooldown
#   2 - rejected by validator
#   3 - blocked by pane state
#   4 - injection failed
#   5 - rejected by pre-sanitization (sacrifice: user must type manually)

send_command() {
    local command="$1"

    if [ -z "$command" ]; then
        log_error "send_command: empty command"
        return 4
    fi

    log_info "Send pipeline starting for: $command"

    # --- Gate 1: Cooldown ---
    if ! check_cooldown_gate; then
        echo '{"status":"blocked","reason":"User typing within cooldown window"}'
        return 1
    fi

    # --- Gate 2: Pane state ---
    if ! check_pane_state; then
        echo '{"status":"blocked","reason":"User pane is not in a suitable state for injection"}'
        return 3
    fi

    # --- Gate 3: Validator (always runs — even if VALIDATOR is empty,
    #               pre-sanitization runs inside run_validator) ---
    local validated_cmd validator_output validator_rc
    validator_output=$(run_validator "$command")
    validator_rc=$?

    if [ $validator_rc -eq 0 ]; then
        # Allowed (possibly modified)
        validated_cmd="$validator_output"
        if [ "$validated_cmd" != "$command" ]; then
            log_info "Validator modified command: '$command' -> '$validated_cmd'"
        fi
    elif [ $validator_rc -eq 3 ]; then
        # Pre-sanitization rejection — too dangerous to even validate
        # This is the "sacrifice" mode: the user must type manually
        echo "{\"status\":\"rejected\",\"reason\":\"Pre-sanitization blocked command\",\"validator_output\":\"$validator_output\",\"sacrifice\":true}"
        return 5
    else
        # Rejected by validator (rc=1) or validator error (rc=2)
        echo "{\"status\":\"rejected\",\"reason\":\"Validator rejected command\",\"validator_output\":\"$validator_output\"}"
        return 2
    fi

    # --- Step 4: Inject ---
    local interactive="${INTERACTIVE_MODE:-true}"
    if inject_command "$validated_cmd" "$interactive"; then
        echo "{\"status\":\"ok\",\"command\":\"$validated_cmd\",\"interactive\":$interactive}"
        return 0
    else
        echo '{"status":"error","reason":"Injection failed"}'
        return 4
    fi
}
