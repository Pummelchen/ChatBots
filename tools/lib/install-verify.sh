#!/bin/bash
#
# Proving the install works: load a model and check the desktop transport, for `tools/install.sh`.
#
# Sourced, not executed: it uses the installer's output helpers and `die`. Split out because this
# phase is the one that runs the built binary, and its timeout and working-directory handling are
# what keep that safe.

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
