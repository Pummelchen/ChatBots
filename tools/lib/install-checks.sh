#!/bin/bash
#
# Preflight checks for the ChatBots installer: this Mac, its toolchain, and the Metal compiler.
#
# Sourced by `tools/install.sh` at the point the checks should run, so it uses that script's
# output helpers and `die` rather than defining its own.

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
# by the bundle's own minimum. Removing the duplicate value is the fix; a check that
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
# path check reports success on a Mac that cannot build.
step "Checking for the Metal compiler"
if metal_version="$(bash "$SCRIPT_DIR/check-metal.sh" --quiet 2>&1)"; then
  ok "$metal_version"
else
  warn "The Metal compiler is not usable on this Mac, so the app cannot be built."
  printf '%s\n' "$metal_version" | sed 's/^/    /'
  die "Install the Metal toolchain component and run this script again:

  xcodebuild -downloadComponent MetalToolchain"
fi
