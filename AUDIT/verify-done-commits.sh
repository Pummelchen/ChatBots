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
# Fields are separated by U+0001, NOT by a tab, and that is the whole point of this comment.
#
# The first version of this guard used `@tsv` and `IFS=$'\t'`. A tab is *IFS whitespace*, so a
# run of them collapses to a single delimiter and leading/trailing ones are dropped — which
# means that when a task's `commit` was empty the doubled tab disappeared, every later field
# shifted one place left, and `file_line` was read as `unit`. The task then "named no source
# path" and was reported as skipped. In other words the guard silently skipped precisely the
# tasks it exists to catch: a DONE claim with no commit behind it.
#
# U+0001 is not IFS whitespace, so an empty field stays an empty field.
rows=$(jq -r '.tasks[]
    | select(.status == "DONE")
    | [.id, (.commit // ""), (.file_line // ""), (.unit // "")]
    | join("\u0001")' "$ledger")

failures=0
checked=0
skipped=0

while IFS=$'\001' read -r id commit file_line unit; do
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
        case "$base" in
            */*)
                # A path that names a directory is matched in full, so a claim about
                # `Sources/A.swift` cannot be satisfied by a different `Sources/B/A.swift`.
                if printf '%s\n' "$touched" | grep -qxF "$base"; then
                    backed="$base"
                    break
                fi
                ;;
            *)
                # A bare basename — A14 and A17 record `HTTPServer.swift:356` — is matched
                # against the last path component. That is looser, and it is the loosest this
                # check should be: a task that wants to be believed should name a path.
                pattern="^(.*/)?$(printf '%s' "$base" | sed 's/[.[\*^$]/\\&/g')$"
                if printf '%s\n' "$touched" | grep -qE "$pattern"; then
                    backed="…/$base"
                    break
                fi
                ;;
        esac
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
