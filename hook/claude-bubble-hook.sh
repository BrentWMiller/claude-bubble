#!/bin/bash
# Claude Bubble hook: records per-session Claude Code state for the Claude Bubble app.
# Never blocks or fails Claude: output is discarded and the exit code is always 0.
DIR="${CLAUDE_BUBBLE_DIR:-$HOME/.claude-bubble}/sessions"

# read (a builtin), not $(cat …): no subshell or cat on every tool call.
IFS= read -r -d '' PY <<'EOF'
# hashlib and tempfile would add ~50ms to every tool call; zlib and os.open do the job.
import json, os, sys, time, zlib

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
# Subagent and compaction events only feed the orb's motion; they keep whatever state the session is in.
keeps_state = event in ('SubagentStart', 'SubagentStop', 'PreCompact', 'PostCompact')
if state is None and not keeps_state:
    sys.exit(0)

now = time.time()
try:
    with open(path) as f:
        prev = json.load(f)
except Exception:
    prev = {}
if keeps_state:
    state = prev.get('state') or 'working'

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
    b = raw.encode()
    return '%08x%04x' % (zlib.crc32(b), zlib.adler32(b) & 0xffff)


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
    detail = 'Completed' if prompted else 'Idle'
# Subagent and compaction events say nothing new about the session: keep its status line.
if keeps_state and prev_detail:
    detail = prev_detail

# What the orb's surface shows while working (mirrors Motion.forTool in the app).
def motion_for(name):
    if name.startswith('mcp__'):
        return 'mcp'
    for kind, names in (('read', ('Read', 'NotebookRead')), ('search', ('Grep', 'Glob', 'LSP', 'ToolSearch')),
                        ('edit', ('Edit', 'Write', 'MultiEdit', 'NotebookEdit')), ('bash', ('Bash', 'PowerShell')),
                        ('web', ('WebFetch', 'WebSearch')), ('waiting', ('Task', 'Agent'))):
        if name in names:
            return kind
    return 'generating'


# Tool events from inside a subagent don't move the main orb's motion (the main agent is waiting on them).
from_subagent = bool(data.get('agent_id')) and not keeps_state
activity = str(prev.get('activity') or 'generating')
# The main agent's tool calls still running ([tool_use_id, motion], oldest first): parallel calls end in any
# order, and the orb goes back to generating only once none are left.
turn_over = fresh_start or event in ('UserPromptSubmit', 'Stop', 'StopFailure')
in_flight = [] if turn_over else [x for x in prev.get('in_flight', []) if isinstance(x, list) and len(x) == 2]
use_id = str(data.get('tool_use_id') or '')
if fresh_start:
    activity = 'generating'
elif not from_subagent:
    if event in ('UserPromptSubmit', 'PostCompact'):
        activity = 'generating'
    elif event == 'PreToolUse':
        activity = motion_for(tool)
        in_flight = [x for x in in_flight if x[0] != use_id][-19:] + [[use_id, activity]]
    elif event in ('PostToolUse', 'PostToolUseFailure', 'PermissionDenied'):
        if any(x[0] == use_id for x in in_flight):
            in_flight = [x for x in in_flight if x[0] != use_id]
        elif in_flight:
            in_flight.pop()
        activity = str(in_flight[-1][1]) if in_flight else 'generating'
    elif event == 'PreCompact':
        activity = 'compacting'
    elif event == 'SessionStart' and data.get('source') == 'compact':
        activity = 'generating'
activity_since = float(prev.get('activity_since', now)) if prev.get('activity') == activity else now

def counter(name):
    try:
        return int(prev.get(name, 0)) if not fresh_start else 0
    except (TypeError, ValueError):
        return 0
ticks = counter('ticks') + (event == 'PostToolUse')
fails = counter('fails') + (event == 'PostToolUseFailure')
skills = counter('skills') + (event == 'PreToolUse' and tool in ('Skill', 'EnterPlanMode', 'ExitPlanMode'))
# Running subagents ({id: started_at}). Background agents outlive the main turn's Stop, so they aren't cleared then;
# instead one whose SubagentStop never comes (an interrupt) expires after a while.
ttl = float(os.environ.get('CLAUDE_BUBBLE_SUBAGENT_TTL', '2700'))
raw = {} if fresh_start else prev.get('subagents', {})
if isinstance(raw, list):   # written by an older hook
    raw = {str(x): now for x in raw if isinstance(x, str)}
running = {str(k): float(v) for k, v in raw.items() if isinstance(v, (int, float)) and now - float(v) < ttl}
agent = str(data.get('agent_id') or '')
if event == 'SubagentStart' and agent and agent not in running:
    running[agent] = now
elif event == 'SubagentStop':
    running.pop(agent, None)
subagents = running

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
          'state_since': state_since, 'pid': pid, 'tool_ids': tool_ids, 'activity': activity,
          'activity_since': activity_since, 'ticks': ticks, 'fails': fails, 'skills': skills, 'subagents': subagents,
          'in_flight': in_flight, 'transcript': str(data.get('transcript_path') or prev.get('transcript', ''))}
tmp = os.path.join(d, '.tmp-%d-%d' % (os.getpid(), time.time_ns()))
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
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

# Claude runs hooks through a shell; walk past shells to the Claude process that owns this session.
# Only a confirmed non-shell owner is recorded: anything else would be a short-lived process the app
# would see die and drop the session for. 0 means unknown, and the app falls back to staleness.
if [ -z "${CLAUDE_BUBBLE_PID:-}" ]; then
  owner=0
  pid=$PPID
  for _ in 1 2 3 4; do
    line=$(ps -o ppid=,comm= -p "$pid" 2>/dev/null) || break
    read -r parent comm <<< "$line"
    case "${comm##*/}" in
      sh|bash|zsh|dash|-sh|-bash|-zsh) pid=$parent ;;
      *) owner=$pid; break ;;
    esac
    [ -n "$pid" ] || break
  done
  export CLAUDE_BUBBLE_PID="$owner"
fi

# /usr/bin/python3 is usually Apple's shim, which looks up the real interpreter every run (~13ms). Look it up
# once and remember it; if it moves (an Xcode update), the shim finds it again.
BASE="${DIR%/sessions}"
PYTHON=""
[ -r "$BASE/python-path" ] && read -r PYTHON < "$BASE/python-path"
if [ -z "$PYTHON" ] || [ ! -x "$PYTHON" ]; then
  PYTHON=$(/usr/bin/python3 -c 'import sys; print(sys.executable)' 2>/dev/null)
  if [ -n "$PYTHON" ] && [ -x "$PYTHON" ]; then
    mkdir -p "$BASE" 2>/dev/null && echo "$PYTHON" > "$BASE/python-path" 2>/dev/null
  else
    PYTHON=/usr/bin/python3
  fi
fi

"$PYTHON" -c "$PY" "$DIR" >/dev/null 2>&1
exit 0
