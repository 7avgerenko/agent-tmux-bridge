#!/usr/bin/env bash
# =============================================================================
# test-bridge.sh -- Integration test suite for agent-tmux-bridge
# =============================================================================
# Tests the bridge components end-to-end. Requires tmux to be installed.
#
# Usage:
#   ./test/test-bridge.sh              # Run all tests
#   ./test/test-bridge.sh --quick      # Quick smoke test only
#   ./test/test-bridge.sh --keep-session  # Don't clean up test session
# =============================================================================

set -uo pipefail
# Note: no -e because we test validators that intentionally return non-zero

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export BRIDGE_HOME

TEST_SESSION="bridge-test-$$"
PASSED=0
FAILED=0
KEEP_SESSION=false
QUICK_MODE=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

ok() {
    PASSED=$((PASSED + 1))
    echo -e "  ${GREEN}✓${NC} $1"
}

fail() {
    FAILED=$((FAILED + 1))
    echo -e "  ${RED}✗${NC} $1"
    if [ -n "${2:-}" ]; then
        echo -e "    ${YELLOW}→ $2${NC}"
    fi
}

assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        ok "$desc"
    else
        fail "$desc" "expected='$expected' actual='$actual'"
    fi
}

assert_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        ok "$desc"
    else
        fail "$desc" "expected '$needle' to be found in output"
    fi
}

assert_exit() {
    local desc="$1"
    local expected_exit=$2
    local actual_exit=$3
    if [ "$expected_exit" -eq "$actual_exit" ]; then
        ok "$desc"
    else
        fail "$desc" "expected exit=$expected_exit actual=$actual_exit"
    fi
}

section() {
    echo ""
    echo "── $1 ──"
}

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup_test_session() {
    echo "Setting up test session: $TEST_SESSION"

    # Create a detached test session
    BRIDGE_HOME="$BRIDGE_HOME" \
    SESSION_NAME="$TEST_SESSION" \
    "$BRIDGE_HOME/bin/bridge" init \
        --no-attach \
        --cooldown 1 \
        2>/dev/null || {
        echo "  (Session may already exist, continuing)"
    }

    # Give daemon time to start
    sleep 1
}

teardown_test_session() {
    if [ "$KEEP_SESSION" = "true" ]; then
        echo "Keeping test session: $TEST_SESSION"
        echo "Clean up with: tmux kill-session -t $TEST_SESSION"
        return
    fi
    echo "Cleaning up test session: $TEST_SESSION"
    tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
    rm -rf "/tmp/bridge/$TEST_SESSION" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Test: Config loading
# ---------------------------------------------------------------------------

test_config_loading() {
    section "Config Loading"

    # Test that config values are loaded
    local cooldown
    cooldown=$(bash -c "source '$BRIDGE_HOME/config/default.conf'; echo \$COOLDOWN_SECONDS")
    assert_eq "Default cooldown is 5" "5" "$cooldown"

    # Test env var override
    local override
    override=$(BRIDGE_COOLDOWN_SECONDS=10 bash -c \
        "source '$BRIDGE_HOME/lib/config.sh' 2>/dev/null; echo \$COOLDOWN_SECONDS")
    assert_eq "Env var overrides cooldown" "10" "$override"

    ok "Config loading tests complete"
}

# ---------------------------------------------------------------------------
# Test: Validator
# ---------------------------------------------------------------------------

test_validator() {
    section "Validator"

    # --- Test validators with $1 arg (template mode) ---
    local result rc

    result=$("$BRIDGE_HOME/config/sanitizers/allow-all.sh" "echo hello")
    rc=$?
    assert_eq "allow-all (template) passes command" "echo hello" "$result"
    assert_exit "allow-all (template) returns 0" 0 $rc

    result=$("$BRIDGE_HOME/config/sanitizers/block-all.sh" "echo hello" 2>&1)
    rc=$?
    assert_exit "block-all (template) returns non-zero" 1 $rc
    assert_contains "block-all (template) has rejection message" "BLOCKED" "$result"

    result=$("$BRIDGE_HOME/config/sanitizers/reject-dangerous.sh" "rm -rf / --no-preserve-root" 2>&1)
    rc=$?
    assert_exit "reject-dangerous (template) blocks rm -rf /" 1 $rc

    result=$("$BRIDGE_HOME/config/sanitizers/reject-dangerous.sh" "ls -la")
    rc=$?
    assert_exit "reject-dangerous (template) allows ls -la" 0 $rc
    assert_eq "reject-dangerous (template) passes safe command" "ls -la" "$result"

    # --- Test legacy stdin mode ---
    result=$(echo "echo hello" | "$BRIDGE_HOME/config/sanitizers/allow-all.sh" 2>&1)
    rc=$?
    assert_eq "allow-all (stdin) passes command" "echo hello" "$result"
    assert_exit "allow-all (stdin) returns 0" 0 $rc

    result=$(echo "echo hello" | "$BRIDGE_HOME/config/sanitizers/block-all.sh" 2>&1)
    rc=$?
    assert_exit "block-all (stdin) returns non-zero" 1 $rc

    result=$(echo "rm -rf /" | "$BRIDGE_HOME/config/sanitizers/reject-dangerous.sh" 2>&1)
    rc=$?
    assert_exit "reject-dangerous (stdin) blocks rm -rf /" 1 $rc

    result=$(echo "ls -la" | "$BRIDGE_HOME/config/sanitizers/reject-dangerous.sh")
    rc=$?
    assert_exit "reject-dangerous (stdin) allows ls -la" 0 $rc

    # --- Mode detection ---
    local detected
    detected=$(bash -c "source '$BRIDGE_HOME/lib/validator.sh'; _is_template_mode './check.py --input {}' && echo template || echo other")
    assert_eq "Detects template mode (contains {})" "template" "$detected"

    detected=$(bash -c "source '$BRIDGE_HOME/lib/validator.sh'; _is_template_mode 'true' && echo template || echo other")
    assert_eq "Detects non-template (true → const)" "other" "$detected"

    detected=$(bash -c "source '$BRIDGE_HOME/lib/validator.sh'; _is_template_mode 'false' && echo template || echo other")
    assert_eq "Detects non-template (false → const)" "other" "$detected"

    detected=$(bash -c "source '$BRIDGE_HOME/lib/validator.sh'; _is_stdin_mode 'stdin:./legacy.sh' && echo stdin || echo other")
    assert_eq "Detects stdin mode prefix" "stdin" "$detected"

    # --- Test const mode via run_validator ---
    # Source dependencies so run_validator can use log_* functions
    local test_shell
    test_shell="
        source '$BRIDGE_HOME/lib/logging.sh' 2>/dev/null
        source '$BRIDGE_HOME/lib/config.sh' 2>/dev/null
        source '$BRIDGE_HOME/lib/validator.sh' 2>/dev/null
        LOG_LEVEL=error
    "

    local result rc
    result=$(bash -c "$test_shell
        VALIDATOR='true' run_validator 'echo hello'
    ")
    rc=$?
    assert_exit "const mode 'true' allows command" 0 $rc
    assert_eq "const mode 'true' keeps command" "echo hello" "$result"

    # const: 'false' — always reject
    result=$(bash -c "$test_shell
        VALIDATOR='false' run_validator 'echo hello'
    " 2>&1)
    rc=$?
    assert_exit "const mode 'false' rejects command" 1 $rc
    assert_contains "const mode 'false' rejection message" "REJECTED" "$result"

    # const: non-existent command → reject (safe default: can't execute = reject)
    result=$(bash -c "$test_shell
        VALIDATOR='/nonexistent/validator_xyzzy' run_validator 'echo hello'
    " 2>&1)
    rc=$?
    # Non-existent validators fail to execute and reject the command
    # The exact exit code depends on the shell; either 1 (reject) or 127 (not found)
    if [ "$rc" -ne 0 ]; then
        ok "const mode nonexistent rejects command (rc=$rc)"
    else
        fail "const mode nonexistent should reject" "exit=$rc"
    fi

    # --- Test template mode via run_validator ---
    result=$(bash -c "$test_shell
        VALIDATOR='$BRIDGE_HOME/config/sanitizers/allow-all.sh {}' run_validator 'echo test'
    ")
    rc=$?
    assert_exit "template mode allow-all passes" 0 $rc
    assert_eq "template mode allow-all keeps command" "echo test" "$result"

    # template: ./reject-dangerous.sh {}
    result=$(bash -c "$test_shell
        VALIDATOR='$BRIDGE_HOME/config/sanitizers/reject-dangerous.sh {}' run_validator 'rm -rf /'
    " 2>&1)
    rc=$?
    assert_exit "template mode reject-dangerous blocks rm -rf /" 1 $rc

    # --- Test stdin mode via run_validator ---
    result=$(bash -c "$test_shell
        VALIDATOR='stdin:$BRIDGE_HOME/config/sanitizers/allow-all.sh' run_validator 'echo hello'
    ")
    rc=$?
    assert_exit "stdin mode allow-all passes" 0 $rc

    ok "Validator tests complete"
}

# ---------------------------------------------------------------------------
# Test: Tmux helpers (requires tmux)
# ---------------------------------------------------------------------------

test_tmux_helpers() {
    section "Tmux Helpers"

    if ! command -v tmux &>/dev/null; then
        fail "tmux not found, skipping tmux tests"
        return
    fi

    # Test basic tmux functionality
    local has_session
    if tmux has-session -t "$TEST_SESSION" 2>/dev/null; then
        ok "Test session exists"
    else
        fail "Test session does not exist"
        return
    fi

    # Test pane discovery
    local panes
    panes=$(tmux list-panes -t "$TEST_SESSION:0" -F '#{pane_id}' 2>/dev/null | wc -l)
    assert_eq "Test session has 2 panes" "2" "$panes"

    ok "Tmux helper tests complete"
}

# ---------------------------------------------------------------------------
# Test: Bridge status (requires running session)
# ---------------------------------------------------------------------------

test_bridge_status() {
    section "Bridge Status"

    if ! command -v tmux &>/dev/null; then
        fail "tmux not found, skipping status tests"
        return
    fi

    if ! tmux has-session -t "$TEST_SESSION" 2>/dev/null; then
        fail "Test session not available"
        return
    fi

    # Test bridge status command
    local status_output status_rc
    status_output=$(BRIDGE_SESSION="$TEST_SESSION" BRIDGE_RUN_DIR="/tmp/bridge/$TEST_SESSION" \
        "$BRIDGE_HOME/bin/bridge" status 2>&1) || status_rc=$?
    echo "  status output: $status_output"

    if echo "$status_output" | grep -qE "READY|BLOCKED|not initialized"; then
        ok "Bridge status returns valid output"
    else
        fail "Bridge status returned unexpected output" "$status_output"
    fi

    # Test JSON status
    local json_output
    json_output=$(BRIDGE_SESSION="$TEST_SESSION" BRIDGE_RUN_DIR="/tmp/bridge/$TEST_SESSION" \
        "$BRIDGE_HOME/bin/bridge" status --json 2>&1)
    if echo "$json_output" | grep -q '"blocked"'; then
        ok "JSON status contains blocked field"
    else
        fail "JSON status missing blocked field" "$json_output"
    fi

    ok "Status tests complete"
}

# ---------------------------------------------------------------------------
# Test: Bridge read (requires running session)
# ---------------------------------------------------------------------------

test_bridge_read() {
    section "Bridge Read"

    if ! command -v tmux &>/dev/null; then
        fail "tmux not found, skipping read tests"
        return
    fi

    if ! tmux has-session -t "$TEST_SESSION" 2>/dev/null; then
        fail "Test session not available"
        return
    fi

    # Send some text to the user pane
    local user_pane
    user_pane=$(cat "/tmp/bridge/$TEST_SESSION/user_pane" 2>/dev/null)
    if [ -z "$user_pane" ]; then
        fail "Cannot find user pane"
        return
    fi

    tmux send-keys -t "$user_pane" "echo 'BRIDGE_TEST_MARKER_$$'" Enter
    sleep 0.5

    # Read back
    local read_output
    read_output=$(BRIDGE_SESSION="$TEST_SESSION" BRIDGE_RUN_DIR="/tmp/bridge/$TEST_SESSION" \
        "$BRIDGE_HOME/bin/bridge" read --last 10 2>/dev/null)
    if echo "$read_output" | grep -q "BRIDGE_TEST_MARKER_$$"; then
        ok "Bridge read captured injected text"
    else
        fail "Bridge read did not capture injected text" "$read_output"
    fi

    ok "Read tests complete"
}

# ---------------------------------------------------------------------------
# Test: Bridge send (dry run)
# ---------------------------------------------------------------------------

test_bridge_send_dry_run() {
    section "Bridge Send (Dry Run)"

    if ! command -v tmux &>/dev/null; then
        fail "tmux not found, skipping send tests"
        return
    fi

    if ! tmux has-session -t "$TEST_SESSION" 2>/dev/null; then
        fail "Test session not available"
        return
    fi

    # Dry run should not actually inject
    local output rc
    output=$(BRIDGE_SESSION="$TEST_SESSION" BRIDGE_RUN_DIR="/tmp/bridge/$TEST_SESSION" \
        "$BRIDGE_HOME/bin/bridge" send --dry-run "echo test_dry_run_$$" 2>&1) || rc=$?

    if echo "$output" | grep -q "DRY RUN"; then
        ok "Dry run shows DRY RUN header"
    else
        fail "Dry run output missing" "$output"
    fi

    ok "Send dry-run tests complete"
}

# ---------------------------------------------------------------------------
# Test: Validator integration with bridge send
# ---------------------------------------------------------------------------

test_validator_integration() {
    section "Validator Integration"

    if ! command -v tmux &>/dev/null; then
        fail "tmux not found, skipping integration tests"
        return
    fi

    if ! tmux has-session -t "$TEST_SESSION" 2>/dev/null; then
        fail "Test session not available"
        return
    fi

    # Test with block-all validator (dry run)
    local output rc
    output=$(BRIDGE_SESSION="$TEST_SESSION" \
        BRIDGE_RUN_DIR="/tmp/bridge/$TEST_SESSION" \
        BRIDGE_VALIDATOR="$BRIDGE_HOME/config/sanitizers/block-all.sh" \
        "$BRIDGE_HOME/bin/bridge" send --dry-run "echo test" 2>&1) || rc=$?

    if echo "$output" | grep -q "REJECTED"; then
        ok "block-all validator rejects command"
    else
        fail "block-all validator did not reject" "$output"
    fi

    ok "Validator integration tests complete"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    # Parse args
    for arg in "$@"; do
        case "$arg" in
            --quick) QUICK_MODE=true ;;
            --keep-session) KEEP_SESSION=true ;;
            --help|-h)
                echo "Usage: $0 [--quick] [--keep-session]"
                exit 0
                ;;
        esac
    done

    echo "════════════════════════════════════════════════════"
    echo "  agent-tmux-bridge Test Suite"
    echo "════════════════════════════════════════════════════"

    # Unit tests (no tmux needed)
    test_config_loading
    test_validator

    if [ "$QUICK_MODE" = true ]; then
        echo ""
        echo "Quick mode: skipping integration tests"
        echo ""
        echo "────────────────────────────────────────"
        echo -e "Results: ${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}"
        echo "────────────────────────────────────────"
        exit $FAILED
    fi

    # Integration tests (need tmux and session)
    setup_test_session
    test_tmux_helpers
    test_bridge_status
    test_bridge_read
    test_bridge_send_dry_run
    test_validator_integration
    teardown_test_session

    echo ""
    echo "────────────────────────────────────────"
    echo -e "Results: ${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}"
    echo "────────────────────────────────────────"

    exit $FAILED
}

main "$@"
