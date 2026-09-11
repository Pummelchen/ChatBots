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

# The default checkpoint, matching `AgentSpec.defaultModelID`.
MODEL_ID="mlx-community/Qwen3.5-4B-MLX-4bit"
MODEL_DIR_NAME="Qwen3.5-4B-MLX-4bit"

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

# Everything is logged, so a failure can be diagnosed after the fact.
: > "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

printf "%s\n" "${BOLD}ChatBots installer${OFF}"
dim "Project: $ROOT"
dim "Log:     $LOG_FILE"

# ── Disk space ──────────────────────────────────────────────────────────────────────
# Checked first, because a 3 GB download that runs out of room at 90% is the worst
# experience this script can give someone.
REQUIRED_GB=8
free_gb() {
  df -g / 2>/dev/null | awk 'NR==2 {print $4}'
}

step "Checking this Mac"
FREE_GB="$(free_gb)"
if [ -z "$FREE_GB" ]; then
  warn "Could not read free disk space; continuing without the check"
else
  dim "Free disk space: ${FREE_GB} GB"
  if [ "$FREE_GB" -lt "$REQUIRED_GB" ]; then
    die "This needs about ${REQUIRED_GB} GB free — the models alone are ~6 GB and the build
needs a few more. There is ${FREE_GB} GB free.

Free some space and run the script again. The model folder can be found later at:
  $MODELS_DIR"
  fi
  ok "Enough disk space (${FREE_GB} GB free)"
fi

ARCH="$(uname -m)"
if [ "$ARCH" != "arm64" ]; then
  die "This app runs the models on the Apple Neural/GPU stack, which needs Apple silicon.
This Mac reports: $ARCH (Intel).

It will not run here."
fi
ok "Apple silicon ($ARCH)"

OS_VERSION="$(sw_vers -productVersion)"
OS_MAJOR="${OS_VERSION%%.*}"
if [ "$OS_MAJOR" -lt 14 ] 2>/dev/null; then
  die "macOS 14 (Sonoma) or newer is required. This Mac runs macOS $OS_VERSION."
fi
ok "macOS $OS_VERSION"

# ── Internet ────────────────────────────────────────────────────────────────────────
step "Checking the internet connection"
if ! curl -sSf --max-time 20 -o /dev/null "https://huggingface.co" 2>/dev/null; then
  die "Could not reach huggingface.co, where the models are downloaded from.

Check the connection, or any firewall or VPN that might be blocking it, then run the
script again."
fi
ok "huggingface.co is reachable"

# ── Build tools ─────────────────────────────────────────────────────────────────────
# Building a Swift app needs a toolchain. The Command Line Tools are enough for everything
# this project does — no full Xcode download required.
step "Checking for the build tools"

have_swift() { command -v swift >/dev/null 2>&1 && swift --version >/dev/null 2>&1; }

if have_swift; then
  ok "Swift $(swift --version 2>/dev/null | head -1 | sed 's/.*version //; s/ .*//')"
else
  warn "No Swift toolchain found — this is the one thing that has to be installed."
  info "macOS can install its own developer tools; a dialog may appear."
  info "This downloads roughly 1 GB and can take several minutes."
  dim  "Command being run: xcode-select --install"

  xcode-select --install >/dev/null 2>&1 || true

  printf "    Waiting for the tools to finish installing"
  for _ in $(seq 1 240); do
    have_swift && break
    printf "."
    sleep 5
  done
  printf "\n"

  if ! have_swift; then
    die "The build tools did not become available.

If a dialog appeared, accept it and let it finish — it installs in the background — then
run this script again. If no dialog appeared, install the Command Line Tools manually:

  xcode-select --install

or with Homebrew:

  brew install swift"
  fi
  ok "Swift installed"
fi

# `iconutil` and `sips` come with macOS, but check rather than assume, since a missing one
# would fail the build much later with a confusing message.
for tool in iconutil sips plutil textutil; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    warn "$tool is missing; the app will build without an icon"
  fi
done

# ── Models ──────────────────────────────────────────────────────────────────────────
# Resumable and verified: each file is checked against the size the server reports, so an
# interrupted download is detected and continued rather than silently accepted.
step "Downloading the models"
info "Checkpoint: $MODEL_ID"
mkdir -p "$MODELS_DIR"
MODEL_DIR="$MODELS_DIR/$MODEL_DIR_NAME"
mkdir -p "$MODEL_DIR"

API_URL="https://huggingface.co/api/models/$MODEL_ID"
FILE_LIST="$MODELS_DIR/.huggingface-file-list.txt"

if [ ! -s "$FILE_LIST" ]; then
  dim "Asking huggingface.co which files this checkpoint has…"
  if ! curl -sSfL --max-time 60 "$API_URL" -o "$MODELS_DIR/.hf-model.json"; then
    die "Could not look up the model files. The connection may have dropped."
  fi

  if ! python3 "$SCRIPT_DIR/hf-file-list.py" "$MODELS_DIR/.hf-model.json" > "$FILE_LIST.names"; then
    die "The checkpoint did not come back with a usable file list. This usually means the
model name is wrong or the repository has moved."
  fi

  # The sizes are not in that response, so they are read with a HEAD request per file.
  # The size is what proves a download finished rather than stopping part-way.
  dim "Reading file sizes from the server…"
  : > "$FILE_LIST"
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    size="$(curl -sIL --max-time 60 "https://huggingface.co/$MODEL_ID/resolve/main/$name" \
      | tr -d '\r' \
      | awk 'tolower($1) == "content-length:" { value = $2 } END { print value }')"
    printf "%s\t%s\n" "$name" "${size:-0}" >> "$FILE_LIST"
  done < "$FILE_LIST.names"
  rm -f "$FILE_LIST.names"
fi

TOTAL_FILES="$(wc -l < "$FILE_LIST" | tr -d ' ')"
info "This checkpoint has $TOTAL_FILES files."

download_file() {
  local name="$1" expected="$2"
  local url="https://huggingface.co/$MODEL_ID/resolve/main/$name"
  local target="$MODEL_DIR/$name"

  if [ -f "$target" ]; then
    # A file whose size matches is complete; one that is short was interrupted.
    local actual
    actual="$(stat -f%z "$target" 2>/dev/null || echo 0)"
    if [ "$expected" = "0" ] || [ "$actual" = "$expected" ]; then
      ok "$name (already downloaded)"
      return 0
    fi
    dim "$name is incomplete ($actual of $expected bytes) — continuing it"
    # `-C -` resumes from where it stopped, which matters for a 3 GB file.
    if curl -sSL -C - --retry 5 --retry-delay 3 --retry-all-errors \
        -o "$target" "$url"; then
      actual="$(stat -f%z "$target" 2>/dev/null || echo 0)"
      if [ "$expected" = "0" ] || [ "$actual" = "$expected" ]; then
        ok "$name (resumed)"
        return 0
      fi
    fi
    # A resume the server does not honour leaves a corrupt file; start over rather than
    # keep a file that will fail in a confusing way later.
    warn "$name could not be resumed — downloading it again from the start"
    rm -f "$target"
  fi

  local human
  human="$(awk -v b="$expected" 'BEGIN { printf "%.0f MB", b/1048576 }')"
  info "$name ($human)"
  if ! curl -L --retry 5 --retry-delay 3 --retry-all-errors --progress-bar \
      -o "$target" "$url"; then
    fail "$name did not finish downloading"
    return 1
  fi

  local actual
  actual="$(stat -f%z "$target" 2>/dev/null || echo 0)"
  if [ "$expected" != "0" ] && [ "$actual" != "$expected" ]; then
    fail "$name is the wrong size ($actual of $expected bytes)"
    # An error page or a truncated transfer is not a partial download, so it is removed
    # rather than left for a resume that would build on corrupt bytes.
    rm -f "$target"
    return 1
  fi
  ok "$name"
  return 0
}

FAILED_DOWNLOADS=0
while IFS=$'\t' read -r name expected; do
  [ -z "$name" ] && continue
  download_file "$name" "$expected" || FAILED_DOWNLOADS=$((FAILED_DOWNLOADS + 1))
done < "$FILE_LIST"

if [ "$FAILED_DOWNLOADS" -gt 0 ]; then
  die "$FAILED_DOWNLOADS file(s) could not be downloaded.

The files that did arrive are kept, so running this script again continues from here rather
than starting over."
fi

# The loader refuses a checkpoint that is missing these, so say so now rather than at the
# first conversation.
for required in config.json tokenizer.json; do
  if [ ! -f "$MODEL_DIR/$required" ]; then
    die "The checkpoint is missing $required, so the model cannot be loaded."
  fi
done
if [ ! -f "$MODEL_DIR/model.safetensors" ] && [ ! -f "$MODEL_DIR/model-00001-of-00001.safetensors" ]; then
  die "The checkpoint has no weights file, so the model cannot be loaded."
fi
ok "Model ready at $MODEL_DIR"

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
# The whole point of an installer is to find out *now* whether it works, rather than
# leaving the person to discover a problem when they open the app.
step "Checking that a model actually runs"
info "This loads the checkpoint once and generates a few tokens — 15-30 seconds."
dim "It is the slowest step and the most important one."

CHECK_LOG="$ROOT/.install-check.log"
CHECK_TIMEOUT=300

# macOS has no `timeout` command, so this is the portable equivalent. A timeout matters
# here: if another app is holding the GPU, model loading can wait indefinitely, and an
# installer that appears to hang forever is the worst outcome for someone who just wants
# the app — they cannot tell whether to wait or give up.
run_with_timeout() {
  local seconds="$1"; shift
  "$@" &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$seconds" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 2
      kill -KILL "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 2
    waited=$((waited + 2))
  done
  wait "$pid"
}

run_with_timeout "$CHECK_TIMEOUT" \
  bash -c "cd '$ROOT' && swift run -c release chatbots-cli --check" > "$CHECK_LOG" 2>&1
CHECK_STATUS=$?

if [ "$CHECK_STATUS" -eq 0 ]; then
  if grep -q "Check passed" "$CHECK_LOG"; then
    ok "A model loaded and generated text on this Mac"
  else
    warn "The check finished, but not in the expected way:"
    tail -5 "$CHECK_LOG" | sed 's/^/      /'
  fi
else
  if [ "$CHECK_STATUS" -eq 124 ]; then
    fail "The check did not finish within $((CHECK_TIMEOUT / 60)) minutes, so it was stopped."
  else
    fail "A model could not be run."
  fi
  printf "\n    Last lines:\n\n"
  tail -15 "$CHECK_LOG" | sed 's/^/      /'
  cat <<EOF

    The app is built, so it is worth trying anyway — this check is stricter than the app
    needs. If it fails again, the usual causes are:

      · very little free memory (this Mac has: $(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f GB", $1/1073741824}'))
      · another app holding the GPU, such as LM Studio or a game
      · a leftover process from an earlier run — check with:
          pgrep -fl chatbots-cli
      · a partial model download — delete $MODEL_DIR and run this script again

EOF
fi

# ── Launcher ────────────────────────────────────────────────────────────────────────
step "Creating a launcher"
LAUNCHER_DIR="$HOME/Applications"
LAUNCHER="$LAUNCHER_DIR/ChatBots.command"
mkdir -p "$LAUNCHER_DIR"

cat > "$LAUNCHER" <<EOF
#!/bin/bash
# Launches ChatBots. Created by the installer; safe to move or delete.
cd "$ROOT" || exit 1
if [ ! -d "$APP" ]; then
  osascript -e 'display alert "ChatBots is not built yet" message "Open Terminal and run:\n\nbash $ROOT/tools/install.sh" as critical'
  exit 1
fi
open "$APP"
EOF
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

${BOLD}Optional: cloud models instead of local ones${OFF}

The app can also talk to any OpenAI-compatible server instead of running models locally.
Click "API" in the app and give it a URL. With LM Studio running on this Mac the URL is
http://localhost:1234/v1 — and no model download is needed at all in that case.

EOF
