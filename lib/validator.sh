#!/usr/bin/env bash
# =============================================================================
# validator.sh -- External command validator for agent-tmux-bridge
# =============================================================================
#
# The validator is an EXTERNAL safety mechanism. Claude Code (or any other
# agent) does NOT check its own commands — that would be unreliable since
# the model can be wrong and non-Anthropic APIs may be in use.
#
# Instead, every command the agent wants to inject passes through an
# external validator executable that independently decides whether to
# allow or reject it.
#
# VALIDATOR CONTRACT:
#   - Returns exit code 0 = ALLOW (command may be injected)
#   - Returns exit code non-zero = REJECT (command blocked)
#   - STDOUT on success: optionally modified/sanitized command (or empty)
#   - STDERR on failure: rejection reason (logged and surfaced to agent)
#
# THREE INVOCATION MODES:
#
#   1. const mode (no "{}" in validator string):
#      The validator is executed as-is — no stdin, no arguments.
#      It does NOT see the command at all. Purely exit-code based.
#      Example: VALIDATOR="true"           → always allow
#               VALIDATOR="false"          → always reject
#               VALIDATOR="./coinflip.sh"  → random allow/reject
#
#   2. template mode (validator string contains "{}"):
#      "{}" is replaced with the shell-escaped command text.
#      The validator can inspect/modify the command.
#      Example: VALIDATOR="./check.py --input {}"
#        → executes: ./check.py --input "rm -rf /"
#      The validator receives the command as an argument and can
#      output a modified version on stdout (or nothing = keep original).
#
#   3. stdin mode (legacy, enabled explicitly with "stdin:" prefix):
#      The command is piped to the validator's STDIN.
#      Example: VALIDATOR="stdin:./legacy-validator.sh"
#        → executes: echo "cmd" | ./legacy-validator.sh
# =============================================================================

# ---------------------------------------------------------------------------
# Determine validator mode from configuration
# ---------------------------------------------------------------------------

# Check if the validator string is a template (contains "{}")
_is_template_mode() {
    local validator="${1:-}"
    [[ "$validator" == *"{}"* ]]
}

# Check if the validator string uses legacy stdin mode
_is_stdin_mode() {
    local validator="${1:-}"
    [[ "$validator" == stdin:* ]]
}

# Check if a validator is configured
has_validator() {
    [ -n "${VALIDATOR:-}" ]
}

# ---------------------------------------------------------------------------
# Command sanitization (pre-validation, runs BEFORE the validator)
# ---------------------------------------------------------------------------
# Delegates to a Python script that receives the command via argv[1].
# Python's execve-based argument passing is immune to shell injection —
# the command text is PURE DATA, never interpreted by a shell.
#
# Why not bash? A bash-based sanitizer processing attacker-controlled
# strings has the same attack surface it's supposed to protect against.
# Python handles binary-safe strings, and argument passing via execve
# eliminates shell injection entirely.
#
# Fallback: if Python is not available, we use a minimal bash check
# that avoids the problematic constructs (no grep -P, no printf '%q').

_sanitizer_py() {
    # Try to find the sanitizer script relative to BRIDGE_HOME
    local script="${BRIDGE_HOME}/lib/sanitize.py"
    if [ ! -f "$script" ]; then
        # Fallback: try relative to this file
        script="$(dirname "${BASH_SOURCE[0]:-$0}")/sanitize.py"
    fi
    echo "$script"
}

sanitize_command() {
    local command="$1"

    # =========================================================================
    # --allow-malicious-access: DISABLE LAYER 1 PRE-SANITIZATION
    # =========================================================================
    # This flag exists for users who want the "openclaw" experience —
    # completely unfiltered command injection, trusting only the external
    # validator (if configured) and human-in-the-loop (Enter key).
    #
    # When set, pre-sanitization is SKIPPED. Control characters, newlines,
    # null bytes, ANSI escapes, and Unicode trickery are NOT blocked.
    # The command text goes directly to the validator (or to send-keys if
    # no validator is configured).
    #
    # THIS IS DANGEROUS. A malicious or compromised LLM can inject:
    #   - Newlines → auto-execute commands without user pressing Enter
    #   - Ctrl+C  → kill the user's foreground process
    #   - Ctrl+D  → close the user's shell
    #   - ANSI escapes → rewrite terminal content, hide commands
    #
    # Only use this if you understand these risks and have compensating
    # controls (e.g., a robust external validator that inspects commands,
    # or a fully sandboxed environment).
    if [ "${ALLOW_MALICIOUS_ACCESS:-0}" = "1" ]; then
        log_warn "⚠️  --allow-malicious-access: Layer 1 pre-sanitization DISABLED"
        log_warn "   Control chars, newlines, and Unicode attacks will NOT be blocked."
        echo "$command"
        return 0
    fi
    local sanitizer_py
    sanitizer_py=$(_sanitizer_py)

    if [ -f "$sanitizer_py" ] && command -v python3 &>/dev/null; then
        # --- Primary path: Python sanitizer (no shell injection surface) ---
        # The command is passed as an argument via execve — pure data.
        # Python processes it as a binary-safe string.
        local output exit_code
        output=$(python3 "$sanitizer_py" "$command" 2>&1)
        exit_code=$?
        if [ $exit_code -ne 0 ]; then
            echo "$output" >&2
            return 1
        fi
        # Sanitizer may output a cleaned version; return it
        if [ -n "$output" ]; then
            echo "$output"
        fi
        return 0
    else
        # --- Fallback: minimal bash sanitization ---
        # Only the checks that are SAFE to do in bash without
        # grep -P, printf '%q', or other complex string processing.
        # These use only bash builtins and basic POSIX tools.

        # Empty check (safe: bash builtin)
        if [ -z "$command" ]; then
            echo "REJECTED: empty command" >&2
            return 1
        fi

        # Length check (safe: bash builtin)
        local max_len="${VALIDATOR_MAX_CMD_LENGTH:-102400}"
        if [ "${#command}" -gt "$max_len" ]; then
            echo "REJECTED: command too long (${#command} bytes, max $max_len)" >&2
            return 1
        fi

        # Newline check via line counting (safe: POSIX wc)
        local lines
        lines=$(printf '%s' "$command" | wc -l)
        if [ "$lines" -gt 1 ]; then
            echo "REJECTED: command contains newline characters" >&2
            return 1
        fi

        # Carriage return check (safe: POSIX tr + test)
        local no_cr
        no_cr=$(printf '%s' "$command" | tr -d '\r' | wc -c)
        local orig
        orig=$(printf '%s' "$command" | wc -c)
        if [ "$no_cr" -ne "$orig" ]; then
            echo "REJECTED: command contains carriage return characters" >&2
            return 1
        fi

        log_warn "Python sanitizer not available, using minimal bash fallback"
        return 0
    fi
}

# ---------------------------------------------------------------------------
# Run the validator pipeline
# ---------------------------------------------------------------------------
# Arguments:
#   $1 - command to validate
#   $2 - (optional) timeout in seconds
#
# Output on success (exit 0):
#   The validated/sanitized command on STDOUT
#   (may be identical to input if validator is pass-through)
#
# Output on failure (exit non-zero):
#   Rejection reason on STDOUT
#
# Returns:
#   0 - command allowed (possibly modified)
#   1 - command rejected by validator
#   2 - validator error (timeout, not found, etc.)
#   3 - command rejected by pre-sanitization (too dangerous to even validate)
#       The user must manually type this command; automation is forbidden.

run_validator() {
    local command="$1"
    local timeout_sec="${2:-${VALIDATOR_TIMEOUT:-5}}"

    # =========================================================================
    # STEP 0: Pre-sanitization (runs BEFORE any validator, cannot be bypassed)
    # =========================================================================
    # These checks are HARD rejections. Even if no validator is configured,
    # commands that fail pre-sanitization are blocked. This prevents the
    # "unset VALIDATOR" bypass and catches injection attempts regardless
    # of validator configuration.
    #
    # If pre-sanitization rejects, the bridge tells the agent the command
    # was blocked and suggests the user type it manually ("sacrifice" mode).

    local sanitize_output sanitize_rc
    sanitize_output=$(sanitize_command "$command" 2>&1)
    sanitize_rc=$?
    if [ $sanitize_rc -ne 0 ]; then
        log_warn "Pre-sanitization rejected command: $sanitize_output"
        echo "REJECTED_BY_SANITIZER: $sanitize_output"
        echo "MANUAL_REQUIRED: This command must be typed manually by the user."
        return 3
    fi

    # =========================================================================
    # STEP 1: No validator configured → allow (pre-sanitization already passed)
    # =========================================================================
    if ! has_validator; then
        echo "$command"
        return 0
    fi

    local validator="$VALIDATOR"

    # =========================================================================
    # STEP 2: Template mode ("{}" present in validator string)
    # =========================================================================
    # CRITICAL: The command text is NEVER inlined into the bash -c string.
    # Instead, {} is replaced with "$1" (a positional parameter reference),
    # and the actual command is passed as the first argument to bash -c.
    # This means the command text is ALWAYS data, NEVER code — no amount
    # of shell metacharacters, quotes, or backticks can break out.
    if _is_template_mode "$validator"; then
        # Replace {} with "$1" — a reference to the first positional parameter
        local template_ref="${validator//\{\}/\"\$1\"}"

        log_debug "Validator (template): $template_ref"

        # Execute: bash -c 'template with "$1"' _ <actual_command>
        # The '_' becomes $0 (script name), the command becomes $1 (data).
        # Even if the command contains: $(id), `id`, "; rm -rf /", $HOME, etc.
        # it is ONLY accessible via "$1" parameter expansion = pure data.
        local output exit_code
        output=$(timeout "$timeout_sec" bash -c "$template_ref" _ "$command" 2>&1)
        exit_code=$?

        if [ $exit_code -eq 0 ]; then
            if [ -n "$output" ]; then
                echo "$output"
            else
                echo "$command"
            fi
            return 0
        elif [ $exit_code -eq 124 ]; then
            log_error "Validator timed out after ${timeout_sec}s"
            echo "VALIDATOR_TIMEOUT: command validation timed out"
            return 2
        else
            log_warn "Validator rejected command (exit=$exit_code): ${output:-no reason given}"
            echo "REJECTED: ${output:-command blocked by validator}"
            return 1
        fi

    # =========================================================================
    # STEP 3: Legacy stdin mode ("stdin:" prefix)
    # =========================================================================
    elif _is_stdin_mode "$validator"; then
        local stdin_cmd="${validator#stdin:}"
        log_debug "Validator (stdin): $stdin_cmd"

        local output exit_code
        output=$(printf '%s' "$command" | timeout "$timeout_sec" $stdin_cmd 2>&1)
        exit_code=$?

        if [ $exit_code -eq 0 ]; then
            if [ -n "$output" ]; then
                echo "$output"
            else
                echo "$command"
            fi
            return 0
        elif [ $exit_code -eq 124 ]; then
            log_error "Validator timed out after ${timeout_sec}s"
            echo "VALIDATOR_TIMEOUT: command validation timed out"
            return 2
        else
            log_warn "Validator rejected command (exit=$exit_code): ${output:-no reason given}"
            echo "REJECTED: ${output:-command blocked by validator}"
            return 1
        fi

    # =========================================================================
    # STEP 4: Const mode (no "{}", no "stdin:" prefix)
    # =========================================================================
    else
        log_debug "Validator (const): $validator"

        local output exit_code
        output=$(timeout "$timeout_sec" $validator 2>&1)
        exit_code=$?

        if [ $exit_code -eq 0 ]; then
            echo "$command"
            return 0
        elif [ $exit_code -eq 124 ]; then
            log_error "Validator timed out after ${timeout_sec}s"
            echo "VALIDATOR_TIMEOUT: command validation timed out"
            return 2
        else
            log_warn "Validator rejected command (const, exit=$exit_code): ${output:-no reason given}"
            echo "REJECTED: ${output:-command blocked by validator}"
            return 1
        fi
    fi
}

# ---------------------------------------------------------------------------
# Built-in validator functions (convenience wrappers)
# ---------------------------------------------------------------------------

# Allow all commands (pass-through)
# Use as: VALIDATOR="stdin:./path/to/allow-all.sh"
validator_allow_all() {
    cat
    return 0
}

# Block all commands
# Use as: VALIDATOR="false" (const mode) — simplest!
validator_block_all() {
    echo "All commands are blocked by validator" >&2
    return 1
}

# Block known dangerous patterns
# Use as: VALIDATOR="./config/sanitizers/reject-dangerous.sh {}"
validator_reject_dangerous() {
    local cmd="${1:-$(cat)}"
    local patterns=(
        'rm\s+-rf\s+/'
        'dd\s+if=/dev/zero'
        'mkfs\.'
        ':(){ :|:& };:'
        'chmod\s+-R\s+777\s+/'
        '>\/dev\/sda'
    )
    for pattern in "${patterns[@]}"; do
        if echo "$cmd" | grep -Eq "$pattern"; then
            echo "Dangerous command pattern detected: $pattern" >&2
            return 1
        fi
    done
    echo "$cmd"
    return 0
}
