#!/bin/bash
# Claude Bubble hook: records per-session Claude Code state for the Claude Bubble app.
# Never blocks or fails Claude: output is discarded and the exit code is always 0.
DIR="${CLAUDE_BUBBLE_DIR:-$HOME/.claude-bubble}/sessions"

PY=$(cat <<'EOF'
import json, os, sys, tempfile, time

d = sys.argv[1]
window = float(os.environ.get('CLAUDE_BUBBLE_REPLAY_WINDOW', '3'))
data = json.load(sys.stdin)
event = data.get('hook_event_name', '')
sid = str(data.get('session_id', ''))
if not sid or '/' in sid or sid.startswith('.'):
    sys.exit(0)
path = os.path.join(d, sid + '.json')

if event == 'SessionEnd':
    try:
        os.remove(path)
    except FileNotFoundError:
        pass
    sys.exit(0)

ntype = data.get('notification_type', '')
if event == 'Notification':
    state = {'permission_prompt': 'needs', 'idle_prompt': 'idle'}.get(ntype)
else:
    state = {
        'SessionStart': 'idle',
        'UserPromptSubmit': 'working',
        'PreToolUse': 'working',
        'PostToolUse': 'working',
        'PostToolUseFailure': 'working',
        'PermissionDenied': 'working',
        'PermissionRequest': 'needs',
        'Stop': 'idle',
        'StopFailure': 'error',
    }.get(event)
if state is None:
    sys.exit(0)

now = time.time()
try:
    with open(path) as f:
        prev = json.load(f)
except Exception:
    prev = {}

# Auto-compact and resume fire SessionStart mid-session: keep the current state and replay window.
fresh_start = event == 'SessionStart' and data.get('source', 'startup') in ('startup', 'clear')
if event == 'SessionStart' and not fresh_start and prev:
    state = prev.get('state', state)
started = now if fresh_start else float(prev.get('started_at', 0))
# `claude -c` replays old events right after SessionStart; ignore them (peon-ping does the same).
if event not in ('SessionStart', 'UserPromptSubmit') and now - started < window:
    sys.exit(0)

# Permission dialogs still waiting on the user, by tool_use_id. Parallel subagents in the same
# session keep firing tool events, so "needs" must outlive them until its own tool resolves.
pending = set(prev.get('pending', []))
tool_id = data.get('tool_use_id') or '?'
if event in ('UserPromptSubmit', 'Stop', 'StopFailure') or fresh_start or ntype == 'idle_prompt':
    pending.clear()
elif event == 'PermissionRequest' or (ntype == 'permission_prompt' and not pending):
    pending.add(tool_id)
elif event in ('PostToolUse', 'PostToolUseFailure', 'PermissionDenied'):
    pending.discard(tool_id)
    pending.discard('?')
if pending and state == 'working':
    state = 'needs'

os.makedirs(d, exist_ok=True)
record = {'state': state, 'event': event, 'cwd': data.get('cwd', ''), 'updated_at': now, 'started_at': started,
          'pending': sorted(pending)}
fd, tmp = tempfile.mkstemp(dir=d, prefix='.tmp-')
try:
    with os.fdopen(fd, 'w') as f:
        json.dump(record, f)
    os.replace(tmp, path)
except Exception:
    try:
        os.remove(tmp)
    except OSError:
        pass
EOF
)

/usr/bin/python3 -c "$PY" "$DIR" >/dev/null 2>&1
exit 0
