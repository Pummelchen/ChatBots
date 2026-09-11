#!/bin/bash
#
# Launch the macOS app.
#
#     bash tools/start-app.sh
#
# Opens ChatBots.app, which runs its own conversation engine in-process — the app needs
# nothing else, and will start the models itself when you press Start.
#
# An API server is also brought up, on the same port the website uses, so that the web
# interface can attach to the same conversation while the app is running. That is the point of
# this script over simply double-clicking the app: the desktop window and a browser page then
# show one conversation rather than two.
#
# Options:
#   --no-engine    just open the app, without also serving the web interface
#   --port <n>     port for the API server (default 7789)
#   --stop         stop the API server this script started

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT" || exit 1

APP="$ROOT/dist/ChatBots.app"
PYTHON=python3
START_ENGINE=1
ENGINE_PORT=7789
ACTION=run

while [ $# -gt 0 ]; do
  case "$1" in
    --no-engine) START_ENGINE=0; shift ;;
    --port) ENGINE_PORT="${2:-7789}"; shift 2 ;;
    --stop) ACTION=stop; shift ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

mkdir -p "$ROOT/.run"
ENGINE_PID="$ROOT/.run/app-engine.pid"
ENGINE_LOG="$ROOT/.run/app-engine.log"

pid_from() {
  [ -f "$1" ] || return 1
  local pid; pid="$(cat "$1" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && printf "%s" "$pid"
}

if [ "$ACTION" = "stop" ]; then
  step "Stopping"
  # By PID, never by name: a name-based kill would take out a browser or an editor.
  if pid="$(pid_from "$ENGINE_PID")"; then
    kill -TERM "$pid" 2>/dev/null && dim "stopped the API server (pid $pid)"
    rm -f "$ENGINE_PID"
  fi
  pkill -f "ChatBots.app/Contents/MacOS/ChatBots" 2>/dev/null || true
  echo "    If the app is still open, quit it with ⌘Q."
  exit 0
fi

# ── The app ──────────────────────────────────────────────────────────────────────────

step "Checking the app"

if [ ! -d "$APP" ]; then
  fail "ChatBots.app has not been built yet."
  printf "\n  Run the installer first:\n\n      bash tools/install.sh\n\n"
  exit 1
fi

# A stale build is the usual cause of "I fixed it and nothing changed".
BINARY="$APP/Contents/MacOS/ChatBots"
if [ -f "$BINARY" ] && [ "$ROOT/Sources" -nt "$BINARY" ]; then
  warn "The source is newer than the app; it is being rebuilt first."
  if ! CONFIG=release bash "$SCRIPT_DIR/make-app.sh" >"$ROOT/.run/build.log" 2>&1; then
    fail "The rebuild failed. See $ROOT/.run/build.log"
    exit 1
  fi
  ok "rebuilt"
fi
ok "app ready"

# ── The API server, so the website can share the conversation ────────────────────────

ENGINE_PID_VALUE=""
if [ "$START_ENGINE" -eq 1 ]; then
  step "Starting the API server on port $ENGINE_PORT"
  if pid="$(pid_from "$ENGINE_PID")"; then
    ok "already running (pid $pid)"
    ENGINE_PID_VALUE="$pid"
  else
    BINARY_CLI="$ROOT/.build/release/chatbots-cli"
    if [ ! -x "$BINARY_CLI" ]; then
      dim "building the engine"
      if ! swift build -c release >"$ROOT/.run/build.log" 2>&1; then
        fail "The engine could not be built. See $ROOT/.run/build.log"
        printf "\n  The app will still open; only the web interface will be unavailable.\n\n"
        START_ENGINE=0
      fi
    fi
    if [ "$START_ENGINE" -eq 1 ]; then
      "$BINARY_CLI" --serve --port "$ENGINE_PORT" >"$ENGINE_LOG" 2>&1 &
      ENGINE_PID_VALUE=$!
      echo "$ENGINE_PID_VALUE" > "$ENGINE_PID"
      ready=0
      for _ in $(seq 1 40); do
        curl -sf --max-time 2 "http://127.0.0.1:$ENGINE_PORT/api/health" >/dev/null 2>&1 && { ready=1; break; }
        kill -0 "$ENGINE_PID_VALUE" 2>/dev/null || break
        sleep 1
      done
      if [ "$ready" -eq 1 ]; then
        ok "listening on 127.0.0.1:$ENGINE_PORT"
      else
        fail "It did not start. See $ENGINE_LOG"
        START_ENGINE=0
      fi
    fi
  fi
else
  dim "skipping the API server (--no-engine)"
fi

# ── Launch ───────────────────────────────────────────────────────────────────────────

step "Opening ChatBots"
open "$APP"

cat <<EOF

${GREEN}${BOLD}ChatBots is open.${OFF}

$( [ "$START_ENGINE" -eq 1 ] \
    && echo "    The same conversation is also at ${BOLD}http://localhost:$ENGINE_PORT${OFF} — open it in a
    browser, or on a phone using your Mac's local address, and you will see the one
    the app is having. It appears once the app has fetched some state, so give it a
    moment after you press Start.

    The API server keeps running until you run:  bash tools/start-app.sh --stop" \
    || echo "    No API server is running, so there is no web interface for this session.
    Start it with:  bash tools/start-app.sh" )

    The models load when you press ${BOLD}Start${OFF} — a few seconds the first time.

EOF

if [ "$START_ENGINE" -eq 1 ]; then
  # Stay attached so the server is a child of this process and Control-C stops it.
  trap 'printf "\n"; bash "$0" --stop; exit 0' INT TERM
  while true; do
    kill -0 "${ENGINE_PID_VALUE:-0}" 2>/dev/null || { dim "the API server stopped"; break; }
    sleep 3
  done
fi
