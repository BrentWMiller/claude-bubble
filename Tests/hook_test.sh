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
field_of() { /usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],"<none>"))' "$S/$1.json" "$2" 2>/dev/null || echo "<none>"; }
expect_field() {
  local got; got=$(field_of "$1" "$2")
  if [ "$got" = "$3" ]; then echo "ok   $4"; else echo "FAIL $4: expected '$3', got '$got'"; fail=1; fi
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

# Polish #2: a real permission prompt right after `claude "prompt"` startup isn't dropped
export CLAUDE_BUBBLE_REPLAY_WINDOW=3
send '{"hook_event_name":"SessionStart","session_id":"q","source":"startup"}'
send '{"hook_event_name":"UserPromptSubmit","session_id":"q"}'
send '{"hook_event_name":"PermissionRequest","session_id":"q","tool_use_id":"x1"}'; expect q needs "permission right after first prompt counts"
send '{"hook_event_name":"SessionEnd","session_id":"q"}'
export CLAUDE_BUBBLE_REPLAY_WINDOW=0

# Polish #3: MCP input requests ask for the user
send '{"hook_event_name":"UserPromptSubmit","session_id":"m"}'
send '{"hook_event_name":"Elicitation","session_id":"m"}';                          expect m needs "Elicitation -> needs"
send '{"hook_event_name":"PostToolUse","session_id":"m","tool_use_id":"o1"}';       expect m needs "other tool events keep elicitation needs"
send '{"hook_event_name":"ElicitationResult","session_id":"m"}';                    expect m working "ElicitationResult -> working"
send '{"hook_event_name":"Notification","session_id":"m","notification_type":"elicitation_dialog"}';     expect m needs "elicitation_dialog -> needs"
send '{"hook_event_name":"ElicitationResult","session_id":"m"}'
send '{"hook_event_name":"Notification","session_id":"m","notification_type":"elicitation_url_dialog"}'; expect m needs "elicitation_url_dialog -> needs"
send '{"hook_event_name":"SessionEnd","session_id":"m"}'

# Multi-session: project, detail, state_since, pid, tool_ids
export CLAUDE_BUBBLE_PID=4242
send '{"hook_event_name":"SessionStart","session_id":"d","cwd":"/Users/me/code/web-app"}'
expect_field d project web-app "project from cwd"
expect_field d detail Idle "SessionStart detail Idle"
expect_field d pid 4242 "pid written"
send '{"hook_event_name":"UserPromptSubmit","session_id":"d"}';  expect_field d detail Thinking "prompt detail Thinking"
since1=$(field_of d state_since)
sleep 0.05
send '{"hook_event_name":"PreToolUse","session_id":"d","tool_name":"Bash","tool_use_id":"b1","tool_input":{"command":"npm test","description":"Running tests"}}'
expect_field d detail "Running tests" "Bash description detail"
check '[ "$(field_of d state_since)" = "$since1" ]' "state_since unchanged while still working"
send '{"hook_event_name":"PostToolUse","session_id":"d","tool_use_id":"b1"}'; expect_field d detail "Running tests" "PostToolUse keeps detail"
send '{"hook_event_name":"PreToolUse","session_id":"d","tool_name":"Read","tool_use_id":"r1","tool_input":{"file_path":"/a/b.ts"}}'; expect_field d detail "Reading files" "Read detail"
send '{"hook_event_name":"PreToolUse","session_id":"d","tool_name":"Edit","tool_use_id":"e1","tool_input":{"file_path":"/repo/src/auth.ts"}}'; expect_field d detail "Editing auth.ts" "Edit detail"
send '{"hook_event_name":"PreToolUse","session_id":"d","tool_name":"WebSearch","tool_use_id":"w1","tool_input":{"query":"x"}}'; expect_field d detail "Searching the web" "web detail"
send '{"hook_event_name":"PreToolUse","session_id":"d","tool_name":"Task","tool_use_id":"t1","tool_input":{}}'; expect_field d detail "Running subagent" "subagent detail"
send '{"hook_event_name":"PreToolUse","session_id":"d","tool_name":"mcp__db__query","tool_use_id":"m1","tool_input":{}}'; expect_field d detail "Using mcp__db__query" "other tool detail"
send '{"hook_event_name":"PreToolUse","session_id":"d","tool_name":"Edit","tool_use_id":"e2","tool_input":{"file_path":"/repo/src/auth.ts","old_string":"a","new_string":"b"}}'
send '{"hook_event_name":"PermissionRequest","session_id":"d","tool_name":"Edit","tool_input":{"file_path":"/repo/src/auth.ts","old_string":"a","new_string":"b"}}'
expect d needs "permission without tool_use_id -> needs"
expect_field d detail "Approve Edit auth.ts?" "permission detail names the file"
check '[ "$(field_of d state_since)" != "$since1" ]' "state_since resets on state change"
send '{"hook_event_name":"PostToolUse","session_id":"d","tool_use_id":"other"}'; expect d needs "another tool finishing keeps needs (tool_ids correlation)"
expect_field d detail "Approve Edit auth.ts?" "needs keeps Approve detail"
send '{"hook_event_name":"PostToolUse","session_id":"d","tool_use_id":"e2"}';    expect d working "the approved tool finishing clears needs"
send '{"hook_event_name":"PermissionRequest","session_id":"d","tool_name":"Bash","tool_input":{"command":"terraform apply -auto-approve"}}'
expect_field d detail "Approve Bash terraform apply -auto-approve?" "permission detail uses command"
send '{"hook_event_name":"StopFailure","session_id":"d","error":"terraform plan failed"}'; expect_field d detail "terraform plan failed" "error detail string"
send '{"hook_event_name":"StopFailure","session_id":"d","error":{"message":"API overloaded"}}'; expect_field d detail "API overloaded" "error detail object"
send '{"hook_event_name":"StopFailure","session_id":"d"}';                       expect_field d detail "Error" "error detail fallback"
send '{"hook_event_name":"Stop","session_id":"d"}';                              expect_field d detail Completed "Stop detail Completed"
send '{"hook_event_name":"Notification","session_id":"d","notification_type":"idle_prompt"}'; expect_field d detail Completed "idle_prompt after a prompt says Completed"
send '{"hook_event_name":"Elicitation","session_id":"d"}';                       expect_field d detail "Input requested" "elicitation detail"
send '{"hook_event_name":"SessionEnd","session_id":"d"}'

send '{"hook_event_name":"SessionStart","session_id":"e"}';                      expect_field e project session "empty cwd -> project session"
send '{"hook_event_name":"UserPromptSubmit","session_id":"e"}'
send '{"hook_event_name":"PreToolUse","session_id":"e","tool_input":"weird"}';   expect_field e detail "Working" "odd tool_input still writes"
long=$(printf 'Run the whole integration suite against staging\\nthen collect coverage and upload artifacts')
send "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"e\",\"tool_name\":\"Bash\",\"tool_use_id\":\"l1\",\"tool_input\":{\"description\":\"$long\"}}"
check '[ "$(field_of e detail)" = "Run the whole integration suite against staging then collec…" ]' "long description clipped to one 60-char line"
for i in $(seq 1 25); do send "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"e\",\"tool_name\":\"Read\",\"tool_use_id\":\"x$i\",\"tool_input\":{\"file_path\":\"/f$i\"}}"; done
check '[ "$(/usr/bin/python3 -c "import json;print(len(json.load(open(\"$S/e.json\"))[\"tool_ids\"]))")" = 20 ]' "tool_ids capped at 20"
send '{"hook_event_name":"SessionEnd","session_id":"e"}'

unset CLAUDE_BUBBLE_PID
got=$(/usr/bin/python3 - "$HOOK" "$S" <<'PY'
import json, os, subprocess, sys
hook, s = sys.argv[1], sys.argv[2]
subprocess.run(['/bin/sh', '-c', '"%s"' % hook], input=b'{"hook_event_name":"SessionStart","session_id":"w"}')
print('same' if json.load(open(os.path.join(s, 'w.json')))['pid'] == os.getpid() else 'different')
PY
)
check '[ "$got" = same ]' "pid skips the shell to reach the calling process"
send '{"hook_event_name":"SessionEnd","session_id":"w"}'
got=$(/usr/bin/python3 - "$HOOK" "$S" <<'PY'
import json, os, shlex, subprocess, sys
hook, s = sys.argv[1], sys.argv[2]
cmd = shlex.quote(hook)
for _ in range(6):  # deeper than the walk will go; `true;` stops sh from exec-ing away each level
    cmd = '/bin/sh -c ' + shlex.quote('true; ' + cmd)
subprocess.run(['/bin/sh', '-c', 'true; ' + cmd], input=b'{"hook_event_name":"SessionStart","session_id":"w2"}')
print(json.load(open(os.path.join(s, 'w2.json')))['pid'])
PY
)
check '[ "$got" = 0 ]' "unconfirmed owner writes pid 0, not a short-lived shell"
send '{"hook_event_name":"SessionEnd","session_id":"w2"}'

out=$(printf 'not json' | "$HOOK"; echo "exit=$?"); check '[ "$out" = "exit=0" ]' "garbage stdin exits 0 silently"
out=$(printf '' | "$HOOK"; echo "exit=$?");         check '[ "$out" = "exit=0" ]' "empty stdin exits 0 silently"
send '{"hook_event_name":"Stop","session_id":"../evil"}'; check '[ ! -e "$CLAUDE_BUBBLE_DIR/evil.json" ]' "path-like session id rejected"
send '{"hook_event_name":"Stop"}'
check '[ "$(ls -A "$S")" = "r.json" ]' "no stray files (missing id, temp files)"

rm -rf "$CLAUDE_BUBBLE_DIR"
[ $fail -eq 0 ] && echo "all hook tests passed"
exit $fail
