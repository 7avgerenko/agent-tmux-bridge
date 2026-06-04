#!/usr/bin/env bash
# =============================================================================
# reject-dangerous.sh -- Reject known dangerous command patterns
# =============================================================================
# An EXAMPLE validator that blocks obviously destructive commands.
# NOT comprehensive — use a more sophisticated validator for production.
#
# Usage:
#   Template mode:  VALIDATOR="./config/sanitizers/reject-dangerous.sh {}"
#   Stdin mode:     VALIDATOR="stdin:./config/sanitizers/reject-dangerous.sh"
#
# Contract:
#   - $1 or STDIN: command to validate
#   - Returns 0 = ALLOW (outputs command), non-zero = REJECT (reason on stderr)
# =============================================================================

cmd="${1:-$(cat)}"

# ---- Block destructive filesystem operations ----
if echo "$cmd" | grep -qE '\brm\s+.*-rf?\s+/'; then
    echo "REJECTED: destructive rm -rf on root: $cmd" >&2
    exit 1
fi

if echo "$cmd" | grep -qE '\bdd\s+.*of=/dev/[a-z]+'; then
    echo "REJECTED: dd writing to block device: $cmd" >&2
    exit 1
fi

if echo "$cmd" | grep -qE '\bmkfs\b'; then
    echo "REJECTED: filesystem creation: $cmd" >&2
    exit 1
fi

# ---- Block privilege escalation combined with destruction ----
if echo "$cmd" | grep -qE '\bsudo\s+.*rm\s+.*-rf\s+/'; then
    echo "REJECTED: sudo rm -rf on root: $cmd" >&2
    exit 1
fi

if echo "$cmd" | grep -qE '\bchmod\s+.*777\s+/'; then
    echo "REJECTED: chmod 777 on root: $cmd" >&2
    exit 1
fi

if echo "$cmd" | grep -qE '\bchown\s+.*-R\s+/'; then
    echo "REJECTED: recursive chown on root: $cmd" >&2
    exit 1
fi

# ---- Block curl/wget piped to shell ----
if echo "$cmd" | grep -qE '\b(curl|wget)\s+.*\|\s*(bash|sh|zsh)'; then
    echo "REJECTED: curl/wget piped to shell: $cmd" >&2
    exit 1
fi

# ---- Block fork bombs ----
if echo "$cmd" | grep -qE ':\(\)\s*\{\s*:\|:&\s*\}\s*;:'; then
    echo "REJECTED: fork bomb pattern detected: $cmd" >&2
    exit 1
fi

if echo "$cmd" | grep -qE '\b:\(\)\s*\{'; then
    echo "REJECTED: potential fork bomb: $cmd" >&2
    exit 1
fi

# ---- Block data exfiltration patterns ----
if echo "$cmd" | grep -qE '\b(nc|netcat|telnet)\s+.*<.*/(etc/passwd|etc/shadow)'; then
    echo "REJECTED: potential data exfiltration: $cmd" >&2
    exit 1
fi

# ---- Block disabling protections ----
if echo "$cmd" | grep -qE '\bsetenforce\s+0\b'; then
    echo "REJECTED: disabling SELinux: $cmd" >&2
    exit 1
fi

if echo "$cmd" | grep -qE '\biptables\s+-F\b'; then
    echo "REJECTED: flushing iptables: $cmd" >&2
    exit 1
fi

if echo "$cmd" | grep -qE '\bufw\s+disable\b'; then
    echo "REJECTED: disabling firewall: $cmd" >&2
    exit 1
fi

# ---- Pass through: command looks safe ----
echo "$cmd"
exit 0
