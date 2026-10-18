#!/bin/bash
# Claude Bubble hook: Claude Code runs this on session events, and it hands them to the hook binary, which records
# each session's state for the Claude Bubble app. Never fails Claude: always exit 0. Its only output is a permission
# decision clicked in the bubble, which Claude Code reads from stdout.
B="${CLAUDE_BUBBLE_HOOK_BIN:-$HOME/.claude-bubble/bin/claude-bubble-hook}"
# Not exec: if the binary can't run (wrong architecture, blocked), the shim still exits 0.
[ -x "$B" ] && "$B" 2>/dev/null
exit 0
