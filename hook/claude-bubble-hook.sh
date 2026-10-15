#!/bin/bash
# Claude Bubble hook: records per-session Claude Code state for the Claude Bubble app.
# Never blocks or fails Claude: output is discarded and the exit code is always 0.
DIR="${CLAUDE_BUBBLE_DIR:-$HOME/.claude-bubble}/sessions"

PY=$(cat <<'EOF'
import hashlib, json, os, sys, tempfile, time

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
    state = {'permission_prompt': 'needs', 'elicitation_dialog': 'needs', 'elicitation_url_dialog': 'needs',
             'idle_prompt': 'idle'}.get(ntype)
else:
    state = {
        'SessionStart': 'idle',
        'UserPromptSubmit': 'working',
        'PreToolUse': 'working',
        'PostToolUse': 'working',
        'PostToolUseFailure': 'working',
        'PermissionDenied': 'working',
        'PermissionRequest': 'needs',
        'Elicitation': 'needs',
        'ElicitationResult': 'working',
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
# Once the user has prompted, everything after is live, not replay.
prompted = event == 'UserPromptSubmit' or (bool(prev.get('prompted')) and not fresh_start)
# `claude -c` replays old events right after SessionStart; ignore them (peon-ping does the same).
if not prompted and event != 'SessionStart' and now - started < window:
    sys.exit(0)

# Permission dialogs still waiting on the user, by tool_use_id. Parallel subagents in the same
# session keep firing tool events, so "needs" must outlive them until its own tool resolves.
pending = set(prev.get('pending', []))
def tool_key(payload):
    raw = str(payload.get('tool_name') or '') + json.dumps(payload.get('tool_input'), sort_keys=True, default=str)
    return hashlib.sha1(raw.encode()).hexdigest()[:12]


# PermissionRequest carries no tool_use_id, but the PreToolUse for the same call does.
tool_ids = dict(prev.get('tool_ids', {}))
if event == 'PreToolUse' and data.get('tool_use_id'):
    key = tool_key(data)
    tool_ids.pop(key, None)
    tool_ids[key] = data['tool_use_id']
    while len(tool_ids) > 20:
        tool_ids.pop(next(iter(tool_ids)))
tool_id = data.get('tool_use_id') or (tool_ids.get(tool_key(data)) if event == 'PermissionRequest' else None) or '?'
if event in ('UserPromptSubmit', 'Stop', 'StopFailure') or fresh_start or ntype == 'idle_prompt':
    pending.clear()
elif event == 'PermissionRequest' or (state == 'needs' and event == 'Notification' and not pending):
    pending.add(tool_id)
elif event == 'Elicitation':
    pending.add('elicitation')
elif event == 'ElicitationResult':
    pending.discard('elicitation')
    pending.discard('?')
elif event in ('PostToolUse', 'PostToolUseFailure', 'PermissionDenied'):
    pending.discard(tool_id)
    pending.discard('?')
if pending and state == 'working':
    state = 'needs'

tool = str(data.get('tool_name') or '')
tin = data.get('tool_input') if isinstance(data.get('tool_input'), dict) else {}


def clip(text, n=60):
    text = ' '.join(str(text).split())
    return text if len(text) <= n else text[:n - 1] + '\u2026'


def base(p):
    return os.path.basename(str(p).rstrip('/')) if p else ''


prev_detail = str(prev.get('detail', ''))
if event == 'StopFailure':
    err = data.get('error')
    if isinstance(err, dict):
        err = err.get('message', '')
    detail = clip(err) if err else 'Error'
elif state == 'error':
    detail = prev_detail or 'Error'
elif state == 'needs':
    if event == 'PermissionRequest':
        target = base(tin.get('file_path') or tin.get('notebook_path')) or clip(tin.get('command', ''), 40)
        detail = clip(f'Approve {tool} {target}?' if target else f'Approve {tool}?')
    elif event == 'Elicitation' or ntype in ('elicitation_dialog', 'elicitation_url_dialog'):
        detail = 'Input requested'
    else:
        detail = prev_detail if prev_detail.startswith('Approve') else 'Needs you'
elif state == 'working':
    if event == 'PreToolUse':
        if tool == 'Bash' and tin.get('description'):
            detail = clip(tin['description'])
        elif tool in ('Read', 'Grep', 'Glob'):
            detail = 'Reading files'
        elif tool in ('Edit', 'Write', 'NotebookEdit'):
            name = base(tin.get('file_path') or tin.get('notebook_path'))
            detail = clip(f'Editing {name}') if name else 'Editing files'
        elif tool in ('WebFetch', 'WebSearch'):
            detail = 'Searching the web'
        elif tool in ('Task', 'Agent'):
            detail = 'Running subagent'
        else:
            detail = clip(f'Using {tool}') if tool else 'Working'
    elif event == 'UserPromptSubmit':
        detail = 'Thinking'
    else:
        detail = prev_detail or 'Working'
else:
    detail = 'Idle'

cwd = data.get('cwd') or prev.get('cwd', '')
project = base(cwd) or 'session'
state_since = float(prev.get('state_since', now)) if prev.get('state') == state else now
try:
    pid = int(os.environ.get('CLAUDE_BUBBLE_PID', '0'))
except ValueError:
    pid = 0

os.makedirs(d, exist_ok=True)
record = {'state': state, 'event': event, 'cwd': cwd, 'updated_at': now, 'started_at': started,
          'pending': sorted(pending), 'prompted': prompted, 'project': project, 'detail': detail,
          'state_since': state_since, 'pid': pid, 'tool_ids': tool_ids}
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

# Claude runs hooks through a shell; walk past shells to the Claude process that owns this session.
if [ -z "${CLAUDE_BUBBLE_PID:-}" ]; then
  pid=$PPID
  for _ in 1 2 3 4; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    case "${comm##*/}" in
      sh|bash|zsh|dash|-sh|-bash|-zsh) pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') ;;
      *) break ;;
    esac
    [ -n "$pid" ] || break
  done
  export CLAUDE_BUBBLE_PID="$pid"
fi

/usr/bin/python3 -c "$PY" "$DIR" >/dev/null 2>&1
exit 0
