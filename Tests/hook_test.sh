#!/bin/bash
# Exercises hook/claude-bubble-hook.sh against a temp sessions dir.
set -u
HOOK="$(cd "$(dirname "$0")/.." && pwd)/hook/claude-bubble-hook.sh"
export CLAUDE_BUBBLE_DIR="$(mktemp -d)"
export CLAUDE_BUBBLE_REPLAY_WINDOW=0
S="$CLAUDE_BUBBLE_DIR/sessions"
fail=0

send() { printf '%s' "$1" | "$HOOK"; }
state_of() { /usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["state"])' "$S/$1.json" 2>/dev/null || echo "<none>"; }
expect() {
  local got; got=$(state_of "$1")
  if [ "$got" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3: expected $2, got $got"; fail=1; fi
}
check() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }

send '{"hook_event_name":"SessionStart","session_id":"a","cwd":"/tmp"}'; expect a idle "SessionStart -> idle"
send '{"hook_event_name":"UserPromptSubmit","session_id":"a"}';            expect a working "UserPromptSubmit -> working"
send '{"hook_event_name":"PermissionRequest","session_id":"a"}';           expect a needs "PermissionRequest -> needs"
send '{"hook_event_name":"PostToolUse","session_id":"a"}';                 expect a working "PostToolUse -> working"
send '{"hook_event_name":"Notification","session_id":"a","notification_type":"permission_prompt"}'; expect a needs "permission_prompt -> needs"
send '{"hook_event_name":"Notification","session_id":"a","notification_type":"auth_success"}';      expect a needs "other notification ignored"
send '{"hook_event_name":"Stop","session_id":"a"}';                        expect a idle "Stop -> idle"
send '{"hook_event_name":"Notification","session_id":"a","notification_type":"idle_prompt"}';       expect a idle "idle_prompt -> idle"
send '{"hook_event_name":"PreToolUse","session_id":"a"}';                  expect a working "PreToolUse -> working"
send '{"hook_event_name":"StopFailure","session_id":"a"}';                 expect a error "StopFailure -> error"
send '{"hook_event_name":"SubagentStop","session_id":"a"}';                expect a error "unmapped event ignored"
send '{"hook_event_name":"SessionEnd","session_id":"a"}';                  expect a "<none>" "SessionEnd deletes file"

export CLAUDE_BUBBLE_REPLAY_WINDOW=3
send '{"hook_event_name":"SessionStart","session_id":"r"}'
send '{"hook_event_name":"PermissionRequest","session_id":"r"}';           expect r idle "replayed event inside window ignored"
send '{"hook_event_name":"UserPromptSubmit","session_id":"r"}';            expect r working "prompt inside window still counts"
export CLAUDE_BUBBLE_REPLAY_WINDOW=0

out=$(printf 'not json' | "$HOOK"; echo "exit=$?"); check '[ "$out" = "exit=0" ]' "garbage stdin exits 0 silently"
out=$(printf '' | "$HOOK"; echo "exit=$?");         check '[ "$out" = "exit=0" ]' "empty stdin exits 0 silently"
send '{"hook_event_name":"Stop","session_id":"../evil"}'; check '[ ! -e "$CLAUDE_BUBBLE_DIR/evil.json" ]' "path-like session id rejected"
send '{"hook_event_name":"Stop"}'
check '[ "$(ls -A "$S")" = "r.json" ]' "no stray files (missing id, temp files)"

rm -rf "$CLAUDE_BUBBLE_DIR"
[ $fail -eq 0 ] && echo "all hook tests passed"
exit $fail
