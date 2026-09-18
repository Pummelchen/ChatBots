#!/usr/bin/env python3
"""Render AUDIT/ledger.md — the open-work tracker — from AUDIT/ledger.json.

`AUDIT/ledger.json` is the single source of truth and keeps every task, closed ones included, as
the audit record. The rendered tracker is the opposite: it lists only what still needs doing, in
tables with a task number, so the file a person opens is the work rather than the history.

Usage: python3 AUDIT/render-ledger.py
Writes AUDIT/ledger.md and prints the counts line.
"""

from __future__ import annotations

import json
import pathlib
import re
import sys
from collections import Counter

ROOT = pathlib.Path(__file__).resolve().parent
LEDGER_JSON = ROOT / "ledger.json"
LEDGER_MD = ROOT / "ledger.md"

FIELDS = [
    "id",
    "severity",
    "tier",
    "project",
    "file_line",
    "title",
    "category",
    "status",
    "host",
    "discovered_by",
    "evidence_before",
    "fix_summary",
    "evidence_after",
    "commit",
    "blocked_reason",
]

# A task in one of these states needs nobody: it is either finished or waiting on a decision that
# is not the audit's to make (BLOCKED, which the tracker shows separately because it is an issue a
# person has to answer).
CLOSED = {"DONE", "BLOCKED"}
SEVERITY_ORDER = {"S0": 0, "S1": 1, "S2": 2, "S3": 3}
STATUS_ORDER = {
    "OPEN": 0,
    "PROGRESS": 1,
    "SWEPT": 2,
    "TEST": 3,
    "AUDIT": 4,
}

BLOCKED_OWNER = re.compile(r"OWNER:\s*(.+?)\.\s*REASON:", re.S)
BLOCKED_OPTIONS = "OPTIONS FOR A HUMAN:"


def load() -> list[dict]:
    if not LEDGER_JSON.exists():
        return []
    return json.loads(LEDGER_JSON.read_text(encoding="utf-8"))


def esc(value: object) -> str:
    text = "" if value is None else str(value)
    return text.replace("|", "\\|").replace("\n", " ").strip()


def blocked_parts(reason: str) -> tuple[str, str, str]:
    """The owner, the situation and the options a `blocked_reason` records."""
    owner = ""
    match = BLOCKED_OWNER.search(reason)
    if match:
        owner = match.group(1).strip()
    body = reason[match.end() :] if match else reason
    situation, _, options = body.partition(BLOCKED_OPTIONS)
    situation = re.sub(r"^(REASON|TRIED):\s*", "", situation.strip())
    return owner, situation.strip(), options.strip()


def main() -> int:
    tasks = load()
    for index, task in enumerate(tasks, start=1):
        task.setdefault("id", f"AUDIT-{index:04d}")
        for field in FIELDS:
            task.setdefault(field, "")

    counts = Counter(task["status"] for task in tasks)
    done = counts.get("DONE", 0)
    blocked_tasks = [t for t in tasks if t["status"] == "BLOCKED"]
    open_tasks = [t for t in tasks if t["status"] not in CLOSED]
    open_count = len(open_tasks)
    sev_open = Counter(t["severity"] for t in open_tasks)

    def order(task: dict) -> tuple:
        return (
            SEVERITY_ORDER.get(task["severity"], 9),
            STATUS_ORDER.get(task["status"], 9),
            task["id"],
        )

    open_tasks.sort(key=order)
    blocked_tasks.sort(key=order)

    lines: list[str] = []
    add = lines.append
    add("# ChatBots audit — open work")
    add("")
    add(
        "Generated from `AUDIT/ledger.json` by `AUDIT/render-ledger.py`; edit the JSON, not this "
        "file."
    )
    add(
        f"**{len(tasks)} recorded · {done} closed · {open_count} open · "
        f"{len(blocked_tasks)} awaiting a decision**"
    )
    add("")
    add("Closed tasks stay in the JSON as the audit record and are not repeated here.")
    add("")

    add("## Open")
    add("")
    if open_tasks:
        add(
            "| # | task | sev | tier | project | title | where | status | what remains |"
        )
        add("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
        for number, task in enumerate(open_tasks, start=1):
            remains = task.get("note") or task["evidence_before"]
            add(
                f"| {number} | {esc(task['id'])} | {esc(task['severity'])} | {esc(task['tier'])} "
                f"| {esc(task['project'])} | {esc(task['title'])} | {esc(task['file_line'])} "
                f"| {esc(task['status'])} | {esc(remains)} |"
            )
    else:
        add("None.")
    add("")

    add("## Awaiting a decision")
    add("")
    if blocked_tasks:
        add("| # | task | sev | title | owner | situation | options |")
        add("| --- | --- | --- | --- | --- | --- | --- |")
        for number, task in enumerate(blocked_tasks, start=len(open_tasks) + 1):
            owner, situation, options = blocked_parts(task["blocked_reason"])
            add(
                f"| {number} | {esc(task['id'])} | {esc(task['severity'])} "
                f"| {esc(task['title'])} | {esc(owner)} | {esc(situation)} | {esc(options)} |"
            )
    else:
        add("None.")
    add("")

    LEDGER_MD.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(
        f"total:{len(tasks)} done:{done} open:{open_count} blocked:{len(blocked_tasks)} "
        f"open_by_sev:"
        + ",".join(f"{s}={sev_open.get(s, 0)}" for s in ("S0", "S1", "S2", "S3"))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
