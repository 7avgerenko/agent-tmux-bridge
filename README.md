# agent-tmux-bridge

A tmux-based dual-shell system where an AI agent (Claude Code, etc.) can observe your shell and suggest commands — but **you always press Enter**.

```
┌──────────────────────────┬──────────────┐
│   Your Shell (60%)       │ Agent (40%)  │
│                          │              │
│   $ ls -la               │  Claude Code │
│   $ git status           │              │
│   $ npm run build  ←── injected by agent │
│   █                      │              │
└──────────────────────────┴──────────────┘
```

## How It Works

1. **Two tmux panes**: Your regular shell on the left, an AI agent on the right
2. **Agent reads your shell**: `bridge read --last 50` captures your terminal content
3. **Agent suggests commands**: `bridge send "npm run build"` types the command into your shell
4. **You decide**: The command appears as if you typed it — you can edit it, and only you press Enter
5. **Safety**: An external validator independently approves/rejects every command; the agent does NOT self-police

## Quick Start

```bash
# 1. Start the bridge session
./bin/bridge init

# 2. In the agent pane (right), launch Claude Code or any other agent
claude

# 3. The agent can now:
bridge read              # See your terminal
bridge read --last 50    # See last 50 lines
bridge read --full       # See entire scrollback
bridge send "git diff"   # Suggest a command (you press Enter)
bridge status            # Check if you're busy typing
```

## Commands

### `bridge init`

Create a new bridge session with two panes.

```bash
bridge init                          # Default: horizontal, 60/40 split
bridge init --vertical               # Vertical split
bridge init --name my-session        # Custom session name
bridge init --cooldown 3             # 3-second cooldown after typing
bridge init --validator ./check.sh   # Use custom validator
bridge init --no-attach              # Start detached (for scripts)
```

### `bridge read`

Capture content from your shell.

```bash
bridge read                    # Visible screen content
bridge read --last 50          # Last 50 lines
bridge read --full             # Entire scrollback buffer
bridge read --since "ERROR"    # Content since last "ERROR"
bridge read --raw              # Keep ANSI color codes
```

### `bridge send`

Inject a command suggestion into your shell.

```bash
bridge send "npm test"               # Suggest a command (you press Enter)
bridge send --yes "echo done"        # Auto-execute (bypasses you — use carefully)
bridge send --dry-run "rm -rf /"     # Check what the validator would do
bridge send --skip-validator "..."   # Bypass the validator (use carefully)
```

### `bridge status`

Check if the bridge is blocked (you're typing) or ready.

```bash
bridge status                 # Human-readable
bridge status --json          # JSON output
bridge status --wait 10       # Wait up to 10s for you to be idle
bridge status --watch         # Continuously watch state changes
```

## Validator (External Safety)

The validator is **external** to the AI agent. The agent does NOT check its own commands — that would be unreliable (models can be wrong, non-Anthropic APIs exist). Instead, an independent executable approves or rejects each command.

### Contract

- **Input**: Command text (via stdin or `--input` argument)
- **Output**: Modified command on stdout (or original if unchanged)
- **Exit code**: `0` = ALLOW, `non-zero` = REJECT
- **Stderr**: Rejection reason

### Two Modes

**1. Stdin mode** — command piped to validator:
```bash
VALIDATOR="./config/sanitizers/reject-dangerous.sh"
```

**2. Template mode** — `{}` replaced with the command:
```bash
VALIDATOR="./config/sanitizers/validator.py --input {}"
```

### Built-in Validators

| Validator | Behavior |
|-----------|----------|
| `allow-all.sh` | Pass-through (default — trust the agent) |
| `block-all.sh` | Block everything (read-only mode) |
| `reject-dangerous.sh` | Block `rm -rf /`, `dd`, fork bombs, etc. |
| `require-confirm.sh` | Wrap command in `read -p "Run? [y/N]"` confirmation |
| `validator.py` | Python template — extend with your own rules |

### Writing Your Own Validator

The simplest validator is a shell script:

```bash
#!/usr/bin/env bash
# my-validator.sh
read -r cmd
if echo "$cmd" | grep -q "dangerous"; then
    echo "Blocked: contains 'dangerous'" >&2
    exit 1   # REJECT
fi
echo "$cmd"
exit 0       # ALLOW
```

Or in Python (template mode):

```bash
# Use with: VALIDATOR="./my-checker.py --cmd {}"
VALIDATOR="./my-checker.py --cmd {}" bridge send "some command"
```

See `config/sanitizers/validator.py` for a full Python example with logging, allow/deny lists, and configurable rules.

## Configuration

Configuration is bash-sourceable. Defaults live in `config/default.conf`.

Override via:
1. **User config**: `~/.config/agent-tmux-bridge/bridge.conf`
2. **Environment variables**: `BRIDGE_COOLDOWN_SECONDS=3 bridge send "..."`

Key settings:

| Setting | Default | Description |
|---------|---------|-------------|
| `COOLDOWN_SECONDS` | 5 | Block agent after user types |
| `POLL_INTERVAL_MS` | 200 | Daemon polling rate |
| `VALIDATOR` | "" | Validator executable (empty = allow all) |
| `VALIDATOR_TIMEOUT` | 5 | Seconds before killing hung validator |
| `LAYOUT` | horizontal | Pane split direction |
| `INTERACTIVE_MODE` | true | User must press Enter |
| `BLOCK_ON_COPY_MODE` | true | Block injection during tmux copy mode |
| `BLOCK_ON_ALTERNATE_SCREEN` | true | Block injection in vim/less/etc. |

## Activity Detection

The daemon polls every 200ms to detect whether you're actively typing:

1. **Shell integration** (automatic): Records timestamps when prompts appear, distinguishing your typing from command output
2. **Cursor tracking**: Polls cursor position; movement at a prompt = typing
3. **Fallback mode**: If shell integration can't be sourced, all cursor movement counts as activity (conservative)

When you type, injection is blocked for `COOLDOWN_SECONDS` (default 5s). The agent sees `BLOCKED` and can wait with `bridge status --wait`.

## Blocking Logic

The agent is blocked from injecting when:
- You've typed something in the last `COOLDOWN_SECONDS`
- You're in tmux copy/scroll mode
- You're in an alternate screen (vim, less, man, etc.)
- Your pane isn't running an interactive shell

## Architecture

```
agent-tmux-bridge/
├── bin/
│   ├── bridge              # CLI dispatcher
│   ├── bridge-init         # Session creation + shell integration
│   ├── bridge-read         # Buffer capture
│   ├── bridge-send         # Command injection pipeline
│   ├── bridge-status       # Activity state queries
│   └── bridge-daemon       # Cursor polling + activity detection
├── lib/
│   ├── config.sh           # Configuration loading
│   ├── logging.sh          # Structured logging
│   ├── tmux-helpers.sh     # Pane discovery, cursor reading
│   ├── activity.sh         # Activity state machine
│   ├── capture.sh          # Buffer capture + ANSI stripping
│   ├── validator.sh        # External validator execution
│   └── injection.sh        # send-keys + cooldown gate
├── config/
│   ├── default.conf        # Default configuration
│   └── sanitizers/         # Built-in validators
├── shell-integrations/     # Bash/Zsh/Fish prompt hooks
├── examples/               # Integration examples
└── test/                   # Test suite
```

## Requirements

- **tmux** 2.0+ (tested with 3.3a+)
- **bash** 4.0+
- **Linux** (uses `/proc`, `stat`, `/tmp`)
- Optional: Python 3.6+ (for `validator.py`)

## Testing

```bash
# Quick unit tests (no tmux needed)
./test/test-bridge.sh --quick

# Full integration tests (requires tmux)
./test/test-bridge.sh

# Keep test session for debugging
./test/test-bridge.sh --keep-session
```

## License

MIT

## Development

```bash
# Run tests
./test/test-bridge.sh --quick    # 29 unit tests
./test/test-jailbreak.sh        # 42 jailbreak tests
```
