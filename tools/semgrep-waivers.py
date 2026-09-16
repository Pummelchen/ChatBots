#!/usr/bin/env python3
"""Check a semgrep report against the findings this project waived in writing.

`semgrep --error` fails on any finding, and three findings in `tools/cdp.py` and
`tools/cdp_protocol.py` are deliberately left visible: the plaintext websocket and the run-time URL
are both correct for a loopback-only Chrome DevTools client, and the code now *enforces* what the
scanner cannot see (a host check that refuses anything but loopback, a pinned scheme, a bounded
read). They are not suppressed with `nosemgrep`,
because that hides a finding rather than justifying it — so a gate has to distinguish "a
finding the project has justified" from "a new one", and a count cannot do that: swapping one finding
for another leaves the total unchanged.

The waivers are therefore an allowlist read from `tools/analysis-waivers.txt`, matched on rule id
*and* path suffix, and this is the one implementation of that check: the CI job calls it, and
`tools/mac-checks.sh` runs the same scan so the hosted gate and a Mac cannot disagree about what
has been justified.

    python3 tools/semgrep-waivers.py report.json [plan.md]

Exit 0 when every finding matches a recorded waiver, 1 when one does not, 2 when the report cannot be
read at all — a report that will not parse is not a clean one.
"""

from __future__ import annotations

import json
import pathlib
import re
import sys
from typing import Any, cast

ROOT: pathlib.Path = pathlib.Path(__file__).resolve().parent.parent
WAIVERS: pathlib.Path = ROOT / "tools" / "analysis-waivers.txt"

# `semgrep waiver: <rule id> <path>` — the shape tools/analysis-waivers.txt records them in, and the
# source both this script and a reader use.
WAIVER: re.Pattern[str] = re.compile(
    r"^semgrep waiver:\s+(\S+)\s+(\S+)\s*$", re.MULTILINE
)


def waivers(path: pathlib.Path) -> list[tuple[str, str]]:
    """Read the recorded waivers.

    Args:
        path: The plan to read them from.

    Returns:
        Rule id and path suffix for each recorded waiver.

    Raises:
        SystemExit: The plan is unreadable. An empty allowlist would fail every finding, which is
            loud, but a *missing* plan must not look the same as a plan with no waivers.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        print(f"cannot read {path}: {error}", file=sys.stderr)
        raise SystemExit(2) from error
    return [(match.group(1), match.group(2)) for match in WAIVER.finditer(text)]


def findings(path: pathlib.Path) -> tuple[list[tuple[str, str]], list[str]]:
    """Read rule id and path for each finding in a semgrep JSON report.

    Args:
        path: The report to read.

    Returns:
        One pair per finding, and the warnings the scan reported.

    Raises:
        SystemExit: The report is missing, unparseable, incomplete or records an error. Reporting
            "no unwaived findings" from a report that could not be read is the failure mode recorded
            before, and it happened again here: only `results` was read, so a failed scan printed
            "0 finding(s), all covered by a recorded waiver" and exited 0.
    """
    try:
        document = cast("dict[str, Any]", json.loads(path.read_text(encoding="utf-8")))
    except OSError as error:
        print(f"cannot read {path}: {error}", file=sys.stderr)
        raise SystemExit(2) from error
    except json.JSONDecodeError as error:
        print(f"{path} is not valid JSON: {error}", file=sys.stderr)
        raise SystemExit(2) from error

    raw_results = document.get("results")
    if not isinstance(raw_results, list):
        print(
            f"{path} has no `results` array, so semgrep did not complete a scan. "
            "A missing results key is not the same as no findings.",
            file=sys.stderr,
        )
        raise SystemExit(2)

    # semgrep records anything it could not do in `errors`, and exits 0 while doing it. An entry at
    # error level means the scan did not cover what it was asked to; a warning (a file it could not
    # parse, a rule it could not load) means it covered it with a caveat. The first stops the gate,
    # the second is printed and carried into the summary, because a scan nobody can see the caveats
    # of is worth little.
    warnings: list[str] = []
    for entry in cast("list[dict[str, Any]]", document.get("errors") or []):
        level = str(entry.get("level", "error"))
        detail = entry.get("message") or entry.get("type") or entry
        if level == "warn":
            warnings.append(str(detail))
            continue
        print(f"semgrep reported a scan error: {detail}", file=sys.stderr)
        raise SystemExit(2)

    found: list[tuple[str, str]] = []
    for entry in cast("list[object]", raw_results):
        if not isinstance(entry, dict):
            print(
                f"{path} has a finding that is not an object: {entry!r}",
                file=sys.stderr,
            )
            raise SystemExit(2)
        result = cast("dict[str, Any]", entry)
        found.append((str(result.get("check_id", "")), str(result.get("path", ""))))
    return found, warnings


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: semgrep-waivers.py report.json [waivers.txt]", file=sys.stderr)
        return 2
    report = pathlib.Path(sys.argv[1])
    plan = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else WAIVERS

    allowed = waivers(plan)
    found, warnings = findings(report)

    for warning in warnings:
        print(f"semgrep scan warning: {warning}", file=sys.stderr)

    unwaived: list[tuple[str, str]] = []
    for rule, path in found:
        if any(
            rule == waived_rule and path.endswith(waived_path)
            for waived_rule, waived_path in allowed
        ):
            print(f"waived:   {rule}  {path}")
        else:
            print(f"UNWAIVED: {rule}  {path}", file=sys.stderr)
            unwaived.append((rule, path))

    if unwaived:
        print(
            f"semgrep: {len(unwaived)} of {len(found)} finding(s) not covered by any waiver "
            f"in {plan.relative_to(ROOT)}",
            file=sys.stderr,
        )
        return 1
    caveat = f", with {len(warnings)} scan warning(s) printed above" if warnings else ""
    print(f"semgrep: {len(found)} finding(s), all covered by a recorded waiver{caveat}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
