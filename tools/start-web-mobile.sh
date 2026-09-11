#!/bin/bash
#
# Launch the web interface, at phone size.
#
#     bash tools/start-web-mobile.sh
#
# Starts the conversation engine and the website, then opens a browser forced into the phone
# layout: one column, WhatsApp-style, with the touch-sized controls — the same interface a
# phone gets, even though you are on a desktop.
#
# Equivalent to:
#
#     bash tools/start.sh --view phone --open desktop
#
# The forced view travels in the URL (`?view=phone`), so it applies to that tab and nothing
# else. If the browser opens it at a desktop width, the page narrows itself to a phone-shaped
# column rather than stretching the layout. Switch to **Auto** or **Desktop** in the header to
# leave the forced view at any time.
#
# Anything you pass is forwarded to start.sh, and an explicit --view or --open wins:
#
#     bash tools/start-web-mobile.sh --port 7990
#     bash tools/start-web-mobile.sh --open none       # just print the URL
#     bash tools/start-web-mobile.sh --stop
#
# To open it on an actual phone, start the desktop version and use your Mac's local address —
# see the wiki page "Using the website".

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULTS=()
case " $* " in
  *" --view "*) ;;
  *) DEFAULTS+=("--view" "phone") ;;
esac
case " $* " in
  *" --open "*) ;;
  *" --stop "*|*" --status "*) ;;
  *) DEFAULTS+=("--open" "desktop") ;;
esac

exec bash "$SCRIPT_DIR/start.sh" "${DEFAULTS[@]}" "$@"
