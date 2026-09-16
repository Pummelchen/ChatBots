#!/bin/bash
#
# Process and port handling for `tools/start.sh`.
#
# Sourced, not executed: it works on that script's pid files and ports and uses its output
# helpers. Kept apart because deciding whether a process is ours is the part that must never
# guess, and it is easier to review on its own than in the middle of the startup flow.

# Set by `tools/start.sh` before this file is sourced; naming them here makes the contract
# explicit and fails loudly if the file is ever sourced without it.
PORT="${PORT:?PORT is set by tools/start.sh}"
CADDY_PID="${CADDY_PID:?CADDY_PID is set by tools/start.sh}"
ENGINE_PID="${ENGINE_PID:?ENGINE_PID is set by tools/start.sh}"

# ── Helpers ─────────────────────────────────────────────────────────────────────────

pid_from() {
  local file="$1"
  [ -f "$file" ] || return 1
  local pid
  pid="$(cat "$file" 2>/dev/null)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  printf "%s" "$pid"
}

port_busy() {
  # `lsof` is present on every Mac; a bare connect test would need a client.
  lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

# Where a share link should point.
#
# The engine can only work out its own loopback address, and a link to that is useless on the phone
# the share feature exists for. This script is what publishes the website, so it is the layer that
# knows the address a phone would use; with `--local-only` nothing is published beyond this
# Mac, so loopback is the honest answer there. Prints nothing when no LAN address can be read, and
# the engine then keeps its own default rather than being handed a bad base.
share_base() {
  if [ "$LOCAL_ONLY" -eq 1 ]; then
    printf 'http://127.0.0.1:%s' "$PORT"
    return 0
  fi
  local address=""
  address="$(ipconfig getifaddr en0 2>/dev/null || true)"
  [ -n "$address" ] || address="$(ipconfig getifaddr en1 2>/dev/null || true)"
  if [ -n "$address" ]; then
    printf 'http://%s:%s' "$address" "$PORT"
  fi
  return 0
}

is_our_process() {
  # Ownership is decided from the **executable**, not from a substring of the command line. A pid file
  # outlives the process it named and the OS can hand that number to an unrelated program, so a live pid
  # is not on its own evidence that the process belongs to ChatBots — and neither is a substring match,
  # which is what this used to be: `vim Caddyfile`, `tail -f .run/caddy.log` and anything else with the
  # word in an argument matched, and killing one of those is exactly the collateral damage this check
  # exists to prevent.
  #
  # `comm` is the path the executable was launched from, so the basename is the program itself: the
  # engine is `chatbots-cli` whatever configuration directory it was built into, and Caddy is `caddy`
  # wherever Homebrew put it. A process that renames itself can still impersonate either name, which is
  # out of scope here: another process running as this user can already do anything this script can.
  local command
  command="$(ps -p "$1" -o comm= 2>/dev/null)" || true
  case "${command##*/}" in
    chatbots-cli|caddy) return 0 ;;
    *) return 1 ;;
  esac
}

stop_all() {
  local stopped=0
  for file in "$CADDY_PID" "$ENGINE_PID"; do
    local pid
    if pid="$(pid_from "$file")"; then
      if is_our_process "$pid"; then
        kill -TERM "$pid" 2>/dev/null && stopped=1
        dim "stopped pid $pid ($(basename "$file" .pid))"
      else
        # The pid exists but is not ours: the file is stale and the OS has reused the
        # number. Leave the unrelated process alone and only clear the file, so the next
        # start is not misled by it.
        warn "pid $pid in $(basename "$file") is not a ChatBots process — not signalling it"
      fi
      rm -f "$file"
    fi
  done

  # Anything started outside this script — or left behind by a crash — is stopped by port,
  # so a stale listener does not block the next start with a confusing message.
  for port in "$PORT" "$ENGINE_PORT"; do
    [ -n "$port" ] || continue
    if port_busy "$port"; then
      local pids
      pids="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null)"
      for pid in $pids; do
        # Only ever our own processes: never kill an unrelated service that happens to hold
        # the port.
        if is_our_process "$pid"; then
          kill -TERM "$pid" 2>/dev/null && stopped=1
          dim "stopped pid $pid on port $port"
        fi
      done
    fi
  done

  # An explicit if, not `[ … ] && ok … || dim …`: the `||` branch runs whenever `ok` fails,
  # not only when `stopped` is 0. Both helpers are printf calls that do not fail today, but
  # the intent is a two-way choice and the code should say so.
  if [ "$stopped" -eq 1 ]; then
    ok "Stopped."
  else
    dim "Nothing was running."
  fi
  return 0
}

show_status() {
  local engine_pid caddy_pid
  engine_pid="$(pid_from "$ENGINE_PID" || true)"
  caddy_pid="$(pid_from "$CADDY_PID" || true)"
  step "ChatBots web service"
  if [ -n "$engine_pid" ]; then
    ok "engine   running (pid $engine_pid) on 127.0.0.1:$ENGINE_PORT"
  elif port_busy "$ENGINE_PORT"; then
    warn "port $ENGINE_PORT is in use by something not started by this script"
  else
    dim "engine   not running"
  fi
  if [ -n "$caddy_pid" ]; then
    ok "caddy    running (pid $caddy_pid) on port $PORT"
  else
    dim "caddy    not running"
  fi
  if port_busy "$PORT"; then
    printf "\n  %shttp://localhost:%s%s\n\n" "$BOLD" "$PORT" "$OFF"
  fi
}
