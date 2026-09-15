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
    die "This needs about ${REQUIRED_GB} GB free — the checkpoint is ~3 GB and the build
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
# Read the requirement from the one place that states it, rather than declaring it a third time
# here. `Package.swift` states it and the app bundle copies it, which CI already checks against each
# other; this script used to state it separately as 14, three major versions below the two that
# matter, so a Sonoma user downloaded the checkpoint, built the app and was then refused at launch
# by the bundle's own minimum (audit A121). Removing the duplicate value is the fix; a check that
# the three agree would only have policed it.
REQUIRED_MACOS_MAJOR="$(grep -oE '\.macOS\(\.v[0-9]+\)' "$ROOT/Package.swift" | grep -oE '[0-9]+' | head -1)"
if [ -z "$REQUIRED_MACOS_MAJOR" ]; then
  warn "Could not read the minimum macOS from Package.swift; continuing without the version check"
elif [ "$OS_MAJOR" -lt "$REQUIRED_MACOS_MAJOR" ] 2>/dev/null; then
  die "macOS $REQUIRED_MACOS_MAJOR or newer is required. This Mac runs macOS $OS_VERSION."
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

# Xcode 27 ships the Metal compiler as a separate downloadable component, and without it the build
# stops on the first `.metal` kernel mlx-swift compiles — an error that names the file rather than the
# cause, three minutes after the download started. The check *runs* the compiler instead of looking for
# it, because `xcrun --find metal` prints a path on a machine where the component is absent, so a
# path check reports success on a Mac that cannot build (A133).
step "Checking for the Metal compiler"
if metal_version="$(bash "$SCRIPT_DIR/check-metal.sh" --quiet 2>&1)"; then
  ok "$metal_version"
else
  warn "The Metal compiler is not usable on this Mac, so the app cannot be built."
  printf '%s\n' "$metal_version" | sed 's/^/    /'
  die "Install the Metal toolchain component and run this script again:

  xcodebuild -downloadComponent MetalToolchain"
fi

# ── Models ──────────────────────────────────────────────────────────────────────────
# Resumable and verified: each file is checked against the size the server reports, so an
# interrupted download is detected and continued rather than silently accepted. A file whose
# size cannot be learned is refused rather than recorded as 0 and then waved through — see
# `file_list_is_complete` and `download_file` below.
step "Downloading the models"
info "Checkpoint: $MODEL_ID"
mkdir -p "$MODELS_DIR"
MODEL_DIR="$MODELS_DIR/$MODEL_DIR_NAME"
mkdir -p "$MODEL_DIR"

API_URL="https://huggingface.co/api/models/$MODEL_ID"
FILE_LIST="$MODELS_DIR/.huggingface-file-list.txt"

# The list is only trusted when every row carries a positive integer size. A zero used to
# mean "unknown — accept any size", which made the integrity check a no-op: a truncated
# transfer, or an error page written by `curl -o` without `--fail`, was recorded as a
# complete model. A list an older installer left with a zero in it is rebuilt, not trusted.
file_list_is_complete() {
  [ -s "$FILE_LIST" ] || return 1
  ! awk -F'\t' '$2 !~ /^[0-9]+$/ || $2 + 0 == 0 { bad = 1 } END { exit bad ? 0 : 1 }' "$FILE_LIST"
}

# Reads the size of every listed file with a HEAD request. The size is what proves a download
# finished rather than stopping part-way, so when it cannot be read the lookup fails and the
# installer says so; recording 0 and continuing would remove the check entirely. `--fail`
# keeps an HTTP error out of the size calculation too.
#
# The result is written to a temporary file and moved into place only after every size has
# been read, so a lookup that stops half-way can never leave a short list that a re-run would
# treat as complete.
read_file_sizes() {
  local names_file="$1" name size attempt
  local building="$FILE_LIST.building"
  : > "$building"
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    size=""
    for attempt in 1 2 3; do
      size="$(curl -fsIL --max-time 60 \
        "https://huggingface.co/$MODEL_ID/resolve/main/$name" \
        | tr -d '\r' \
        | awk 'tolower($1) == "content-length:" { value = $2 } END { print value }')" || size=""
      case "$size" in
        ''|*[!0-9]*) size="" ;;
        *) if [ "$size" -gt 0 ]; then break; fi ;;
      esac
      if [ "$attempt" -lt 3 ]; then sleep 3; fi
    done
    if [ -z "$size" ]; then
      rm -f "$building"
      return 1
    fi
    printf "%s\t%s\n" "$name" "$size" >> "$building"
  done < "$names_file"
  mv "$building" "$FILE_LIST"
}

if ! file_list_is_complete; then
  if [ ! -s "$FILE_LIST.names" ]; then
    dim "Asking huggingface.co which files this checkpoint has…"
    if ! curl -sSfL --max-time 60 "$API_URL" -o "$MODELS_DIR/.hf-model.json"; then
      die "Could not look up the model files. The connection may have dropped."
    fi

    if ! python3 "$SCRIPT_DIR/hf-file-list.py" "$MODELS_DIR/.hf-model.json" > "$FILE_LIST.names"; then
      die "The checkpoint did not come back with a usable file list. This usually means the
model name is wrong or the repository has moved."
    fi
  fi

  dim "Reading file sizes from the server…"
  if ! read_file_sizes "$FILE_LIST.names"; then
    die "The size of one or more model files could not be read from huggingface.co, so the
download cannot be verified and was not started.

This is usually a dropped connection or a rate limit, and running the script again retries
it. It is deliberately fatal: without the size there is nothing to check the download
against, and this installer will not record a model it cannot verify as complete."
  fi
  rm -f "$FILE_LIST.names"
fi

TOTAL_FILES="$(wc -l < "$FILE_LIST" | tr -d ' ')"
info "This checkpoint has $TOTAL_FILES files."

download_file() {
  local name="$1" expected="$2"
  local url="https://huggingface.co/$MODEL_ID/resolve/main/$name"
  # Where it belongs, and the directory it needs. The list comes from the hub, so the name may be a
  # nested path (`original/config.json`) — which `curl -o` cannot write into a directory that does not
  # exist — and it may not be trusted to stay inside the model directory (A186).
  local target
  if ! target="$(bash "$SCRIPT_DIR/model-target-path.sh" "$MODEL_DIR" "$name" 2>&1)"; then
    fail "refusing to download $name"
    dim "$target"
    return 1
  fi

  # A zero or non-numeric size is not "unknown, so accept anything": it means this file
  # cannot be verified, and an unverifiable model file is not recorded as complete. The size
  # list is validated before it is used, so this only fires on a corrupt or hand-edited list.
  case "$expected" in
    ''|*[!0-9]*|0)
      fail "$name has no size to verify against — refusing to download it"
      return 1
      ;;
  esac

  if [ -f "$target" ]; then
    # A file whose size matches is complete; one that is short was interrupted.
    local actual
    actual="$(stat -f%z "$target" 2>/dev/null || echo 0)"
    if [ "$actual" = "$expected" ]; then
      ok "$name (already downloaded)"
      return 0
    fi
    dim "$name is incomplete ($actual of $expected bytes) — continuing it"
    # `-C -` resumes from where it stopped, which matters for a 3 GB file. `--fail` keeps an
    # error response out of the file, so a 404 page is never resumed into model bytes.
    if curl -fsSL -C - --retry 5 --retry-delay 3 --retry-all-errors \
        -o "$target" "$url"; then
      actual="$(stat -f%z "$target" 2>/dev/null || echo 0)"
      if [ "$actual" = "$expected" ]; then
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
  if ! curl -fL --retry 5 --retry-delay 3 --retry-all-errors --progress-bar \
      -o "$target" "$url"; then
    fail "$name did not finish downloading"
    return 1
  fi

  local actual
  actual="$(stat -f%z "$target" 2>/dev/null || echo 0)"
  if [ "$actual" != "$expected" ]; then
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
  local pid waited

  # Job control puts the command in its own process group. That is what makes the timeout
  # actually stop the work: `swift run` and the `chatbots-cli` it spawns are grandchildren of
  # this shell, so signalling only the direct child left the process that holds the GPU
  # running for the rest of the install while the log said the check had been stopped.
  set -m
  "$@" &
  pid=$!
  set +m

  waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$seconds" ]; then
      # A negative pid addresses the whole process group created above; the plain-pid
      # fallback is there only in case job control was unavailable and no group was created.
      kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      sleep 2
      kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
      # Reap the group leader so the next step does not see a zombie.
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 2
    waited=$((waited + 2))
  done

  # The command's real status: a passing run must stay a pass.
  wait "$pid"
}

# Runs a command with the project root as its working directory. The directory is passed as
# an argument and the command as the remaining words, so no shell command string is ever
# built from the path: an apostrophe or a semicolon in the checkout's name is just a
# character in a path, not shell syntax. The previous form pasted `$ROOT` into
# `bash -c "cd '…' && …"`, so an apostrophe broke the quoting and a crafted directory name
# was command injection at install time.
run_in_root() {
  local dir="$1"; shift
  ( cd "$dir" || exit 1; exec "$@" )
}

# The engine's certificate is made here rather than on first launch.
#
# Two reasons: generating a key takes a moment, and during setup a pause is expected while in
# the app it reads as a hang; and the fingerprint is printed where whoever is installing can
# see it. It is also the one step that touches the filesystem outside the build, so a failure
# is better reported here than discovered by the app later.
step "Preparing the engine certificate"
if CERT_OUTPUT="$(cd "$ROOT" && swift run -c release chatbots-cli --prepare-identity 2>&1)"; then
  ok "$(echo "$CERT_OUTPUT" | head -1 | sed 's/^engine certificate: //')"
  dim "stored in $ROOT/.run — the engine reads it from there and never touches the keychain"
else
  # Not fatal: the app creates one on first launch if it is missing.
  warn "The certificate could not be prepared; the app will create one on first launch."
  echo "$CERT_OUTPUT" | tail -3 | sed 's/^/      /'
fi

# The channel the desktop app uses, proved separately from the model check.
#
# These fail independently: a model can generate text while the transport is broken, and the
# app would then open a window that never updates. It needs no model, so it is quick.
step "Checking the app's connection to the engine"
TRANSPORT_LOG="$ROOT/.install-transport.log"
if run_with_timeout 180 \
  run_in_root "$ROOT" swift run -c release chatbots-cli --check-transport \
  > "$TRANSPORT_LOG" 2>&1
then
  ok "The app can reach the engine over WebTransport"
else
  warn "The app's connection could not be verified. The website will still work."
  tail -4 "$TRANSPORT_LOG" | sed 's/^/      /'
fi

run_with_timeout "$CHECK_TIMEOUT" \
  run_in_root "$ROOT" swift run -c release chatbots-cli --check > "$CHECK_LOG" 2>&1
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

${BOLD}Optional: cloud models instead of local ones${OFF}

The app can also talk to any OpenAI-compatible server instead of running models locally.
Click "API" in the app and give it a URL. With LM Studio running on this Mac the URL is
http://localhost:1234/v1 — and no model download is needed at all in that case.

EOF
