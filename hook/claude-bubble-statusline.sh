#!/bin/bash
# Claude Bubble status line wrapper. Claude Code pipes the status line JSON in on stdin; this saves it for the
# bubble (which reads rate_limits.five_hour from it), then runs your own status line command (kept in
# statusline-inner) on the same input, so your status line looks exactly as before. Plain shell only: it runs
# on every status line update.

# Never run inside itself (a status line command that points back here would otherwise loop forever).
[ -n "${CLAUDE_BUBBLE_STATUSLINE:-}" ] && exit 0
export CLAUDE_BUBBLE_STATUSLINE=1

dir="${CLAUDE_BUBBLE_DIR:-$HOME/.claude-bubble}"
input=$(cat; printf x)
input=${input%x}

if [[ $input == *'"five_hour"'* ]] && { [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null; }; then
  tmp="$dir/.usage.$$"
  printf '%s' "$input" > "$tmp" 2>/dev/null && mv -f "$tmp" "$dir/usage.json" 2>/dev/null || rm -f "$tmp" 2>/dev/null
fi

inner=""
[ -f "$dir/statusline-inner" ] && inner=$(<"$dir/statusline-inner")
[ -z "$inner" ] && exit 0
printf '%s' "$input" | bash -c "$inner"
