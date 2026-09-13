#!/bin/bash
#
# Start the ChatBots web interface.
#
#     bash tools/start.sh
#
# Brings up the conversation engine and, where Caddy is installed, puts Caddy in front of it
# on port 7788. The engine listens on 7789 on loopback and is never exposed directly.
#
#     browser ──▶ :7788 Caddy ──┬──▶ /         the web interface
#                                └──▶ /api/*   the engine
#
# If Caddy is not installed the engine serves the interface itself on 7788, so the web
# interface works either way — it just does not get Caddy's compression and access logging.
# Nothing here needs the SwiftUI app: the web interface and the desktop app are two front
# ends onto the same engine, and either can run without the other.
#
# Options:
#   --port <n>       port for the web interface   (default 7788)
#   --engine <n>     port for the engine          (default 7789)
#   --foreground     stay attached and show logs  (default: same)
#   --stop           stop whatever is running
#   --status         report what is running
#   --open <where>   desktop | mobile | none   (default: none — print the URL)
#   --view <mode>    auto | phone | desktop    (default: auto)
#
# `--view phone` forces the single-column phone layout even in a desktop browser, which is
# what `start-web-mobile.sh` uses. The page honours `?view=` on load and remembers nothing, so
# the mode is a property of the URL rather than of the browser.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT" || exit 1

PORT=7788
ENGINE_PORT=7789
ACTION=run
OPEN_WHERE=none
VIEW_MODE=auto
LOG_DIR="$ROOT/.run"
ENGINE_LOG="$LOG_DIR/engine.log"
CADDY_LOG="$LOG_DIR/caddy.log"
ENGINE_PID="$LOG_DIR/engine.pid"
CADDY_PID="$LOG_DIR/caddy.pid"

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="${2:-}"; shift 2 ;;
    --engine) ENGINE_PORT="${2:-}"; shift 2 ;;
    --foreground) ACTION=run; shift ;;
    --open) OPEN_WHERE="${2:-none}"; shift 2 ;;
    --view) VIEW_MODE="${2:-auto}"; shift 2 ;;
    --stop) ACTION=stop; shift ;;
    --status) ACTION=status; shift ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; BLUE=$'\033[34m'; OFF=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; OFF=""
fi
step() { printf "%s==>%s %s\n" "$BLUE" "$OFF" "$*"; }
ok()   { printf "    %s✓%s %s\n" "$GREEN" "$OFF" "$*"; }
warn() { printf "    %s!%s %s\n" "$YELLOW" "$OFF" "$*"; }
fail() { printf "    %s✗%s %s\n" "$RED" "$OFF" "$*"; }
dim()  { printf "    %s%s%s\n" "$DIM" "$*" "$OFF"; }

mkdir -p "$LOG_DIR"

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

is_our_process() {
  # Ownership is decided from the whole command line, never from the bare name. A pid file
  # outlives the process it named and the OS can hand that number to an unrelated program, so
  # a live pid is not on its own evidence that the process belongs to ChatBots.
  local command
  command="$(ps -p "$1" -o command= 2>/dev/null)" || true
  case "$command" in
    *chatbots*|*caddy*) return 0 ;;
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

  [ "$stopped" -eq 1 ] && ok "Stopped." || dim "Nothing was running."
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

if [ "$ACTION" = "stop" ]; then
  step "Stopping"
  stop_all
  exit 0
fi
if [ "$ACTION" = "status" ]; then
  show_status
  exit 0
fi

# ── Preconditions ────────────────────────────────────────────────────────────────────

step "Checking"

if ! command -v swift >/dev/null 2>&1; then
  fail "No Swift toolchain found."
  printf "\n  Run the installer first:\n\n      bash tools/install.sh\n\n"
  exit 1
fi

if [ ! -d "$ROOT/models" ] || [ -z "$(ls -A "$ROOT/models" 2>/dev/null)" ]; then
  warn "No models are downloaded yet; the page will work but a turn cannot run."
  printf "      bash tools/install.sh downloads them.\n"
fi

# The name lists are generated from names/, and the web interface from web/. Both are
# embedded in the binary, so a change to either has to be regenerated before the build or the
# app would use the previous version.
if ! python3 "$SCRIPT_DIR/embed-names.py" --check >/dev/null 2>&1; then
  step "Regenerating the embedded name lists"
  python3 "$SCRIPT_DIR/embed-names.py" >/dev/null || {
    fail "Could not regenerate Sources/ChatBotsCore/NameLists.swift"
    exit 1
  }
  ok "name lists regenerated"
fi

if ! python3 "$SCRIPT_DIR/embed-web.py" --check >/dev/null 2>&1; then
  # web/ is the source of truth and WebAssets.swift is generated from it, so regenerating is
  # the right repair — but it overwrites an edit made in the generated file, which is exactly
  # how the interface once drifted and then lost the newer work. Say which way the repair goes
  # rather than doing it silently, and leave `swift test` as the guard that fails on drift.
  step "Regenerating the embedded web interface"
  dim "web/ is the source; an edit made in WebAssets.swift is discarded here."
  python3 "$SCRIPT_DIR/embed-web.py" >/dev/null || {
    fail "Could not regenerate Sources/ChatBotsCore/WebAssets.swift"
    exit 1
  }
  ok "web assets regenerated"
fi

BINARY="$ROOT/.build/release/chatbots-cli"
if [ ! -x "$BINARY" ] || [ "$ROOT/web" -nt "$BINARY" ] || [ "$ROOT/Sources" -nt "$BINARY" ]; then
  step "Building the engine"
  dim "First build only — this takes a few minutes."
  if ! swift build -c release >"$LOG_DIR/build.log" 2>&1; then
    fail "The engine could not be built. See $LOG_DIR/build.log"
    exit 1
  fi
fi
ok "engine binary ready"

# The port must be free, and anything of ours already listening is stopped first rather
# than failing with "address already in use".
if [ -f "$ENGINE_PID" ] && pid_from "$ENGINE_PID" >/dev/null; then
  dim "an engine is already running; restarting it"
  stop_all
fi
if port_busy "$ENGINE_PORT"; then
  fail "Port $ENGINE_PORT is already in use by another program."
  printf "\n  Choose another with:  bash tools/start.sh --engine 7999\n\n"
  exit 1
fi

# ── The engine ───────────────────────────────────────────────────────────────────────

step "Starting the engine"
dim "engine log: $ENGINE_LOG"
"$BINARY" --serve --port "$ENGINE_PORT" >"$ENGINE_LOG" 2>&1 &
ENGINE_PID_VALUE=$!
echo "$ENGINE_PID_VALUE" > "$ENGINE_PID"

ready=0
for _ in $(seq 1 60); do
  if curl -sf --max-time 2 "http://127.0.0.1:$ENGINE_PORT/api/health" >/dev/null 2>&1; then
    ready=1
    break
  fi
  if ! kill -0 "$ENGINE_PID_VALUE" 2>/dev/null; then break; fi
  sleep 1
done

if [ "$ready" -ne 1 ]; then
  fail "The engine did not become ready."
  printf "\n    Last lines of its log:\n\n"
  tail -12 "$ENGINE_LOG" | sed 's/^/      /'
  printf "\n"
  exit 1
fi
ok "engine listening on 127.0.0.1:$ENGINE_PORT"

# ── Caddy, if it is there ────────────────────────────────────────────────────────────

CADDY_BIN="$(command -v caddy || true)"
USE_CADDY=0

if [ -n "$CADDY_BIN" ]; then
  if port_busy "$PORT"; then
    warn "Port $PORT is in use, so Caddy is being skipped."
    dim "The engine will serve the interface on port $ENGINE_PORT instead."
    dim "Stop whatever holds $PORT, or run: bash tools/start.sh --port 7990"
  else
    USE_CADDY=1
  fi
else
  dim "Caddy is not installed — the engine will serve the interface itself."
  dim "To get it:  brew install caddy"
fi

if [ "$USE_CADDY" -eq 1 ]; then
  step "Starting Caddy on port $PORT"
  # The Caddyfile hard-codes 7788/7789, so an alternate port needs a generated config
  # rather than an edit to the repository's copy.
  CONFIG="$ROOT/Caddyfile"
  if [ "$PORT" != "7788" ] || [ "$ENGINE_PORT" != "7789" ]; then
    CONFIG="$LOG_DIR/Caddyfile.runtime"
    sed -e "s|http://:7788|http://:$PORT|" \
        -e "s|127.0.0.1:7789|127.0.0.1:$ENGINE_PORT|g" \
        "$ROOT/Caddyfile" > "$CONFIG"
    dim "using a generated config for the alternate ports: $CONFIG"
  fi

  "$CADDY_BIN" run --config "$CONFIG" --adapter caddyfile >"$CADDY_LOG" 2>&1 &
  CADDY_PID_VALUE=$!
  echo "$CADDY_PID_VALUE" > "$CADDY_PID"

  caddy_ready=0
  for _ in $(seq 1 30); do
    if curl -sf --max-time 2 "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then
      caddy_ready=1
      break
    fi
    if ! kill -0 "$CADDY_PID_VALUE" 2>/dev/null; then break; fi
    sleep 1
  done

  if [ "$caddy_ready" -eq 1 ]; then
    ok "serving through Caddy"
  else
    fail "Caddy did not start; falling back to the engine."
    tail -8 "$CADDY_LOG" | sed 's/^/      /'
    kill -TERM "$CADDY_PID_VALUE" 2>/dev/null
    rm -f "$CADDY_PID"
    USE_CADDY=0
  fi
fi

URL_PORT="$PORT"
if [ "$USE_CADDY" -eq 0 ]; then
  URL_PORT="$ENGINE_PORT"
fi

# ── Ready ────────────────────────────────────────────────────────────────────────────

# A forced view rides in the URL, so the phone layout can be seen on a desktop browser.
PAGE_URL="http://localhost:$URL_PORT"
if [ "$VIEW_MODE" != "auto" ]; then
  PAGE_URL="$PAGE_URL/?view=$VIEW_MODE"
fi

if [ "$OPEN_WHERE" != "none" ]; then
  open "$PAGE_URL" 2>/dev/null || true
fi

cat <<EOF

${GREEN}${BOLD}ChatBots web interface${OFF}

    ${BOLD}$PAGE_URL${OFF}

$( [ "$USE_CADDY" -eq 1 ] \
    && echo "    Served by Caddy on port $PORT; the engine is on 127.0.0.1:$ENGINE_PORT (loopback only)." \
    || echo "    Served by the engine on port $ENGINE_PORT (Caddy not in use)." )

    The page drives the same conversation engine as the desktop app, so either can be
    used on its own and both see the same conversation.
$( [ "$VIEW_MODE" = "phone" ] \
    && echo "
    Forcing the ${BOLD}phone layout${OFF}. Switch to Auto or Desktop in the header to leave it." \
    || true )

${BOLD}Logs${OFF}

    engine    tail -f $ENGINE_LOG
    caddy     tail -f $CADDY_LOG

${BOLD}Stopping${OFF}

    bash tools/start.sh --stop

EOF

# Stay attached: the services are children of this process, and leaving the terminal open
# is the clearest way to show that they are running. Interrupting stops them cleanly.
trap 'printf "\n"; stop_all; exit 0' INT TERM
while true; do
  if ! kill -0 "$ENGINE_PID_VALUE" 2>/dev/null; then
    fail "The engine exited."
    tail -12 "$ENGINE_LOG" | sed 's/^/      /'
    stop_all
    exit 1
  fi
  if [ "$USE_CADDY" -eq 1 ] && ! kill -0 "$CADDY_PID_VALUE" 2>/dev/null; then
    fail "Caddy exited."
    tail -8 "$CADDY_LOG" | sed 's/^/      /'
    stop_all
    exit 1
  fi
  sleep 2
done
