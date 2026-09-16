#!/usr/bin/env bash
# A190 probe — which processes does `--stop` take out?
#
# The stop path killed the app with `pkill -f "ChatBots.app/Contents/MacOS/ChatBots"` under a comment that
# said it killed by pid, and a pattern over the command line matches anything that merely *mentions* the
# bundle. This runs the old pattern and the new name match over the same decoys, and then over a process
# whose name is exactly what the app's is.
#
# The real app is not started here on purpose: launching it opens a window and an engine on this machine,
# which is a side effect a probe must not have. A process renamed to `ChatBots` is the same case as far as
# `pgrep -x` is concerned, and the probe says so.
#
#   usage: bash AUDIT/baseline/swift64/a190-probe/app-stop.sh

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "$ROOT" || exit 1

failures=0
check() {
  if [ "$2" = "yes" ]; then
    printf '  ok    %s\n' "$1"
  else
    failures=$((failures + 1))
    printf '  FAIL  %s%s\n' "$1" "${3:+ — $3}"
  fi
}

PATTERN="ChatBots.app/Contents/MacOS/ChatBots"
old_matches() { pgrep -f "$PATTERN" 2>/dev/null | grep -qx "$1" && echo yes || echo no; }
new_matches() { pgrep -x ChatBots 2>/dev/null | grep -qx "$1" && echo yes || echo no; }

started=()
# The trap body is written inline: ShellCheck's SC2329 calls a function whose only use is a trap handler
# never invoked once the script ends in `exit`, and the audit does not silence a check to keep a helper.
# The body is the one that function had (A192).
trap 'for pid in "${started[@]:-}"; do kill -TERM "$pid" 2>/dev/null; done' EXIT

echo "decoys — processes that mention the bundle without being it"
labels=(
  "a shell renamed to a tail of the app's log"
  "a shell named something else entirely"
)
names=(
  "tail -f ChatBots.app/Contents/MacOS/ChatBots.log"
  "vim ChatBots.app"
)
for index in 0 1; do
  label="${labels[$index]}"
  name="${names[$index]}"
  bash -c "exec -a '$name' /bin/sleep 30" &
  pid=$!
  started+=("$pid")
  sleep 0.2
  was="$(old_matches "$pid")"
  now="$(new_matches "$pid")"
  printf '  %s\n    old pattern kills it: %s, the stop path now kills it: %s\n' "$label" "$was" "$now"
  check "the stop path does not take out $label" "$([ "$now" = "no" ] && echo yes || echo no)" "it matched"
done

echo
echo "the case the stop path is for, and the one it cannot tell apart"
bash -c "exec -a 'ChatBots.app/Contents/MacOS/ChatBots' /bin/sleep 30" &
same_name=$!
started+=("$same_name")
sleep 0.2
printf '  a process whose name is the bundle path\n    the stop path matches it: %s (that is also the name the real app has, so nothing can tell them apart)\n' "$(new_matches "$same_name")"
check "a process named as the app is matched" "$([ "$(new_matches "$same_name")" = "yes" ] && echo yes || echo no)"
bash -c "exec -a ChatBots /bin/sleep 30" &
app=$!
started+=("$app")
sleep 0.2
matched="$(new_matches "$app")"
printf '  a process named exactly ChatBots\n    the stop path matches it: %s\n' "$matched"
check "the stop path matches a process named ChatBots" "$([ "$matched" = "yes" ] && echo yes || echo no)" \
  "it did not match"

echo
echo "the name the script looks for, run against that process"
# The last match, not the first: the comment above the code names the same command, and the code is what
# the probe is testing.
script_name="$(sed -n 's/.*pgrep -x \([A-Za-z0-9_]*\).*/\1/p' tools/start-app.sh | tail -1)"
if [ -n "$script_name" ]; then
  found="$(pgrep -x "$script_name" 2>/dev/null | grep -qx "$app" && echo yes || echo no)"
  check "the stop path finds a process named ChatBots" "$found" "it looks for '$script_name'"
else
  check "the stop path finds a process named ChatBots" no "the stop path has no pgrep -x in it"
fi

echo
echo "and the script says so"
check "the stop path uses the exact name" \
  "$(grep -q 'pgrep -x ChatBots' tools/start-app.sh && echo yes || echo no)"
check "the name pattern is gone" \
  "$(grep -q 'pkill -f "' tools/start-app.sh && echo no || echo yes)" "start-app.sh still kills by pattern"
check "the header says what --stop does" \
  "$(grep -q 'stop the API server this script started, and quit the app' tools/start-app.sh && echo yes || echo no)"

echo
if [ "$failures" -eq 0 ]; then
  echo "all A190 probe checks passed"
  exit 0
fi
echo "$failures A190 probe check(s) failed"
exit 1
