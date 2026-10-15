#!/bin/bash
# Exercises hook/claude-bubble-statusline.sh against a temp bubble dir.
set -u
WRAP="$(cd "$(dirname "$0")/.." && pwd)/hook/claude-bubble-statusline.sh"
export CLAUDE_BUBBLE_DIR="$(mktemp -d)"
D="$CLAUDE_BUBBLE_DIR"
fail=0
check() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }
usage_field() { /usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$D/usage.json" "$1" 2>/dev/null || echo "<none>"; }

IN='{"model":{"id":"x"},"rate_limits":{"five_hour":{"used_percentage":77.5,"resets_at":1800003600}}}'

out=$(printf '%s' "$IN" | "$WRAP"; echo "exit=$?")
check '[ "$out" = "exit=0" ]' "no inner command prints nothing"
check '[ "$(usage_field used_percentage)" = "77.5" ]' "writes used_percentage"
check '[ "$(usage_field resets_at)" = "1800003600" ]' "writes resets_at"
check '[ "$(usage_field captured_at)" != "<none>" ]' "writes captured_at"

printf '%s' 'jq -r .model.id; echo line2' > "$D/statusline-inner"
out=$(printf '%s' "$IN" | "$WRAP")
check '[ "$out" = "$(printf "x\nline2")" ]' "inner command gets the same stdin, output passes through"

printf '%s' 'cat | wc -c | tr -d " "' > "$D/statusline-inner"
out=$(printf '%s' "$IN" | "$WRAP")
check '[ "$out" = "${#IN}" ]' "inner with pipe sees the whole input"

rm "$D/usage.json"
printf '%s' 'echo hi' > "$D/statusline-inner"
out=$(printf '%s' '{"model":{"id":"x"}}' | "$WRAP")
check '[ "$out" = "hi" ] && [ ! -e "$D/usage.json" ]' "no rate limits: nothing written, still passes through"

out=$(printf 'not json' | "$WRAP")
check '[ "$out" = "hi" ] && [ ! -e "$D/usage.json" ]' "bad JSON still passes through"

printf '%s' 'echo boom; exit 3' > "$D/statusline-inner"
out=$(printf '%s' "$IN" | "$WRAP"; echo "exit=$?")
check '[ "$out" = "$(printf "boom\nexit=3")" ]' "keeps the inner exit code"

check '[ "$(ls -A "$D" | sort | tr "\n" " ")" = "statusline-inner usage.json " ]' "no stray temp files"

rm -rf "$D"
[ $fail -eq 0 ] && echo "all statusline tests passed"
exit $fail
