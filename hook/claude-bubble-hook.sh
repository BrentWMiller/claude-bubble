#!/bin/bash
# Claude Bubble hook: Claude Code runs this on session events, and it hands them to the hook binary, which records
# each session's state for the Claude Bubble app. Never blocks or fails Claude: no output, always exit 0.
B="${CLAUDE_BUBBLE_HOOK_BIN:-$HOME/.claude-bubble/bin/claude-bubble-hook}"
[ -x "$B" ] && exec "$B" >/dev/null 2>&1
exit 0
