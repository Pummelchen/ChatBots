#!/bin/bash
#
# ChatBots — is a build older than the source it was made from?
#
#     usage: tools/source-newer.sh <binary> <tree>...
#
# Exit status: 0 when the binary is missing or older than the newest file under any tree — the caller
# should rebuild — and 1 when it is up to date.
#
# Comparing the *directory* mtime, which is what the start scripts did, does not answer this question:
# a directory's modification time changes only when an entry is added or removed, so editing
# `web/app.js` or `Sources/X.swift` left the old build in place and the rebuild the scripts promise
# never ran. That is the "I changed it and nothing happened" case the guard exists for, and a
# directory has to be walked to see it.
#
# `stat -f '%m'` is BSD stat, which is the only stat on macOS; this script is macOS-only, like the
# scripts that call it.

set -uo pipefail

binary="${1:-}"
if [ -z "$binary" ]; then
    echo "usage: source-newer.sh <binary> <tree>..." >&2
    exit 2
fi
shift

# Nothing built yet is as stale as it gets.
[ -e "$binary" ] || exit 0

built="$(stat -f '%m' "$binary" 2>/dev/null || echo 0)"
newest=0
for tree in "$@"; do
    [ -e "$tree" ] || continue
    # One stat per file, and `-exec … +` batches them so a tree of any size costs one pass.
    while IFS= read -r time; do
        [ -n "$time" ] && [ "$time" -gt "$newest" ] 2>/dev/null && newest="$time"
    done < <(find "$tree" -type f -exec stat -f '%m' {} + 2>/dev/null)
done

[ "$newest" -gt "$built" ]
