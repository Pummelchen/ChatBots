#!/usr/bin/env bash
# A193 probe — a transfer that stops moving must fail; one that is merely slow must not.
#
# `curl --retry` retries a transfer that *fails*; a connection that stops moving without failing is
# not a failure to curl, so the installer and the two fetch scripts waited forever — the outcome
# install.sh's own text calls the worst a user can get. The fix is curl's speed deadline
# (`--speed-limit`/`--speed-time`) plus `--connect-timeout`, and this probe measures both directions
# of it against local servers, with the exact values the three scripts ship:
#
#   * a stalled transfer is still waiting after 12 s without the deadline, and fails with curl's
#     "too slow" (exit 28) in about 30 s with it;
#   * a transfer at 100 B/s that finishes inside the window is not killed, and one at 2 KiB/s that
#     runs *longer* than the window still completes — the deadline is a floor on speed, not a cap on
#     total time, which is why `--max-time` was not used;
#   * a stalled first attempt is retried and the download completes, which is what makes the deadline
#     a recovery rather than a failure.
#
# The servers are `nc -l` on loopback and are killed on the way out; nothing here touches the network.
# The probe is bash rather than Python so that the shell lint A192 widened covers it.
#
#   usage: bash AUDIT/baseline/swift64/a193-probe/transfer-deadline.sh

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "$ROOT" || exit 1

failures=0
check() {
  if [ "$2" = "yes" ]; then
    printf '  ok    %s\n' "$1"
  else
    failures=$((failures + 1))
    printf '  FAIL  %s%s\n' "$1" "${3:+ — $3}"
  fi
}

work="$(mktemp -d)"
servers=()
# Inline in the trap rather than a function the trap names: ShellCheck 0.11 reports a trap-only
# function as never invoked once the script ends in `exit` (A192).
trap 'for pid in "${servers[@]:-}"; do kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; done; rm -rf "$work"' EXIT

free_port() {
  local port tries=0
  while [ "$tries" -lt 20 ]; do
    tries=$((tries + 1))
    port=$((20000 + RANDOM % 20000))
    if ! nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
      printf '%s' "$port"
      return 0
    fi
  done
  return 1
}

# Runs a command with a wall-clock bound, so the *old* invocation can be shown to still be waiting.
# Sets `ran_status` to the command's exit status; returns 0 when it finished inside the bound.
run_bounded() {
  local bound="$1" pid ticks=0
  shift
  "$@" > "$work/ran.log" 2>&1 &
  pid=$!
  while [ "$ticks" -lt "$((bound * 2))" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null
      ran_status=$?
      return 0
    fi
    sleep 0.5
    ticks=$((ticks + 1))
  done
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  ran_status=143
  return 1
}

size_of() {
  wc -c < "$1" 2>/dev/null | tr -d ' '
}

stall_server() {
  local port="$1"
  { printf 'HTTP/1.1 200 OK\r\nContent-Length: 1048576\r\nConnection: close\r\n\r\n'
    printf '0123456789'
    sleep 300
  } | nc -l 127.0.0.1 "$port" >/dev/null 2>&1
}

dribble_server() {
  local port="$1" per="$2" seconds="$3" i=0
  { printf 'HTTP/1.1 200 OK\r\nContent-Length: %s\r\nConnection: close\r\n\r\n' "$((per * seconds))"
    while [ "$i" -lt "$seconds" ]; do
      printf '%*s' "$per" '' | tr ' ' 'x'
      i=$((i + 1))
      sleep 1
    done
  } | nc -l 127.0.0.1 "$port" >/dev/null 2>&1
}

# Stalls the first connection — for longer than the deadline, so curl abandons it and retries — and
# serves the same 2000 bytes to every later one. The first hold is what makes the retry land on a
# listening socket: until it ends, the single-threaded server is not accepting.
flaky_server() {
  local port="$1" i
  while :; do
    if [ ! -f "$work/stalled" ]; then
      : > "$work/stalled"
      { printf 'HTTP/1.1 200 OK\r\nContent-Length: 2000\r\nConnection: close\r\n\r\n'
        printf '0123456789'
        sleep 40
      } | nc -l 127.0.0.1 "$port" >/dev/null 2>&1
    else
      { printf 'HTTP/1.1 200 OK\r\nContent-Length: 2000\r\nConnection: close\r\n\r\n'
        i=0
        while [ "$i" -lt 5 ]; do printf '%0400d' 0; i=$((i + 1)); done
      } | nc -l 127.0.0.1 "$port" >/dev/null 2>&1
    fi
  done
}

# The invocations as each script writes them, taken from the code and not from a comment: the two
# install.sh downloads must use the defined option array, and the other two scripts must carry the
# three options on the curl line itself.
install_uses_deadline() {
  local file="$1" definition resume fresh
  definition="$(grep -F 'CURL_TRANSFER_OPTIONS=(' "$file" | tail -1)"
  resume="$(grep -F 'CURL_TRANSFER_OPTIONS[@]' "$file" | grep -F -- '-C -' | tail -1)"
  fresh="$(grep -F 'CURL_TRANSFER_OPTIONS[@]' "$file" | grep -F -- '--progress-bar' | tail -1)"
  if [ -n "$definition" ] && [ -n "$resume" ] && [ -n "$fresh" ] \
    && printf '%s' "$definition" | grep -qF -- '--connect-timeout 20' \
    && printf '%s' "$definition" | grep -qF -- '--speed-limit 1024' \
    && printf '%s' "$definition" | grep -qF -- '--speed-time 30'; then
    echo yes
  else
    echo no
  fi
}

carries_deadline() {
  local line
  line="$(grep -F 'curl ' "$1" | grep -F -- '--speed-limit 1024' | tail -1)"
  if [ -n "$line" ] \
    && printf '%s' "$line" | grep -qF -- '--connect-timeout 20' \
    && printf '%s' "$line" | grep -qF -- '--speed-time 30'; then
    echo yes
  else
    echo no
  fi
}

echo "the servers this probe runs:"
echo "  stalled      10 bytes of a declared 1 MB body, then silence"
echo "  slow         100 bytes a second for 10s (finishes inside the deadline's window)"
echo "  long slow    2 KiB a second for 35s (outlasts the window, stays above the floor)"
echo "  flaky        the first connection stalls, every later one serves 2000 bytes"

echo
echo "the stall, before and after"
port="$(free_port)"
stall_server "$port" &
servers+=("$!")
sleep 1
if run_bounded 12 curl -fsS --retry 5 --retry-delay 3 --retry-all-errors \
  -o "$work/old.bin" "http://127.0.0.1:$port/checkpoint.bin"; then
  check "without a deadline, a stalled transfer is still running after 12s" no "it returned rc=$ran_status"
else
  check "without a deadline, a stalled transfer is still running after 12s (the hang)" yes
fi

port="$(free_port)"
stall_server "$port" &
servers+=("$!")
sleep 1
if run_bounded 45 curl -fsS --connect-timeout 20 --speed-limit 1024 --speed-time 30 \
  -o "$work/new.bin" "http://127.0.0.1:$port/checkpoint.bin"; then
  check "with the shipped deadline the same stall fails instead of hanging" \
    "$([ "$ran_status" = "28" ] && echo yes || echo no)" "curl returned rc=$ran_status"
  check "and curl says why" \
    "$(grep -qi 'too slow' "$work/ran.log" && echo yes || echo no)" "$(tail -1 "$work/ran.log")"
else
  check "with the shipped deadline the same stall fails instead of hanging" no \
    "still running after 45s (rc=$ran_status)"
fi

echo
echo "the counterweights — a slow transfer is not the same as a stalled one"
port="$(free_port)"
dribble_server "$port" 100 10 &
servers+=("$!")
sleep 1
if run_bounded 40 curl -fsS --connect-timeout 20 --speed-limit 1024 --speed-time 30 \
  -o "$work/slow.bin" "http://127.0.0.1:$port/slow.bin"; then
  check "100 B/s that finishes inside the window completes" \
    "$([ "$(size_of "$work/slow.bin")" = "1000" ] && echo yes || echo no)" \
    "got $(size_of "$work/slow.bin") bytes"
else
  check "100 B/s that finishes inside the window completes" no "it was killed (rc=$ran_status)"
fi

port="$(free_port)"
dribble_server "$port" 2048 35 &
servers+=("$!")
sleep 1
if run_bounded 90 curl -fsS --connect-timeout 20 --speed-limit 1024 --speed-time 30 \
  -o "$work/long.bin" "http://127.0.0.1:$port/long.bin"; then
  check "2 KiB/s outlasting the 30s window completes (a floor on speed, not a cap on time)" \
    "$([ "$(size_of "$work/long.bin")" = "71680" ] && echo yes || echo no)" \
    "got $(size_of "$work/long.bin") bytes"
else
  check "2 KiB/s outlasting the 30s window completes (a floor on speed, not a cap on time)" no \
    "it was killed (rc=$ran_status)"
fi

port="$(free_port)"
flaky_server "$port" &
servers+=("$!")
sleep 1
if run_bounded 120 curl -fsS --connect-timeout 20 --speed-limit 1024 --speed-time 30 \
  --retry 8 --retry-delay 3 --retry-all-errors \
  -o "$work/retry.bin" "http://127.0.0.1:$port/retry.bin"; then
  check "the stalled attempt is abandoned, retried and the download completes" \
    "$([ "$(size_of "$work/retry.bin")" = "2000" ] && echo yes || echo no)" \
    "rc=$ran_status, got $(size_of "$work/retry.bin") bytes"
else
  check "the stalled attempt is abandoned, retried and the download completes" no \
    "still running after 120s (rc=$ran_status)"
fi

echo
echo "the three scripts, as they now write it"
check "install.sh defines the deadline once and uses it in both downloads" \
  "$(install_uses_deadline tools/install.sh)"
check "tools/fetch-metal.sh carries it on its download" "$(carries_deadline tools/fetch-metal.sh)"
check "tools/fetch-audit-tools.sh carries it in fetch()" "$(carries_deadline tools/fetch-audit-tools.sh)"
check "the values measured above are the ones the scripts ship" \
  "$([ "$(install_uses_deadline tools/install.sh)" = "yes" ] \
    && [ "$(carries_deadline tools/fetch-metal.sh)" = "yes" ] \
    && [ "$(carries_deadline tools/fetch-audit-tools.sh)" = "yes" ] \
    && echo yes || echo no)"

echo
echo "mutations — each one has to be caught"
sed 's/CURL_TRANSFER_OPTIONS\[@\]/CURL_OPTIONS_REMOVED/' tools/install.sh > "$work/install-mutant.sh"
check "M1 the check sees a download that lost the deadline" \
  "$([ "$(install_uses_deadline "$work/install-mutant.sh")" = "no" ] && echo yes || echo no)" \
  "the check accepted a copy with the option array removed"

sed 's/--speed-limit 1024 //' tools/fetch-metal.sh > "$work/metal-mutant.sh"
check "M2 the check sees one option missing" \
  "$([ "$(carries_deadline "$work/metal-mutant.sh")" = "no" ] && echo yes || echo no)" \
  "the check accepted a copy without --speed-limit"

# M3 is behavioural: an over-aggressive deadline must lose the counterweight, or the probe would not
# notice a fix that kills slow-but-healthy transfers. It has to *fail* the 2 KiB/s transfer; if it
# completes, this check goes red.
port="$(free_port)"
dribble_server "$port" 2048 35 &
servers+=("$!")
sleep 1
if run_bounded 20 curl -fsS --speed-limit 1000000 --speed-time 1 \
  -o "$work/aggressive.bin" "http://127.0.0.1:$port/aggressive.bin"; then
  check "M3 an over-aggressive deadline loses the slow-transfer counterweight" \
    "$([ "$ran_status" = "28" ] && echo yes || echo no)" \
    "rc=$ran_status after $(size_of "$work/aggressive.bin") bytes"
else
  check "M3 an over-aggressive deadline loses the slow-transfer counterweight" no \
    "still running after 20s (rc=$ran_status)"
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "all A193 probe checks passed"
  exit 0
fi
echo "$failures A193 probe check(s) failed"
exit 1
