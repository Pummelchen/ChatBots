#!/bin/bash
#
# ChatBots installer — for a Mac that has nothing set up for development.
#
# Run it from a Terminal window:
#
#     bash tools/install.sh
#
# It checks the machine, installs a Swift toolchain if there is none, downloads the models,
# builds the app, loads a model once to prove the whole chain works, and leaves a launcher
# you can double-click. Every step is safe to repeat: running it again repairs rather than
# duplicating, so it is always reasonable to just run it again if something went wrong.
#
# The checkpoint the app ships with is always installed; the other entries in the catalogue are
# opt-in, through `--model <alias>` / `--models all` or through the menu this prints when it runs
# on a terminal and was told nothing. `bash tools/install.sh --help` lists the options.
#
# Deliberately plain: `set -u` but not `set -e`, because several steps are allowed to fail
# and are handled explicitly, and a non-developer should see *which* step failed rather than
# a script that stopped silently. No dependencies beyond what macOS already has.

set -u
set -o pipefail

# ── Where things are ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODELS_DIR="$ROOT/models"
APP="$ROOT/dist/ChatBots.app"
LOG_FILE="$ROOT/.install.log"
BUILD_LOG="$ROOT/.install-build.log"

# ── Output ──────────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; BLUE=$'\033[34m'; OFF=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; OFF=""
fi

step()  { printf "\n%s==>%s %s%s%s\n" "$BLUE" "$OFF" "$BOLD" "$*" "$OFF"; }
info()  { printf "    %s\n" "$*"; }
dim()   { printf "    %s%s%s\n" "$DIM" "$*" "$OFF"; }
ok()    { printf "    %s✓%s %s\n" "$GREEN" "$OFF" "$*"; }
warn()  { printf "    %s!%s %s\n" "$YELLOW" "$OFF" "$*"; }
fail()  { printf "    %s✗%s %s\n" "$RED" "$OFF" "$*"; }

die() {
  printf "\n%sInstallation stopped.%s\n\n" "$RED$BOLD" "$OFF" >&2
  printf "%s\n\n" "$*" >&2
  printf "Nothing was left half-installed — it is safe to run this script again.\n" >&2
  printf "A full log is at: %s\n\n" "$LOG_FILE" >&2
  exit 1
}

# ── Options ─────────────────────────────────────────────────────────────────────────
# Read before the log is opened, so `--help` and a usage error print nothing else. The shipped
# checkpoint is always installed — the app's first run uses it and the verification step below
# loads it — so these options only add to it.
MODEL_REQUEST=""
MODELS_ALL=0
INSTALL_ASSUME_YES=0

usage() {
  cat <<'USAGE'
ChatBots installer — checks the machine, downloads the models, builds the app, and leaves a
launcher you can double-click.

usage: bash tools/install.sh [options]

  --model <alias|id>   also download this checkpoint. Repeatable, and a comma-separated list
                       works too. Aliases are listed by `chatbots-cli --list-models`; any
                       Hugging Face repository id (owner/name) is accepted as well.
  --models all         also download every checkpoint in the catalogue (~12 GB in total).
  --yes                do not ask anything; install the shipped checkpoint and whatever the
                       flags named.
  -h, --help           this text.

The checkpoint the app ships with is always installed: the app's first run uses it, and this
installer loads it to prove the install works. Run without options on a terminal and it lists
the catalogue and asks which further ones to fetch; run it from a script or a pipe and it
installs the shipped checkpoint alone.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --model)
      if [ $# -lt 2 ]; then
        printf 'error: --model needs an alias or a repository id\n\n' >&2
        usage >&2
        exit 2
      fi
      MODEL_REQUEST="$MODEL_REQUEST ${2//,/ }"
      shift 2
      ;;
    --models)
      if [ "${2:-}" != "all" ]; then
        printf "error: --models only takes 'all'\n\n" >&2
        usage >&2
        exit 2
      fi
      MODELS_ALL=1
      shift 2
      ;;
    --yes)
      INSTALL_ASSUME_YES=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# Read by `tools/lib/install-models.sh`, which is sourced below; exported so the interface between
# the two files is explicit rather than an accident of sourcing order.
export MODELS_ALL INSTALL_ASSUME_YES

# Everything is logged, so a failure can be diagnosed after the fact.
: > "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

printf "%s\n" "${BOLD}ChatBots installer${OFF}"
dim "Project: $ROOT"
dim "Log:     $LOG_FILE"

# ── Machine checks ──────────────────────────────────────────────────────────────────
# The installer's phases are sourced rather than executed, so they share this script's
# helpers (`die`, `step`, …) and its log. `source=/dev/null` is shellcheck's directive for a
# path computed at run time; every phase file is tracked and checked on its own.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/install-checks.sh"

# ── Models ──────────────────────────────────────────────────────────────────────────
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/install-models.sh"

# ── Build ───────────────────────────────────────────────────────────────────────────
step "Building the app"
info "The first build takes several minutes; later runs are much faster."
dim "Full output: $BUILD_LOG"

if ! (cd "$ROOT" && CONFIG=release bash tools/make-app.sh) > "$BUILD_LOG" 2>&1; then
  fail "The build failed."
  printf "\n    The last lines of the build log:\n\n"
  tail -20 "$BUILD_LOG" | sed 's/^/      /'
  die "The app could not be built. The log above usually names the reason; the full log is:
  $BUILD_LOG"
fi

if [ ! -d "$APP" ]; then
  die "The build reported success but no app was produced at:
  $APP"
fi
ok "Built $APP"

# ── Prove it works ──────────────────────────────────────────────────────────────────
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/install-verify.sh"

# ── Launcher ────────────────────────────────────────────────────────────────────────
step "Creating a launcher"
LAUNCHER_DIR="$HOME/Applications"
LAUNCHER="$LAUNCHER_DIR/ChatBots.command"
mkdir -p "$LAUNCHER_DIR"

# The launcher is generated, and no path is pasted into shell or AppleScript syntax:
# `printf %q` writes each path as a single shell word, and the installer's path is passed to
# osascript as an argument rather than interpolated into the AppleScript source. A checkout
# named with an apostrophe (or a double quote, a backtick or a `$`) therefore cannot break
# the launcher or inject a command into it.
{
  printf '%s\n' '#!/bin/bash'
  printf '%s\n' '# Launches ChatBots. Created by the installer; safe to move or delete.'
  printf 'ROOT=%q\n' "$ROOT"
  printf 'APP=%q\n' "$APP"
  cat <<'LAUNCHER'
cd "$ROOT" || exit 1
if [ ! -d "$APP" ]; then
  osascript -e 'on run argv
    display alert "ChatBots is not built yet" message ("Open Terminal and run:" & return & return & "bash " & (item 1 of argv)) as critical
  end run' "$ROOT/tools/install.sh"
  exit 1
fi
open "$APP"
LAUNCHER
} > "$LAUNCHER"
chmod +x "$LAUNCHER"
# A file made by a script is not quarantined, but the app may have been copied in from
# elsewhere; clearing it here avoids a misleading "damaged" warning.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
ok "Launcher: $LAUNCHER"

# ── Done ────────────────────────────────────────────────────────────────────────────
cat <<EOF

${GREEN}${BOLD}ChatBots is installed.${OFF}

To start it, either:

  · double-click ${BOLD}$LAUNCHER${OFF}
    (in your Applications folder — from Finder, press ⌘⇧A)

  · or run:  open "$APP"

The app starts with two local models talking to each other about a topic you set. The
first turn takes a few seconds while the model loads; after that it is quicker.

${BOLD}If something goes wrong${OFF}

  · Run this script again — it repairs rather than duplicating.
  · The log from this run:        $LOG_FILE
  · The build log:                $BUILD_LOG
  · Where the models live:        $MODELS_DIR
  · Add another checkpoint later: bash tools/install.sh --model huihui9b --yes
    (the catalogue and its aliases:  chatbots-cli --list-models)

${BOLD}Optional: cloud models instead of local ones${OFF}

The app can also talk to any OpenAI-compatible server instead of running models locally.
Click "API" in the app and give it a URL. With LM Studio running on this Mac the URL is
http://localhost:1234/v1 — and no model download is needed at all in that case.

EOF
