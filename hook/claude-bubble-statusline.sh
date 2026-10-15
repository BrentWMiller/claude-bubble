#!/bin/bash
# Claude Bubble status line wrapper. Claude Code pipes the status line JSON in on stdin; this saves the
# 5-hour usage window (rate_limits.five_hour) for the bubble, then runs your own status line command
# (kept in statusline-inner) on the same input, so your status line looks exactly as before.
dir="${CLAUDE_BUBBLE_DIR:-$HOME/.claude-bubble}"
input=$(cat; printf x)
input=${input%x}

printf '%s' "$input" | /usr/bin/python3 -c '
import json, os, sys, tempfile, time
try:
    limit = json.load(sys.stdin)["rate_limits"]["five_hour"]
    used, resets = limit["used_percentage"], limit["resets_at"]
    if not isinstance(used, (int, float)) or not isinstance(resets, (int, float)):
        sys.exit(0)
    d = sys.argv[1]
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".usage.")
    with os.fdopen(fd, "w") as f:
        json.dump({"used_percentage": used, "resets_at": resets, "captured_at": time.time()}, f)
    os.replace(tmp, os.path.join(d, "usage.json"))
except Exception:
    pass
' "$dir" 2>/dev/null

inner=""
[ -f "$dir/statusline-inner" ] && inner=$(cat "$dir/statusline-inner")
[ -z "$inner" ] && exit 0
printf '%s' "$input" | bash -c "$inner"
