#!/usr/bin/env bash
# ChatBots — no source file is longer than a reader can hold.
#
# The repository is organised by domain, not by line count, and a file that grows past a
# few hundred lines is usually two responsibilities wearing one name. The limit is 500
# lines of code; generated files are exempt because nobody writes them by hand, and
# everything that is not code (images, JSON, notices) is not measured at all.
#
# The file list comes from git rather than from a glob, so an ignored build product is not
# judged and a new directory is. `--others --exclude-standard` adds a file that has been
# written but not staged yet, which matters because the moment a file is most likely to be
# oversized is the moment it is created: a check that saw only committed files would pass on
# a fresh 900-line file and fail an hour later in CI.
#
# usage: bash tools/check-file-sizes.sh
# exit:  0 when every tracked code file is within the limit, 1 when one is not

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

LIMIT=500

# Generated from `web/` and `names/` by the embed tools; their length is a function of the
# sources they are built from, so the limit would be a rule about the generator's output
# rather than about a file somebody chose to grow.
EXEMPT=(
    "Sources/ChatBotsCore/WebAssets.swift"
    "Sources/ChatBotsCore/NameLists.swift"
)

is_exempt() {
    local file="$1" skip
    for skip in "${EXEMPT[@]}"; do
        [ "$file" = "$skip" ] && return 0
    done
    return 1
}

over=()
while IFS= read -r file; do
    case "$file" in
        *.swift | *.js | *.css | *.html | *.sh | *.py) ;;
        *) continue ;;
    esac
    is_exempt "$file" && continue
    [ -f "$file" ] || continue
    lines="$(wc -l < "$file" | tr -d ' ')"
    if [ "$lines" -gt "$LIMIT" ]; then
        over+=("$lines $file")
    fi
done < <(git ls-files --cached --others --exclude-standard)

if [ "${#over[@]}" -eq 0 ]; then
    printf 'PASS  file sizes: every code file is within %s lines\n' "$LIMIT"
    exit 0
fi

printf 'FAIL  file sizes: %s file(s) over %s lines\n' "${#over[@]}" "$LIMIT"
printf '%s\n' "${over[@]}" | sort -rn | sed 's/^/      /'
printf '      split the file along a responsibility boundary; do not raise the limit\n'
exit 1
