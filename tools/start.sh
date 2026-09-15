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
# Caddy's site address has no host, so by default it binds **every** interface: the website,
# and with it the whole unauthenticated /api/* surface, is reachable by anyone on the same
# network. That is what makes phone access work. Pass --local-only to bind 127.0.0.1 only and
# reach it from this Mac alone.
#
# If Caddy is not installed the engine serves the interface itself on its own port (7789),
# where it is already loopback-only, so the web interface works either way — it just does not
# get Caddy's compression and access logging, and a phone cannot reach it. Nothing here needs
# the SwiftUI app: the web interface and the desktop app are two front ends onto the same
# engine, and either can run without the other.
#
# Options:
#   --port <n>       port for the web interface   (default 7788)
#   --engine <n>     port for the engine          (default 7789)
#   --foreground     stay attached and show logs  (default: same)
#   --stop           stop whatever is running
#   --status         report what is running
#   --open <where>   desktop | mobile | none   (default: none — print the URL)
#   --view <mode>    auto | phone | desktop    (default: auto)
#   --local-only     bind 127.0.0.1 only, not every interface
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
LOCAL_ONLY=0
LOG_DIR="$ROOT/.run"
ENGINE_LOG="$LOG_DIR/engine.log"
CADDY_LOG="$LOG_DIR/caddy.log"
ENGINE_PID="$LOG_DIR/engine.pid"
CADDY_PID="$LOG_DIR/caddy.pid"

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

# A TCP port number, or a message and an exit.
#
# Both port options are interpolated into `sed` programs — one as a replacement, one as a *pattern* —
# and the result is a Caddyfile that Caddy is then asked to run. A value containing `|` ends the `s`
# command early, `&` inserts the text that matched, `/` breaks the address pattern, and a pattern like
# `.*` matches any line at all: the generated config is then mangled, or carries a directive nobody
# asked for, and it is a file this script wrote and a program this script started (A188). Digits in
# range is the whole of the validation that interpolation needs, and doing it here means the value is
# a number by the time any of that runs.
require_port() {
  case "${2:-}" in
    ''|*[!0-9]*)
      echo "$1 needs a port number, not '${2:-}'" >&2
      exit 2
      ;;
  esac
  if [ "$2" -lt 1 ] || [ "$2" -gt 65535 ]; then
    echo "$1 needs a port between 1 and 65535, not '$2'" >&2
    exit 2
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --port)
      require_value "$1" "${2:-}"
      require_port "$1" "${2:-}"
      PORT="$2"; shift 2 ;;
    --engine)
      require_value "$1" "${2:-}"
      require_port "$1" "${2:-}"
      ENGINE_PORT="$2"; shift 2 ;;
    --foreground) ACTION=run; shift ;;
    --open)
      require_value "$1" "${2:-}"
      OPEN_WHERE="${2:-none}"; shift 2 ;;
    --view)
      require_value "$1" "${2:-}"
      VIEW_MODE="${2:-auto}"; shift 2 ;;
    --local-only) LOCAL_ONLY=1; shift ;;
    --stop) ACTION=stop; shift ;;
    --status) ACTION=status; shift ;;
    -h|--help) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# Where a share link should point.
#
# The engine can only work out its own loopback address, and a link to that is useless on the phone
# the share feature exists for. This script is what publishes the website, so it is the layer that
# knows the address a phone would use (A99); with `--local-only` nothing is published beyond this
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
# `tools/source-newer.sh` walks the trees: the directory mtimes this compared changed only when a
# file was added or removed, so an edited `web/app.js` left the stale build in place (A182).
if "$SCRIPT_DIR/source-newer.sh" "$BINARY" "$ROOT/web" "$ROOT/Sources"; then
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
# Share links are built by the engine, so it is told the address the website is published on rather
# than being left to report its own loopback port (A99).
SHARE_BASE="$(share_base)"
ENGINE_ARGS=(--serve --port "$ENGINE_PORT")
if [ -n "$SHARE_BASE" ]; then
  ENGINE_ARGS+=(--share-base "$SHARE_BASE")
  dim "share links: $SHARE_BASE/s/<id>"
fi
"$BINARY" "${ENGINE_ARGS[@]}" >"$ENGINE_LOG" 2>&1 &
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
  # Without Caddy the engine serves the interface itself. Its HTTPServer sets
  # `requiredLocalEndpoint` to 127.0.0.1, so this path is already loopback-only and
  # --local-only has nothing to change here; a phone cannot reach it either way.
  dim "Caddy is not installed — the engine will serve the interface itself on loopback only."
  dim "To get it:  brew install caddy"
fi

if [ "$USE_CADDY" -eq 1 ]; then
  step "Starting Caddy on port $PORT"
  # The Caddyfile's site address is host-less, so its listener is ":PORT" — every interface.
  # An alternate port, or --local-only, needs a generated config rather than an edit to the
  # repository's copy.
  CONFIG="$ROOT/Caddyfile"
  if [ "$PORT" != "7788" ] || [ "$ENGINE_PORT" != "7789" ] || [ "$LOCAL_ONLY" -eq 1 ]; then
    CONFIG="$LOG_DIR/Caddyfile.runtime"
    sed -e "s|http://:7788|http://:$PORT|" \
        -e "s|127.0.0.1:7789|127.0.0.1:$ENGINE_PORT|g" \
        "$ROOT/Caddyfile" > "$CONFIG"
    if [ "$LOCAL_ONLY" -eq 1 ]; then
      # The site address says which Host a request must carry; it does not choose the
      # interface, so naming 127.0.0.1 there would still leave Caddy on ":PORT" (that is
      # what `caddy adapt` reports). `bind` is the directive that picks the listener, so
      # the generated copy gets one and the listener becomes 127.0.0.1:$PORT.
      sed -e "/^http:\/\/:$PORT {/a\\
	bind 127.0.0.1" "$CONFIG" > "$CONFIG.local-only"
      mv "$CONFIG.local-only" "$CONFIG"
      dim "binding the website to 127.0.0.1 only (--local-only)"
    fi
    dim "using a generated config: $CONFIG"
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

# The banner states which interface the website is bound to rather than leaving the reader to
# infer it: Caddy's host-less address is the one thing in this script that is reachable from
# off this Mac, and it is the whole point of --local-only.
SERVED_NOTE="    Served by the engine on 127.0.0.1:$ENGINE_PORT (Caddy not in use, loopback only)."
EXPOSURE_NOTE=""
if [ "$USE_CADDY" -eq 1 ]; then
  if [ "$LOCAL_ONLY" -eq 1 ]; then
    SERVED_NOTE="    Served by Caddy on 127.0.0.1:$PORT only (--local-only). The engine is on 127.0.0.1:$ENGINE_PORT (loopback only)."
  else
    SERVED_NOTE="    Served by Caddy on port $PORT, on every interface. The engine is on 127.0.0.1:$ENGINE_PORT (loopback only)."
    EXPOSURE_NOTE="    Anyone on this network can use the whole interface and API without a password.
    Add --local-only to serve this Mac alone."
  fi
fi

cat <<EOF

${GREEN}${BOLD}ChatBots web interface${OFF}

    ${BOLD}$PAGE_URL${OFF}

$SERVED_NOTE
$EXPOSURE_NOTE

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
