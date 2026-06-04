---
name: agent-tmux-bridge
description: |
  Use when you (Claude Code) are in a tmux pane and the agent-tmux-bridge is active.
  Teaches you to observe the user's shell, suggest commands, check activity status,
  respect cooldowns, and handle validator rejections. Triggered when the user mentions
  the bridge, bridge commands, or when BRIDGE_SESSION / BRIDGE_RUN_DIR env vars exist.
---

# agent-tmux-bridge — Skill for Claude Code

You are running inside a **bridge session**: a tmux environment with two panes — the
**user's shell** (where they work) and your **agent pane** (where you run). You can
observe their terminal and inject suggested commands that appear as if they typed them.
**The user always presses Enter to execute** — you only suggest.

## What you can do

| Action | Command | Purpose |
|--------|---------|---------|
| **Observe** | `bridge read --last 50` | See recent output in the user's shell |
| **Observe** | `bridge read --visible` | See what's currently on screen |
| **Observe** | `bridge read --full` | Read the entire scrollback buffer |
| **Observe** | `bridge read --since "ERROR"` | Read content since the last error marker |
| **Suggest** | `bridge send "command"` | Type a command into the user's shell |
| **Check** | `bridge status` | Is the user ready, or busy typing? |
| **Check** | `bridge status --json` | Same, as machine-readable JSON |
| **Wait** | `bridge status --wait 30` | Block until user is idle (up to N seconds) |
| **Test** | `bridge send --dry-run "cmd"` | See if a command would pass validation |

## Core workflow

Every time you want to suggest something, follow this sequence **in order**:

### 1. Observe the user's shell

Read relevant context before acting. Don't suggest commands blindly.

```bash
bridge read --last 50
```

Adjust the number of lines based on how much context you need:
- **Quick check** (what command just ran?): `--last 20`
- **Understand a task** (what are they working on?): `--last 80`
- **Full investigation**: `--full` (but be aware this can be very large)

### 2. Check if the user is idle

**Always check before sending.** If the user is typing, your injection will fail.

```bash
bridge status --json
```

Parse the JSON:
- `"blocked": true` → user is busy. **Wait, don't send.**
- `"blocked": false` → user is idle. You can send.

If blocked, use `bridge status --wait 30` to politely wait. For longer waits, poll
with a loop that checks every second and reports back.

### 3. Send the command

Once the user is idle, inject your suggestion:

```bash
bridge send "your suggested command here"
```

**The command will appear in the user's shell character-by-character as if they typed
it.** They can edit it before pressing Enter. You do NOT press Enter for them (by
default).

### 4. Interpret the result

`bridge send` returns exit codes and JSON on stdout. Both matter.

## Exit codes from `bridge send`

| Exit | Meaning | What you should do |
|------|---------|-------------------|
| **0** | ✓ Command injected successfully | Tell the user what you suggested and why |
| **1** | ✗ Blocked — cooldown window active | Wait. `bridge status --wait 30` then retry |
| **2** | ✗ Rejected by validator | Read the JSON `reason` field. Explain to user. Do NOT resend the same command |
| **3** | ✗ Blocked — pane state (vim, copy mode, etc.) | Wait. Try again when the user returns to shell |
| **4** | ✗ Injection failed (technical error) | Check daemon is running. Report the issue |
| **5** | ✗ Pre-sanitization rejected | Command contains dangerous content (control chars, newlines, Unicode attacks). Do NOT attempt to bypass. Explain to user |

### Parsing the JSON output

```bash
# Capture both stdout and exit code
result=$(bridge send "git status")
code=$?

if [ $code -eq 0 ]; then
    echo "Command sent: $(echo "$result" | grep -o '"command":"[^"]*"')"
elif [ $code -eq 2 ]; then
    echo "Rejected: $(echo "$result" | grep -o '"reason":"[^"]*"')"
fi
```

## When to avoid sending — the blocking conditions

The bridge blocks injection when:

1. **Cooldown active**: The user typed something in the last `COOLDOWN_SECONDS` (default 5s). Cursor movement and shell prompt hooks feed the activity state machine.
2. **Copy/scroll mode**: The user pressed `Ctrl+B [` and is scrolling history.
3. **Alternate screen**: The user is in vim, less, man, htop, or any full-screen app.
4. **Non-shell process**: The foreground process in the user's pane is not a shell (e.g., a running server, a Python REPL, etc.).

**Always check `bridge status` before sending.** It costs ~200ms and avoids failed injections.

## Validator awareness

The bridge may have an **external validator** — an independent executable that approves
or rejects every command. You do NOT self-police; the validator is the authority.

- The validator is locked at `bridge init` time. You cannot change or bypass it via
  environment variables (the lock file prevents this).
- If `bridge send` returns exit `2` or `5`, **respect the rejection**. Don't try to
  rephrase and resend the same command — it will be rejected again.
- Exit `5` means the command failed **pre-sanitization** (Layer 1). This checks for
  control characters, newlines, null bytes, Unicode bidi overrides, and other injection
  attacks. These commands are fundamentally unsafe to send via `tmux send-keys`.

### If the validator rejects a legitimate command

Tell the user: "The validator blocked this command. You can run it manually: `<cmd>`."
The user can type it themselves — they're not blocked from doing so.

## Best practices

### Do

- **Read before sending.** Know what the user is doing before suggesting.
- **Check status before every send.** Even if you just read — the user might have
  started typing in between.
- **Wait politely.** Use `bridge status --wait 30` instead of busy-looping.
- **Explain your suggestions.** After a successful send, tell the user WHY you
  suggested that command. They may not execute it if they don't understand.
- **Handle rejections gracefully.** Explain what happened and offer alternatives.
- **Respect the cooldown.** The cooldown exists so you don't interrupt the user's
  flow. A blocked status is normal — wait for it to pass.
- **Use `--dry-run` for dangerous-looking commands** before sending, so you can
  see if the validator would reject them.
- **Check exit codes.** Don't just fire-and-forget. `bridge send` gives you rich
  feedback — use it.

### Don't

- **Don't spam.** If you're blocked, wait. Don't retry `bridge send` in a tight
  loop — the daemon polls at 200ms intervals, the cooldown won't change faster
  than that.
- **Don't resend rejected commands.** If the validator says no, it means no.
- **Don't try to bypass the validator.** The lock mechanism prevents env var tricks.
  Even if you could, you shouldn't — the validator is there for safety.
- **Don't send while the user is in vim/less.** Wait for them to return to the shell.
- **Don't send multi-line commands.** The pre-sanitizer rejects newlines. If you need
  a multi-line construct, use `&&` or `;` on a single line, or tell the user to type
  it themselves.
- **Don't use `--yes` / `--no-interactive` lightly.** Auto-executing commands
  bypasses the human-in-the-loop guarantee. Only use if the user explicitly asked
  for it, and confirm first.
- **Don't use `--skip-validator` unless the user explicitly instructed you to.**
  This flag exists for emergencies only.
- **Don't use `--allow-malicious-access`.** Ever. If you think you need it, you
  don't. This disables pre-sanitization and opens the door to injection attacks.

## Error recovery patterns

### User is always blocked (cooldown never expires)

1. Check `bridge status` — is shell integration active?
2. Without shell integration, the daemon uses cursor-only detection (more sensitive
   to false positives). Wait longer.
3. The user may be holding a key or have a running process that moves the cursor.
   Wait for a natural prompt.

### Validator keeps rejecting commands

1. Read the rejection reason from stderr/JSON.
2. Tell the user why. They may need to update the validator configuration.
3. The user can always type the command manually.

### Daemon not running

1. This shouldn't happen if `bridge init` completed.
2. Tell the user: "The bridge daemon appears to have stopped. Run `bridge init`
   again to restart it."

### `bridge send` returns exit 4 (injection failed)

1. This is a technical error — likely the user pane can't be found.
2. Check if the tmux session still exists: `tmux list-sessions`
3. Check if the bridge run directory exists: `ls $BRIDGE_RUN_DIR`

## Multi-turn interactions

When helping the user over multiple turns:

1. **First turn**: `bridge read` to understand context, then suggest.
2. **After user runs a command**: Read again to see the output. Don't assume
   what happened — the command might have failed, or the user might have edited
   it before pressing Enter.
3. **Long-running commands**: If the user runs `npm run build` or similar,
   use `bridge read --last 30` periodically to check progress. Look for error
   markers or success indicators in the output.
4. **Debugging sessions**: Alternate between reading output and suggesting
   next steps. Be a pair programmer, not a lecturer.

## Integration detection

At session start, check if the bridge is active:

```bash
if [ -n "${BRIDGE_RUN_DIR:-}" ] && [ -d "$BRIDGE_RUN_DIR" ]; then
    # Bridge is active — you can use bridge commands
    bridge status
else
    # No bridge detected — you're in a normal shell
fi
```

The bridge sets these environment variables in the agent pane:
- `BRIDGE_SESSION` — tmux session name
- `BRIDGE_RUN_DIR` — runtime directory (`/tmp/bridge/<session>`)
- `BRIDGE_USER_PANE` — tmux pane ID of the user's shell
- `BRIDGE_AGENT_PANE` — tmux pane ID of your (agent) shell
- `BRIDGE_HOME` — path to the bridge installation

## Quick reference card

```
# Observe
bridge read                    # visible screen
bridge read --last 50          # last 50 lines
bridge read --full             # entire scrollback
bridge read --since "ERROR"    # since last ERROR

# Suggest
bridge send "git status"            # interactive (user presses Enter)
bridge send "npm run build"         # suggest a build
bridge send --dry-run "rm -rf /"    # check validator result
bridge send --yes "echo done"       # auto-execute (CONFIRM FIRST)

# Check activity
bridge status                       # human-readable
bridge status --json                # {"blocked": false, ...}
bridge status --wait 30             # block until idle
bridge status --watch               # continuous status stream
```
