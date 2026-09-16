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
#   --open <where>   open the page in the default browser; `none` only prints the URL
#   --view <mode>    auto | phone | desktop    (default: auto)
#   --local-only     bind 127.0.0.1 only, not every interface
#
# The value of `--open` is not a layout: every value but `none` opens the same URL, and the layout
# comes from `--view`, or from the browser's own width in `auto`.
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
# without printing anything. A missing value is a usage error, and saying so is what a caller
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
# asked for, and it is a file this script wrote and a program this script started. Digits in
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
      # Every value but `none` opens the same URL — the code has no desktop/mobile distinction here,
      # and the help says so now instead of advertising one. Both wrappers pass `--open desktop`,
      # including `start-web-mobile.sh`, which reaches the phone layout through `--view phone`; the
      # old help line read `desktop | mobile | none` and described something that never existed.
      require_value "$1" "${2:-}"
      OPEN_WHERE="${2:-none}"; shift 2 ;;
    --view)
      require_value "$1" "${2:-}"
      VIEW_MODE="${2:-auto}"; shift 2 ;;
    --local-only) LOCAL_ONLY=1; shift ;;
    --stop) ACTION=stop; shift ;;
    --status) ACTION=status; shift ;;
    -h|--help)
      # The header *is* the help: every leading comment line after the shebang is printed, with the
      # `#` and one space removed, stopping at the first line that is not a comment. It used to be
      # `sed -n '2,33p'`, a range that had to be updated by hand and was not — lines 34-36, the
      # `--view phone` explanation, were missing from the help while being in the file.
      awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
      exit 0 ;;
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

# The service helpers (pid files, ports, process ownership, stop and status) live in their own
# file; `source=/dev/null` is shellcheck's directive for a run-time path, and the file is
# tracked and checked on its own.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/start-service.sh"

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
# file was added or removed, so an edited `web/app.js` left the stale build in place.
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
# than being left to report its own loopback port.
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
