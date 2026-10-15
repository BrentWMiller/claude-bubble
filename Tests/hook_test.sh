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

# I-1: failed or denied tools leave "needs" for "working"
send '{"hook_event_name":"PermissionRequest","session_id":"f","tool_use_id":"t1"}'
send '{"hook_event_name":"PostToolUseFailure","session_id":"f","tool_use_id":"t1"}'; expect f working "PostToolUseFailure -> working"
send '{"hook_event_name":"PermissionRequest","session_id":"f","tool_use_id":"t2"}'
send '{"hook_event_name":"PermissionDenied","session_id":"f","tool_use_id":"t2"}';   expect f working "PermissionDenied -> working"
send '{"hook_event_name":"SessionEnd","session_id":"f"}'

# I-2: auto-compact / resume keep the current state and don't reopen the replay window
export CLAUDE_BUBBLE_REPLAY_WINDOW=3
send '{"hook_event_name":"SessionStart","session_id":"c","source":"startup"}'
send '{"hook_event_name":"UserPromptSubmit","session_id":"c"}'
/usr/bin/python3 -c 'import json,sys;p=sys.argv[1];d=json.load(open(p));d["started_at"]=0;json.dump(d,open(p,"w"))' "$S/c.json"
send '{"hook_event_name":"SessionStart","session_id":"c","source":"compact"}';       expect c working "compact SessionStart keeps working"
send '{"hook_event_name":"PermissionRequest","session_id":"c","tool_use_id":"t9"}';  expect c needs "events right after compact still count"
send '{"hook_event_name":"SessionStart","session_id":"c","source":"clear"}';         expect c idle "clear SessionStart -> idle"
send '{"hook_event_name":"SessionEnd","session_id":"c"}'
export CLAUDE_BUBBLE_REPLAY_WINDOW=0

# I-4: a pending permission survives other subagents' tool events
send '{"hook_event_name":"UserPromptSubmit","session_id":"p"}'
send '{"hook_event_name":"PermissionRequest","session_id":"p","tool_use_id":"a1"}'
send '{"hook_event_name":"PreToolUse","session_id":"p","tool_use_id":"b1"}';         expect p needs "other subagent PreToolUse keeps needs"
send '{"hook_event_name":"PostToolUse","session_id":"p","tool_use_id":"b1"}';        expect p needs "other subagent PostToolUse keeps needs"
send '{"hook_event_name":"PostToolUse","session_id":"p","tool_use_id":"a1"}';        expect p working "approved tool finishing clears needs"
send '{"hook_event_name":"PermissionRequest","session_id":"p","tool_use_id":"a2"}'
send '{"hook_event_name":"Stop","session_id":"p"}';                                  expect p idle "Stop clears pending permissions"
send '{"hook_event_name":"PreToolUse","session_id":"p","tool_use_id":"a3"}';         expect p working "nothing pending after Stop"
send '{"hook_event_name":"SessionEnd","session_id":"p"}'

out=$(printf 'not json' | "$HOOK"; echo "exit=$?"); check '[ "$out" = "exit=0" ]' "garbage stdin exits 0 silently"
out=$(printf '' | "$HOOK"; echo "exit=$?");         check '[ "$out" = "exit=0" ]' "empty stdin exits 0 silently"
send '{"hook_event_name":"Stop","session_id":"../evil"}'; check '[ ! -e "$CLAUDE_BUBBLE_DIR/evil.json" ]' "path-like session id rejected"
send '{"hook_event_name":"Stop"}'
check '[ "$(ls -A "$S")" = "r.json" ]' "no stray files (missing id, temp files)"

rm -rf "$CLAUDE_BUBBLE_DIR"
[ $fail -eq 0 ] && echo "all hook tests passed"
exit $fail
