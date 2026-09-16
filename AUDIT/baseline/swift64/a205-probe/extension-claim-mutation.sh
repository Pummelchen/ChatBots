#!/usr/bin/env bash
# A205 probe — the kind guard fails when an extension is claimed twice again.
#
# `AttachmentTests` asserts two things about `DocumentKind.extensions`: no extension belongs to two
# kinds, and every kind is reachable from at least one extension it advertises. The finding was the case
# both catch — `.word` listed `rtf` and `rtfd` ahead of `.richText`, `forExtension` takes the first
# match, so rich text was unreachable and an RTF file was labelled "Word". `a205-kind-tests-before.log`
# is that guard run against the enum as it was, red with all seven issues.
#
# This is the other direction: one of the duplicate claims put back on purpose, so the guard is shown to
# be sensitive rather than passing because the extensions happen to be in a good order. The mutation is
# taken out again by the trap, which runs however this script ends, and the file is compared with what
# it was on the way out.
#
#   usage: bash AUDIT/baseline/swift64/a205-probe/extension-claim-mutation.sh

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "$ROOT" || exit 1

TARGET="Sources/ChatBotsCore/Attachments.swift"
WORK="$(mktemp -d)"
cp "$TARGET" "$WORK/original.swift"
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
  swift test --filter DocumentKindTests > "$WORK/guard.log" 2>&1
  return $?
}

echo "the enum as it stands"
if run_guard; then
  check "the guard passes with the extensions disjoint" yes
else
  check "the guard passes with the extensions disjoint" no "$(grep -m1 '✘ Test' "$WORK/guard.log")"
fi

echo
echo "the duplicate claim written back: rtf into .word, ahead of .richText"
sed 's|case .word: \["docx", "doc", "odt", "wordml"\]|case .word: ["docx", "doc", "odt", "rtf", "rtfd", "wordml"]|' \
  "$TARGET" > "$WORK/mutated.swift"
check "the mutation was applied" \
  "$(grep -q '"odt", "rtf"' "$WORK/mutated.swift" && echo yes || echo no)" "the sed matched nothing"
cp "$WORK/mutated.swift" "$TARGET"
if run_guard; then
  check "the guard fails on the mutation" no "it passed with rtf claimed twice"
else
  claim="$(grep -m1 'claimed by both' "$WORK/guard.log" | sed 's/^ *//')"
  check "the guard fails on the mutation" "$([ -n "$claim" ] && echo yes || echo no)" \
    "it failed for some other reason"
  [ -n "$claim" ] && printf '        %s\n' "$claim"
  unreachable="$(grep -m1 'maps back to it' "$WORK/guard.log" | sed 's/^ *//')"
  check "and says which kind became unreachable" \
    "$([ -n "$unreachable" ] && echo yes || echo no)"
  [ -n "$unreachable" ] && printf '        %s\n' "$unreachable"
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
  echo "all A205 probe checks passed"
  exit 0
fi
echo "$failures A205 probe check(s) failed"
exit 1
