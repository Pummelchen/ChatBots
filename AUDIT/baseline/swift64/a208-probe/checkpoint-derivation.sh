#!/usr/bin/env bash
# A208 probe — the installer follows the declared checkpoint, and refuses when it cannot read it.
#
# `tools/install.sh` used to carry `MODEL_ID="mlx-community/Qwen3.5-4B-MLX-4bit"` and a directory name
# beside it, kept in step with `AgentSpec.defaultModelID` by a comment. It now reads the declaration and
# derives the directory from the id, because the app finds a local checkpoint at the tail of the repo id
# (`ModelStore.localCheckpoint`) and a mismatch would be a 3 GB download nothing could see.
#
# This runs the derivation the script runs, against the real file and against a copy whose declaration
# has been changed and one whose declaration is gone, so the two claims are measured rather than
# asserted: the value follows the source, and an unreadable declaration is an empty value — which is
# what the script's own guard turns into a refusal.
#
#   usage: bash AUDIT/baseline/swift64/a208-probe/checkpoint-derivation.sh

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "$ROOT" || exit 1

SOURCE="Sources/ChatBotsCore/ChatModels.swift"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
check() {
  if [ "$2" = "yes" ]; then
    printf '  ok    %s\n' "$1"
  else
    failures=$((failures + 1))
    printf '  FAIL  %s%s\n' "$1" "${3:+ — $3}"
  fi
}

# The derivation exactly as `tools/install.sh` writes it, so this measures the script's rule and not a
# copy of it: the line is read out of the script itself. Double quotes with escapes rather than single
# ones, because ShellCheck reads `$(` inside single quotes as an expansion that will not happen.
printf 'the installer derives the id with:\n    %s\n' \
  "$(grep -F -A 1 "MODEL_ID=\"\$(sed" tools/install.sh | head -1)"

derive() {
  sed -n 's/.*static let defaultModelID = "\([^"]*\)".*/\1/p' "$1" | head -1
}

echo
echo "the real declaration"
id="$(derive "$SOURCE")"
check "the derivation yields the declared checkpoint" \
  "$([ "$id" = "mlx-community/Qwen3.5-4B-MLX-4bit" ] && echo yes || echo no)" "got '$id'"
check "the directory name is the tail of the id, which is where the app looks" \
  "$([ "${id##*/}" = "Qwen3.5-4B-MLX-4bit" ] && echo yes || echo no)" "got '${id##*/}'"
check "the declaration appears in exactly one source file" \
  "$([ "$(grep -rl 'static let defaultModelID' Sources --include='*.swift' | grep -c .)" = "1" ] && echo yes || echo no)"
check "and the installer carries no copy of the id" \
  "$(grep -q 'mlx-community/Qwen3.5-4B-MLX-4bit' tools/install.sh && echo no || echo yes)" \
  "install.sh names the checkpoint itself"
check "the guard that refuses an unreadable declaration is in the script" \
  "$(grep -q 'Could not read the default checkpoint' tools/install.sh && echo yes || echo no)"

echo
echo "the old form, for comparison"
printf '  as committed before the fix:\n'
git show "HEAD:tools/install.sh" | grep -nE 'MODEL_ID=|MODEL_DIR_NAME=' | sed 's/^/    /'

echo
echo "mutation A — the declaration changed in a copy"
mutant="$WORK/renamed.swift"
sed 's|static let defaultModelID = "mlx-community/Qwen3.5-4B-MLX-4bit"|static let defaultModelID = "some-org/Another-Checkpoint-8bit"|' \
  "$SOURCE" > "$mutant"
mutated="$(derive "$mutant")"
check "the derivation follows a changed declaration" \
  "$([ "$mutated" = "some-org/Another-Checkpoint-8bit" ] && echo yes || echo no)" "got '$mutated'"
check "and the derived directory follows it too" \
  "$([ "${mutated##*/}" = "Another-Checkpoint-8bit" ] && echo yes || echo no)" "got '${mutated##*/}'"

echo
echo "mutation B — the declaration gone from a copy"
broken="$WORK/broken.swift"
grep -v 'static let defaultModelID' "$SOURCE" > "$broken"
missing="$(derive "$broken")"
if [ -z "$missing" ]; then
  check "an unreadable declaration yields nothing, which the guard refuses on" yes
else
  check "an unreadable declaration yields nothing, which the guard refuses on" no "got '$missing'"
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "all A208 probe checks passed"
  exit 0
fi
echo "$failures A208 probe check(s) failed"
exit 1
