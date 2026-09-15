#!/bin/bash
#
# Launch the macOS app.
#
#     bash tools/start-app.sh
#
# Opens ChatBots.app. The app starts its own engine as a child process and talks to it over
# WebTransport, so this script has little to do that the app does not do itself: it is here so
# the engine can be started deliberately, in the foreground, with its output visible.
#
# The two channels are independent. The app speaks only WebTransport and never asks its engine
# for an HTTP port; the website is served over HTTP by the engine this script starts. So the
# engine started here exists for the web interface — the app works either way, and when an engine
# is already running it adopts that one rather than starting a rival.
#
# Options:
#   --no-engine    just open the app, without also serving the web interface
#   --port <n>     port for the web interface and API (default 7789)
#   --stop         stop the API server this script started, and quit the app if it is open

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT" || exit 1

APP="$ROOT/dist/ChatBots.app"
START_ENGINE=1
ENGINE_PORT=7789
ACTION=run

# The value an option was given, or a message and an exit.
#
# `--port "${2:-}"; shift 2` with the option last shifted nothing — `shift 2` fails when only one
# argument remains — so the case was re-entered with the same argument and the loop ran for ever
# without printing anything (A181). A missing value is a usage error, and saying so is what a caller
# needs; every option that takes one goes through here.
require_value() {
  if [ $# -ge 2 ] && [ -n "$2" ]; then
    return 0
  fi
  echo "$1 needs a value" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --no-engine) START_ENGINE=0; shift ;;
    --port)
      require_value "$1" "${2:-}"
      ENGINE_PORT="${2:-7789}"; shift 2 ;;
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
  # The engine, by the pid this script wrote when it started it. Nothing else is touched: a name-based
  # kill would take out a browser or an editor.
  if pid="$(pid_from "$ENGINE_PID")"; then
    kill -TERM "$pid" 2>/dev/null && dim "stopped the API server (pid $pid)"
    rm -f "$ENGINE_PID"
  fi
  # The app, by exact process *name* — `pgrep -x ChatBots`, not `pkill -f <path>`: the pattern matched any
  # process whose command line merely mentions the bundle, which is how a `tail -f` on the app's log, a
  # second checkout, or an editor with the bundle open comes to be killed by a script that promises in the
  # line above not to touch anything but its own (A190). This is the same rule A189 applied to the engine:
  # the executable decides, never an argument. The name is all there is to go on here because the app was
  # opened with `open`, which gives the script no pid to record.
  app_pids="$(pgrep -x ChatBots 2>/dev/null || true)"
  if [ -n "$app_pids" ]; then
    for pid in $app_pids; do
      kill -TERM "$pid" 2>/dev/null && dim "asked the app to quit (pid $pid)"
    done
  fi
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
if [ -f "$BINARY" ] && "$SCRIPT_DIR/source-newer.sh" "$BINARY" "$ROOT/Sources"; then
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
      "$BINARY_CLI" --serve --transport both --port "$ENGINE_PORT" \
        --transport-port "$((ENGINE_PORT + 1))" >"$ENGINE_LOG" 2>&1 &
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

    The engine keeps running until you run:  bash tools/start-app.sh --stop" \
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
