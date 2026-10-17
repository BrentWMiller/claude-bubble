#!/bin/bash
# Claude Bubble hook: Claude Code runs this on session events, and it hands them to the hook binary, which records
# each session's state for the Claude Bubble app. Never blocks or fails Claude: no output, always exit 0.
B="${CLAUDE_BUBBLE_HOOK_BIN:-$HOME/.claude-bubble/bin/claude-bubble-hook}"
# Not exec: if the binary can't run (wrong architecture, blocked), the shim still exits 0.
[ -x "$B" ] && "$B" >/dev/null 2>&1
exit 0
