#!/usr/bin/env bash
# A206 probe — the dead-declaration guard fails when a declaration comes back.
#
# `Tests/ChatBotsCoreTests/AuditS3DeadDeclarationsTests.swift` checks the sources for the declarations
# the finding named; the other half of that evidence is the grep in `a206-declarations-before.log`,
# which shows each of them in the tree as it was committed. This is the third direction — one put back
# on purpose — so the guard is shown to be sensitive rather than passing because the names are absent
# for some other reason.
#
# The declaration is appended to a real source file and taken out again by the trap, which runs however
# this script ends, and the file is compared with what it was on the way out.
#
#   usage: bash AUDIT/baseline/swift64/a206-probe/dead-declaration-mutation.sh

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "$ROOT" || exit 1

TARGET="Sources/ChatBotsCore/HTTPServer.swift"
WORK="$(mktemp -d)"
cp "$TARGET" "$WORK/original.swift"
# A file-scope function is valid Swift, so the tree still compiles while the guard is being tested. The
# tree is legitimately modified while A206 is being written, so the check is that this probe put back
# exactly what it found, not that git is clean.
before_sha="$(shasum -a 256 < "$TARGET" | cut -d' ' -f1)"
trap 'cp "$WORK/original.swift" "$TARGET"; rm -rf "$WORK"' EXIT

failures=0
check() {
  if [ "$2" = "yes" ]; then
    printf '  ok    %s\n' "$1"
  else
    failures=$((failures + 1))
    printf '  FAIL  %s%s\n' "$1" "${3:+ — $3}"
  fi
}

run_guard() {
  swift test --filter CoreDeadDeclarationTests > "$WORK/guard.log" 2>&1
  return $?
}

echo "the tree as it stands"
if run_guard; then
  check "the guard passes with the declarations removed" yes
else
  check "the guard passes with the declarations removed" no "$(grep -m1 '✘ Test' "$WORK/guard.log")"
fi

echo
echo "one of them put back, as a file-scope function"
printf '\n// (A206 probe mutation)\nprivate func closeStreams() {}\n' >> "$TARGET"
if run_guard; then
  check "the guard fails on the mutation" no "it passed with the declaration back"
else
  claim="$(grep -m1 'still declares' "$WORK/guard.log" | sed 's/^ *//')"
  check "the guard fails on the mutation" "$([ -n "$claim" ] && echo yes || echo no)" \
    "it failed for some other reason"
  [ -n "$claim" ] && printf '        %s\n' "$claim"
fi

echo
echo "the mutation taken out again"
cp "$WORK/original.swift" "$TARGET"
if run_guard; then
  check "the guard passes again after the restore" yes
else
  check "the guard passes again after the restore" no "$(grep -m1 '✘ Test' "$WORK/guard.log")"
fi
check "the file is byte for byte what it was" \
  "$(cmp -s "$TARGET" "$WORK/original.swift" && echo yes || echo no)"
check "and its checksum is the one taken before the mutation" \
  "$([ "$(shasum -a 256 < "$TARGET" | cut -d' ' -f1)" = "$before_sha" ] && echo yes || echo no)" \
  "the probe left the file mutated"

echo
if [ "$failures" -eq 0 ]; then
  echo "all A206 probe checks passed"
  exit 0
fi
echo "$failures A206 probe check(s) failed"
exit 1
