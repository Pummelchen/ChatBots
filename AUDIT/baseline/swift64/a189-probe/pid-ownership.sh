#!/usr/bin/env bash
# A189 probe — whose pid is it?
#
# The check that decides whether a pid file still names a ChatBots process used to match a substring of
# the command line. This runs the *old* matcher and the real one over the same decoys — a `vim Caddyfile`,
# a `tail -f .run/caddy.log`, and a plain `sleep` — and then over real processes of both kinds the pid
# files can hold, so the check is shown to be neither too loose nor too tight.
#
#   usage: bash AUDIT/baseline/swift64/a189-probe/pid-ownership.sh

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

# The real check, lifted out of the script by name so the probe never has to start one to test this.
is_our_process="$(sed -n '/^is_our_process()/,/^}/p' tools/start.sh)"
our() { ( eval "$is_our_process"; is_our_process "$1" ) && return 0; return 1; }

# The check as it was, for the same pids.
old_is_our() {
  local command
  command="$(ps -p "$1" -o command= 2>/dev/null)" || true
  case "$command" in
    *chatbots*|*caddy*) return 0 ;;
    *) return 1 ;;
  esac
}

started=()
start() { "$@" >/dev/null 2>&1 & started+=("$!"); printf '%s' "$!"; }
cleanup() {
  for pid in "${started[@]:-}"; do kill -TERM "$pid" 2>/dev/null; done
  [ -n "${RUN_DIR:-}" ] && rm -rf "$RUN_DIR"
}
trap cleanup EXIT

echo "decoys — processes whose *arguments* mention the words"
decoy_specs=(
  "a shell that renames itself to grep chatbots:exec -a 'grep chatbots' /bin/sleep 30"
  "a shell that renames itself to tail -f caddy.log:exec -a 'tail -f caddy.log' /bin/sleep 30"
  "a plain sleep:/bin/sleep 30"
)
for spec in "${decoy_specs[@]}"; do
  label="${spec%%:*}"; command="${spec#*:}"
  if [ "${command#exec}" != "$command" ]; then
    bash -c "$command" & pid=$!
  else
    $command & pid=$!
  fi
  started+=("$pid")
  sleep 0.2
  was="$(old_is_our "$pid" && echo yes || echo no)"
  now="$(our "$pid" && echo yes || echo no)"
  printf '  %s\n    old check says ours: %s, the check now says ours: %s\n' "$label" "$was" "$now"
  check "the check refuses $label" "$([ "$now" = "no" ] && echo yes || echo no)" "it said the process was ours"
done

# vim, because that is the example the finding gives — and it is worth measuring twice, in both cases of
# the word: the old matcher was case-sensitive, so `vim Caddyfile` did *not* match it and `vim caddyfile`
# did. The finding's example reproduces only in lowercase, and the probe says so.
if command -v vim >/dev/null 2>&1; then
  for file in Caddyfile caddyfile; do
    vim -u NONE -c 'sleep 30' "$file" >/dev/null 2>&1 & vpid=$!
    started+=("$vpid")
    sleep 0.3
    was="$(old_is_our "$vpid" && echo yes || echo no)"
    now="$(our "$vpid" && echo yes || echo no)"
    printf '  vim %s\n    old check says ours: %s, the check now says ours: %s\n' "$file" "$was" "$now"
    check "the check refuses vim $file" "$([ "$now" = "no" ] && echo yes || echo no)" "it said the process was ours"
  done
fi

echo
echo "the real processes the pid files actually hold"
RUN_DIR="$(mktemp -d)"
.build/out/Products/Debug/chatbots-cli --serve --port 7843 --run-directory "$RUN_DIR" >/dev/null 2>&1 &
engine=$!
started+=("$engine")
for _ in $(seq 1 40); do
  kill -0 "$engine" 2>/dev/null || break
  [ -f "$RUN_DIR/webtransport-cert.pem" ] && break
  sleep 0.25
done
check "the engine is recognised" "$(our "$engine" && echo yes || echo no)" "the check refused its own engine"

if command -v caddy >/dev/null 2>&1; then
  caddyfile="$RUN_DIR/Caddyfile"
  printf 'http://:7844 {\n\trespond "ok"\n}\n' > "$caddyfile"
  caddy run --config "$caddyfile" --adapter caddyfile >/dev/null 2>&1 &
  caddy_pid=$!
  started+=("$caddy_pid")
  sleep 1.5
  check "Caddy is recognised" "$(our "$caddy_pid" && echo yes || echo no)" "the check refused Caddy"
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "all A189 probe checks passed"
  exit 0
fi
echo "$failures A189 probe check(s) failed"
exit 1
