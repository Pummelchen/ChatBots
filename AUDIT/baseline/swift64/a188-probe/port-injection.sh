#!/usr/bin/env bash
# A188 probe — what a port value does to the sed programs that generate the Caddyfile.
#
# Two halves. The first reproduces the *pre-fix* program with hostile values, in the same shape
# `tools/start.sh` uses, and prints the config it produces: that is what the finding is about. The second
# runs the real script with those values and asserts it refuses them before doing anything — and that a
# real port still generates the config it should, which is the counterweight.
#
#   usage: bash AUDIT/baseline/swift64/a188-probe/port-injection.sh

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

echo "the pre-fix program, with a hostile port (this is the finding)"
for value in '7990|e' '7990' '.*' '7990&x'; do
  generated="$(sed -e "s|http://:7788|http://:$value|" Caddyfile | sed -n '40p')"
  printf '  --port %-8s -> %s\n' "'$value'" "$generated"
done
echo "  (with '.*' as --port the local-only pattern '/^http:\/\/:.* {/' matches every line ending in ' {')"

echo
echo "the validation itself, extracted from the script so nothing can be started"
# The script is not run with a hostile value here on purpose: without the validation that is exactly the
# state the finding is about, and running it would start an engine and a Caddy — which is a side effect a
# probe must not have. The function is lifted out by name and called in a subshell, so its `exit` is what
# the probe observes.
validation="$(sed -n '/^require_port()/,/^}/p' "$ROOT/tools/start.sh")"
refuses() {
  ( eval "$validation"; require_port "$1" "$2" ) >/dev/null 2>&1 && return 1
  return 0
}
for value in '7990|e' '.*' 'x' '99999' '0' '-1' '7788 '; do
  if refuses --port "$value"; then
    check "the validation refuses --port '$value'" yes
  else
    check "the validation refuses --port '$value'" no "it accepted it"
  fi
done
# The engine option gets one value of the same shape as the port list above — a metacharacter inside a
# plausible value. It is held in an array because a `for` list holding a single literal reads as a
# mistake to ShellCheck (SC2041), and A192 put this probe under the shell lint.
engine_values=('7789|e')
for value in "${engine_values[@]}"; do
  if refuses --engine "$value"; then
    check "the validation refuses --engine '$value'" yes
  else
    check "the validation refuses --engine '$value'" no "it accepted it"
  fi
done

echo
echo "and both options go through it, which is what makes the values above unreachable"
for option in port engine; do
  if sed -n "/--$option)/,/;;/p" "$ROOT/tools/start.sh" | grep -q "require_port"; then
    check "--$option is validated where it is read" yes
  else
    check "--$option is validated where it is read" no "the option loop does not call it"
  fi
done

echo
echo "a valid port still passes"
# `07` is accepted on purpose: it is a number, and the Caddyfile it generates carries the same digits.
for value in 1 7788 65535 7990 07; do
  if refuses --port "$value"; then
    check "a valid --port $value is accepted" no "it refused it"
  else
    check "a valid --port $value is accepted" yes
  fi
done

echo
echo "the counterweight: a real port still generates the config"
generated="$(sed -e "s|http://:7788|http://:7990|" -e "s|127.0.0.1:7789|127.0.0.1:7991|g" Caddyfile)"
check "a real port reaches the site address" "$(printf '%s' "$generated" | grep -q '^http://:7990 {' && echo yes)" 
check "a real engine port reaches the reverse proxy" \
  "$(printf '%s' "$generated" | grep -q 'reverse_proxy 127.0.0.1:7991' && echo yes)"

echo
if [ "$failures" -eq 0 ]; then
  echo "all A188 probe checks passed"
  exit 0
fi
echo "$failures A188 probe check(s) failed"
exit 1
