#!/usr/bin/env bash
# AUDIT — every DONE task that claims a source change must have a commit that makes it.
#
# Why this exists: A14 and A17 were recorded DONE by a commit that carried the ledger entry,
# the plan update and the sanitizer log but no source change at all. The evidence was real —
# ThreadSanitizer really had gone quiet — and the code it described was still sitting
# uncommitted in the working tree. Nothing in the ledger noticed, because the ledger was not
# wrong about the result; it was wrong about where the result lived.
#
# So the check is mechanical rather than a matter of care: for each DONE task, take the paths
# its own record names and confirm its own commit touches them.
#
#   usage: AUDIT/verify-done-commits.sh [ledger.json]
#
# Exit 0 when every claim is backed, 1 otherwise, listing each unbacked claim.

set -uo pipefail

ledger="${1:-$(dirname "$0")/ledger.json}"
cd "$(dirname "$0")/.." || exit 2

if [ ! -f "$ledger" ]; then
    echo "no ledger at $ledger" >&2
    exit 2
fi

# Task fields, tab separated so the shell can read them without a JSON parser per task.
#
# `file_line` is free prose, so it is scanned for plausible repository paths rather than parsed:
# anything that looks like a file or directory under Sources/, Tests/ or tools/. A task that
# names no such path — a CI YAML, a document, a decision — is out of scope here and is reported
# as skipped rather than passed silently.
rows=$(jq -r '.tasks[]
    | select(.status == "DONE")
    | [.id, (.commit // ""), (.file_line // ""), (.unit // "")]
    | @tsv' "$ledger")

failures=0
checked=0
skipped=0

while IFS=$'\t' read -r id commit file_line unit; do
    [ -n "$id" ] || continue

    # The paths this task's own record points at.
    paths=$(printf '%s %s\n' "$file_line" "$unit" \
        | grep -oE '[A-Za-z0-9_./-]*\.(swift|py|sh)[^ ,;:)]*' \
        | sed 's/[.,;:)]*$//' \
        | sort -u)

    if [ -z "$paths" ]; then
        echo "skip   $id  names no source path"
        skipped=$((skipped + 1))
        continue
    fi

    if [ -z "$commit" ] || [ "$commit" = "null" ] || [ "$commit" = "HEAD" ]; then
        echo "FAIL   $id  status DONE but commit is '${commit:-empty}' — a DONE claim needs the commit that carries it"
        failures=$((failures + 1))
        continue
    fi

    if ! git rev-parse --verify --quiet "$commit^{commit}" >/dev/null; then
        echo "FAIL   $id  commit $commit is not in this repository"
        failures=$((failures + 1))
        continue
    fi

    touched=$(git show --name-only --format= "$commit")
    backed=""
    for path in $paths; do
        # The task may name a line (`HTTPServer.swift:356`) and the commit records the file.
        base=${path%%:*}
        if printf '%s\n' "$touched" | grep -qxF "$base"; then
            backed="$base"
            break
        fi
    done

    if [ -n "$backed" ]; then
        echo "ok     $id  $commit touches $backed"
        checked=$((checked + 1))
    else
        echo "FAIL   $id  commit $commit touches none of: $(echo "$paths" | tr '\n' ' ')"
        failures=$((failures + 1))
    fi
done <<< "$rows"

echo
echo "backed $checked · skipped $skipped · unbacked $failures"
[ "$failures" -eq 0 ]
