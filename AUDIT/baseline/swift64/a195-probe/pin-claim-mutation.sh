#!/usr/bin/env bash
# A195 probe — the pin-claim guard has to fail when a claim comes back.
#
# The guard itself is `Tests/ChatBotsCoreTests/AuditS3CertificatePinClaimTests.swift`, and the evidence
# that it was needed is the "before" log beside this file: run against the comments as they were, it
# reported all nine phrasings. This is the other direction — the phrasing re-introduced on purpose, to
# show the guard catches it rather than passing because the text happens to be gone.
#
# The claim is written into a copy-on-disk of `WebTransportServer.swift` and taken out again by the
# trap, which runs however this script ends. At the end the file is compared with what it was, so a
# probe that dies mid-run cannot leave a mutated source behind.
#
#   usage: bash AUDIT/baseline/swift64/a195-probe/pin-claim-mutation.sh

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "$ROOT" || exit 1

TARGET="Sources/ChatBotsCore/WebTransportServer.swift"
WORK="$(mktemp -d)"
cp "$TARGET" "$WORK/original.swift"
# The file is legitimately modified in this working tree while A195 is being written, so "the tree is
# clean" is not the check — the check is that the probe put back exactly what it found.
before_sha="$(shasum -a 256 < "$TARGET" | cut -d' ' -f1)"
# Inline in the trap rather than a function the trap names: ShellCheck 0.11 calls a trap-only function
# never invoked once the script ends in `exit` (A192). The second copy is the evidence that the restore
# happened, and it is compared below.
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
  swift test --filter CertificatePinClaimTests > "$WORK/guard.log" 2>&1
  return $?
}

echo "the file as it stands"
if run_guard; then
  check "the guard passes on the corrected comments" yes
else
  check "the guard passes on the corrected comments" no "$(grep -m1 '✘ Test' "$WORK/guard.log")"
fi

echo
echo "the same claim written back in, as a comment"
printf '\n// (A195 probe mutation) The fingerprint a client must pin, so the note above is wrong.\n' >> "$TARGET"
if run_guard; then
  check "the guard fails on the mutation" no "it passed with the claim in the file"
else
  claim="$(grep -m1 'claim →' "$WORK/guard.log" | sed 's/^ *//')"
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
  echo "all A195 probe checks passed"
  exit 0
fi
echo "$failures A195 probe check(s) failed"
exit 1
