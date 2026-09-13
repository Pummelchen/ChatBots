#!/usr/bin/env bash
# AUDIT — render ledger.md's status content from ledger.json.
#
# Why this exists (A118). `HANDOVER.md:4` and `:19` call `ledger.md` "the source of truth", `:109`
# tells the next session to "Read AUDIT/ledger.md first", and `plan.md:119` says the same — but the
# file enumerated 28 tasks and stopped at A89, while `ledger.json` held 116. A90-A116 appeared
# nowhere in it, and its Summary ("DONE | 9") contradicted the machine-readable twin that every gate
# actually reads: `phase-e.sh` section 11 and `verify-done-commits.sh` both read the JSON. A reader
# following the handover would have concluded the audit enumerated 28 tasks and closed 9.
#
# The cause is the same one this project already fixed for `web/` and `names/`: a hand-maintained
# summary of generated facts drifts, silently, one wave at a time. So the status content is
# generated, the prose sections stay hand-written, and `--check` makes drift a failure rather than a
# discovery.
#
#   usage: AUDIT/render-ledger.sh          # rewrite the generated region in place
#          AUDIT/render-ledger.sh --check  # exit 1 if the region is not what the ledger renders
#
# The region is delimited by the two markers below. Everything outside them — the per-task prose
# sections, the reviews, the process notes — is never touched by this script.

set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
md="$root/AUDIT/ledger.md"
json="$root/AUDIT/ledger.json"

begin='<!-- BEGIN GENERATED: ledger status — rendered from ledger.json by AUDIT/render-ledger.sh -->'
end='<!-- END GENERATED -->'

check=0
[ "${1:-}" = "--check" ] && check=1

if [ ! -f "$json" ]; then
    echo "render-ledger: no ledger at $json" >&2
    exit 2
fi
if [ ! -f "$md" ]; then
    echo "render-ledger: no ledger page at $md" >&2
    exit 2
fi

# Parse before rendering, for the reason A89 recorded: on invalid JSON jq writes nothing, and an
# empty render would look like a ledger with no tasks rather than like a failure.
if ! jq -e '.tasks | length > 0' "$json" > /dev/null 2>&1; then
    echo "render-ledger: $json could not be parsed, or holds no tasks; refusing to render" >&2
    exit 2
fi

# The rendered body: counts, the open tasks, then every task.
#
# Titles and units are escaped for a markdown table — a `|` in a field would otherwise split the row
# and silently move a column. Newlines some fields carry are collapsed for the same reason.
render_body() {
    jq -r '
      def esc: gsub("\\|"; "\\|") | gsub("[\r\n]+"; " ");
      def n($s): [.tasks[] | select(.status == $s)] | length;
      def row: "| \(.id) | \(.severity // "—") | \(.status) | \(.commit // "—") | \(.unit | esc) | \(.title | esc) |";
      def hdr: ["| id | sev | status | commit | unit | title |", "| --- | --- | --- | --- | --- | --- |"];
      .tasks as $t
      | ([$t[] | select(.status != "DONE" and .status != "BLOCKED")] | sort_by(.id)) as $open
      | ("| Metric | Count |",
        "| --- | --- |",
        "| Tasks enumerated | \($t | length) |",
        "| DONE | \(n("DONE")) |",
        "| START | \(n("START")) |",
        "| PROGRESS | \(n("PROGRESS")) |",
        "| BLOCKED | \(n("BLOCKED")) |"),
        "",
        "### Open — \($open | length)",
        "",
        (if ($open | length) == 0 then "Nothing is open." else (hdr + ($open | map(row)))[] end),
        "",
        "### Every task — \($t | length)",
        "",
        (hdr + ($t | sort_by(.id) | map(row)))[],
        ""
    ' "$json"
}

body_file="$(mktemp "${TMPDIR:-/tmp}/chatbots-ledger-body.XXXXXX")" || exit 2
out_file="$(mktemp "${TMPDIR:-/tmp}/chatbots-ledger-out.XXXXXX")" || exit 2
trap 'rm -f "$body_file" "$out_file"' EXIT

render_body > "$body_file" || {
    echo "render-ledger: jq failed to render the ledger" >&2
    exit 2
}

begin_line="$(grep -n -F "$begin" "$md" | head -1 | cut -d: -f1)"
end_line="$(grep -n -F "$end" "$md" | head -1 | cut -d: -f1)"
if [ -z "$begin_line" ] || [ -z "$end_line" ] || [ "$end_line" -le "$begin_line" ]; then
    echo "render-ledger: ledger.md does not carry both region markers" >&2
    exit 2
fi

{
    head -n "$begin_line" "$md"
    cat "$body_file"
    tail -n "+$end_line" "$md"
} > "$out_file"

if [ "$check" = "1" ]; then
    if diff -u "$md" "$out_file" > /dev/null 2>&1; then
        echo "ledger.md status region is in step with ledger.json ($(jq '.tasks | length' "$json") tasks)"
        exit 0
    fi
    echo "ledger.md has drifted from ledger.json; run AUDIT/render-ledger.sh" >&2
    diff -u "$md" "$out_file" | head -40 >&2
    exit 1
fi

cat "$out_file" > "$md"
echo "rendered $md from ledger.json ($(jq '.tasks | length' "$json") tasks)"
