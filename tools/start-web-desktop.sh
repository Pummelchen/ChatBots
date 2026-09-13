#!/bin/bash
#
# Launch the web interface, at desktop size.
#
#     bash tools/start-web-desktop.sh
#
# Starts the conversation engine and the website, then opens a browser at the two-pane desktop
# layout. Equivalent to:
#
#     bash tools/start.sh --view desktop --open desktop
#
# Anything you pass is forwarded to start.sh, and an explicit --view or --open wins over the
# defaults here. So:
#
#     bash tools/start-web-desktop.sh --port 7990
#     bash tools/start-web-desktop.sh --open none      # just print the URL
#     bash tools/start-web-desktop.sh --local-only     # 127.0.0.1 only, no LAN access
#     bash tools/start-web-desktop.sh --stop
#
# To see the phone layout on this machine instead, use tools/start-web-mobile.sh.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults, added only when the caller has not supplied their own. Scanning the arguments
# rather than rewriting them means a pair like `--port 7990` is passed through intact.
DEFAULTS=()
case " $* " in
  *" --view "*) ;;
  *) DEFAULTS+=("--view" "desktop") ;;
esac
case " $* " in
  *" --open "*) ;;
  *" --stop "*|*" --status "*) ;;
  *) DEFAULTS+=("--open" "desktop") ;;
esac

exec bash "$SCRIPT_DIR/start.sh" "${DEFAULTS[@]}" "$@"
