#!/usr/bin/env bash
# ChatBots — one edit for a bump, and the check that nothing else disagrees.
#
# `VERSION` at the repository root is the one authoritative value (RELEASE.md §1.3), so a bump
# is this command plus the release notes for the new number. Nothing else carries a copy: the
# bundle builder derives from `VERSION`, and the packaging script reads it, so there is nothing
# to propagate and everything to verify — which is what the last call does.
#
# usage: bash tools/set-version.sh <X.Y.Z>
# exit:  0 when the new identity is consistent, 1 when it is not, 2 on a usage error

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

if [ $# -ne 1 ]; then
    printf 'usage: bash tools/set-version.sh <X.Y.Z>\n' >&2
    exit 2
fi

new="$1"
if ! printf '%s' "$new" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    printf 'error: %s is not a semantic version (expected X.Y.Z)\n' "$new" >&2
    exit 2
fi

old="unknown"
[ -f VERSION ] && old="$(tr -d '[:space:]' < VERSION)"

printf '%s\n' "$new" > VERSION
printf 'VERSION: %s -> %s\n' "$old" "$new"

# The identity check is the point of the command: writing the file is one line, and proving
# that nothing else still says the old number is what makes the bump safe.
bash tools/check-identity.sh
