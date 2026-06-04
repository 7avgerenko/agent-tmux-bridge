#!/usr/bin/env bash
# =============================================================================
# claude-code-agent.sh -- Example: Using agent-tmux-bridge with Claude Code
# =============================================================================
# This script demonstrates how to configure Claude Code to work with
# the agent-tmux-bridge. It sets up:
#   1. The bridge session (if not already running)
#   2. Environment for Claude Code to discover the bridge
#   3. A Claude Code session in the agent pane
#
# Usage:
#   ./examples/claude-code-agent.sh [--validator allow-all|block-all|PATH]
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

VALIDATOR="${VALIDATOR:-}"  # Default: no validator (allow all)
COOLDOWN="${COOLDOWN:-5}"   # 5 second cooldown
LAYOUT="${LAYOUT:-horizontal}"

while [ $# -gt 0 ]; do
    case "$1" in
        --validator)
            VALIDATOR="$2"
            shift 2
            ;;
        --cooldown)
            COOLDOWN="$2"
            shift 2
            ;;
        --vertical)
            LAYOUT="vertical"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "=== agent-tmux-bridge + Claude Code Integration ==="
echo ""

# ---------------------------------------------------------------------------
# Step 1: Check for tmux
# ---------------------------------------------------------------------------

if ! command -v tmux &>/dev/null; then
    echo "ERROR: tmux is required but not installed."
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: Initialize the bridge if not already running
# ---------------------------------------------------------------------------

if ! "$BRIDGE_HOME/bin/bridge" status --json &>/dev/null 2>&1; then
    echo "[1/3] Creating bridge session..."

    INIT_ARGS=(
        --name "agent-tmux-bridge"
        --cooldown "$COOLDOWN"
        --no-attach
    )

    if [ "$LAYOUT" = "vertical" ]; then
        INIT_ARGS+=(--vertical)
    fi

    if [ -n "$VALIDATOR" ]; then
        INIT_ARGS+=(--validator "$VALIDATOR")
    fi

    "$BRIDGE_HOME/bin/bridge" init "${INIT_ARGS[@]}"
    echo "  Bridge session created."
else
    echo "[1/3] Bridge already initialized."
fi

# ---------------------------------------------------------------------------
# Step 3: Verify bridge status
# ---------------------------------------------------------------------------

echo "[2/3] Verifying bridge status..."
"$BRIDGE_HOME/bin/bridge" status

# ---------------------------------------------------------------------------
# Step 4: Launch Claude Code in the agent pane
# ---------------------------------------------------------------------------

echo "[3/3] Launching Claude Code in agent pane..."

# Get agent pane ID
AGENT_PANE=$(cat /tmp/bridge/agent-tmux-bridge/agent_pane 2>/dev/null)

if [ -z "$AGENT_PANE" ]; then
    echo "ERROR: Could not find agent pane."
    exit 1
fi

# Ensure bridge commands are in PATH for the agent pane
tmux send-keys -t "$AGENT_PANE" "export PATH=\"$BRIDGE_HOME/bin:\$PATH\"" Enter
sleep 0.2

# Print bridge instructions for Claude Code
tmux send-keys -t "$AGENT_PANE" "clear" Enter
sleep 0.1
tmux send-keys -t "$AGENT_PANE" "echo '═══════════════════════════════════════'" Enter
sleep 0.1
tmux send-keys -t "$AGENT_PANE" "echo '  agent-tmux-bridge is active!'" Enter
sleep 0.1
tmux send-keys -t "$AGENT_PANE" "echo ''" Enter
sleep 0.1
tmux send-keys -t "$AGENT_PANE" "echo '  You can read the user shell with:'" Enter
sleep 0.1
tmux send-keys -t "$AGENT_PANE" "echo '    bridge read --last 50'" Enter
sleep 0.1
tmux send-keys -t "$AGENT_PANE" "echo ''" Enter
sleep 0.1
tmux send-keys -t "$AGENT_PANE" "echo '  You can suggest commands with:'" Enter
sleep 0.1
tmux send-keys -t "$AGENT_PANE" "echo '    bridge send \"<command>\"'" Enter
sleep 0.1
tmux send-keys -t "$AGENT_PANE" "echo ''" Enter
sleep 0.1
tmux send-keys -t "$AGENT_PANE" "echo '  Check user activity with:'" Enter
sleep 0.1
tmux send-keys -t "$AGENT_PANE" "echo '    bridge status'" Enter
sleep 0.1
tmux send-keys -t "$AGENT_PANE" "echo '═══════════════════════════════════════'" Enter
sleep 0.2

# Now launch Claude Code
tmux send-keys -t "$AGENT_PANE" "claude" Enter

echo ""
echo "=== Bridge is ready! ==="
echo ""
echo "Layout:"
echo "  ┌──────────────────────┬─────────────┐"
echo "  │   User Shell (60%)   │ Agent (40%) │"
echo "  │   Your terminal      │ Claude Code │"
echo "  └──────────────────────┴─────────────┘"
echo ""
echo "Claude Code can now:"
echo "  - Read your terminal with 'bridge read'"
echo "  - Suggest commands that appear in your shell"
echo "  - Commands only execute when YOU press Enter"
echo ""
echo "Attach to session:  tmux attach -t agent-tmux-bridge"
echo "Switch to user pane: Ctrl+B ;"

# If already in tmux, select user pane
if [ -n "${TMUX:-}" ]; then
    USER_PANE=$(cat /tmp/bridge/agent-tmux-bridge/user_pane 2>/dev/null)
    if [ -n "$USER_PANE" ]; then
        tmux select-pane -t "$USER_PANE"
    fi
fi
