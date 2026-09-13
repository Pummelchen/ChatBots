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
# Exit 0 when every claim is backed, 1 when a claim is unbacked, 2 when the ledger cannot be
# read well enough to make the claim either way.

set -uo pipefail

ledger="${1:-$(dirname "$0")/ledger.json}"
cd "$(dirname "$0")/.." || exit 2

if [ ! -f "$ledger" ]; then
    echo "no ledger at $ledger" >&2
    exit 2
fi

# Task fields, one row per DONE task, separated by U+001F so the shell can read them without a
# JSON parser per task.
#
# `file_line` is free prose, so it is scanned for plausible repository paths rather than parsed:
# anything that looks like a file or directory under Sources/, Tests/ or tools/. A task that
# names no such path — a CI YAML, a document, a decision — is out of scope here and is reported
# as skipped rather than passed silently.
# The separator has now been wrong twice, in the same direction both times: the guard read its
# own fields wrongly, therefore *skipped* the claims it exists to check, and still exited 0.
#
#   * `@tsv` with `IFS=$'\t'` (A83). A tab is *IFS whitespace*, so a run of them collapses to a
#     single delimiter and leading/trailing ones are dropped. When a task's `commit` was empty
#     the doubled tab disappeared, every later field shifted one place left, and `file_line` was
#     read as `unit`. The task then "named no source path" — so the guard silently skipped
#     precisely the DONE claim with no commit behind it.
#   * `U+0001` with `IFS=$'\001'` (A117). `U+0001` is bash's own internal `CTLESC` escape
#     character — `U+007F` is `CTLNUL` — so a literal one cannot survive in a shell variable.
#     `read` never saw a delimiter, the whole row landed in `$id`, every task was skipped, and on
#     macOS's bash 3.2 the guard reported "backed 0 · skipped 109 · unbacked 0" and exited 0.
#
# U+001F is neither IFS whitespace (so an empty field stays an empty field) nor one of bash's
# internal markers, so it is read as a delimiter on bash 3.2 and on bash 5 alike.
#
# The parse is then *checked* rather than trusted, because on both occasions the failure was
# invisible from the exit status: a row that does not begin with a task id aborts the run with
# exit 2 instead of being skipped. Section 10 of phase-e.sh reads that status, so an unreadable
# ledger is reported as a failure rather than passing as a clean run.
separator=$'\037'
rows=$(jq -r --arg sep "$separator" '.tasks[]
    | select(.status == "DONE")
    | [.id, (.commit // ""), (.file_line // ""), (.unit // "")]
    | join($sep)' "$ledger")
done_tasks=$(jq -r '[.tasks[] | select(.status == "DONE")] | length' "$ledger")

failures=0
checked=0
skipped=0
read_rows=0

while IFS="$separator" read -r id commit file_line unit; do
    [ -n "$id" ] || continue

    # A row whose first field is not a task id means the separator did not survive into the
    # loop, and every task would be skipped while this script reported success. Refuse to
    # report a result at all rather than reporting a vacuous one.
    if [[ ! "$id" =~ ^A[0-9]+$ ]]; then
        echo "FATAL  could not parse a ledger row: the first field is not a task id:" >&2
        printf '       %s\n' "$id" >&2
        echo "       the U+001F separator did not survive; the ledger was not read" >&2
        exit 2
    fi
    read_rows=$((read_rows + 1))

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

if [ "$read_rows" -ne "$done_tasks" ]; then
    echo
    echo "FATAL  read $read_rows row(s) for $done_tasks DONE task(s) — the ledger was not read in full" >&2
    exit 2
fi

echo
echo "backed $checked · skipped $skipped · unbacked $failures"
[ "$failures" -eq 0 ]
