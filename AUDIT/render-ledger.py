#!/usr/bin/env python3
"""Render AUDIT/ledger.md from AUDIT/ledger.json — the ledger is the single source of truth.

Usage: python3 AUDIT/render-ledger.py
Writes AUDIT/ledger.md and prints the counts line.
"""

from __future__ import annotations

import json
import pathlib
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

TERMINAL = {"DONE", "BLOCKED"}
SEVERITY_ORDER = {"S0": 0, "S1": 1, "S2": 2, "S3": 3}
STATUS_ORDER = {
    "OPEN": 0,
    "PROGRESS": 1,
    "SWEPT": 2,
    "TEST": 3,
    "AUDIT": 4,
    "DONE": 5,
    "BLOCKED": 6,
}


def load() -> list[dict]:
    if not LEDGER_JSON.exists():
        return []
    return json.loads(LEDGER_JSON.read_text(encoding="utf-8"))


def esc(value: object) -> str:
    text = "" if value is None else str(value)
    return text.replace("|", "\\|").replace("\n", " ")


def main() -> int:
    tasks = load()
    for index, task in enumerate(tasks, start=1):
        task.setdefault("id", f"AUDIT-{index:04d}")
        for field in FIELDS:
            task.setdefault(field, "")

    counts = Counter(task["status"] for task in tasks)
    open_count = sum(1 for t in tasks if t["status"] not in TERMINAL)
    blocked = counts.get("BLOCKED", 0)
    done = counts.get("DONE", 0)
    sev_open = Counter(t["severity"] for t in tasks if t["status"] not in TERMINAL)
    sev_all = Counter(t["severity"] for t in tasks)
    tier_all = Counter(t["tier"] for t in tasks)

    lines: list[str] = []
    add = lines.append
    add("# Audit ledger")
    add("")
    add("Generated from `AUDIT/ledger.json` by `AUDIT/render-ledger.py`. Do not edit by hand.")
    add("")
    add(f"- total: {len(tasks)}")
    add(f"- done: {done}")
    add(f"- open: {open_count}")
    add(f"- blocked: {blocked}")
    add("")
    add("## Open by severity")
    add("")
    add("| severity | open | total |")
    add("| --- | --- | --- |")
    for severity in ("S0", "S1", "S2", "S3"):
        add(f"| {severity} | {sev_open.get(severity, 0)} | {sev_all.get(severity, 0)} |")
    add("")
    add("## By tier")
    add("")
    add("| tier | total |")
    add("| --- | --- |")
    for tier in sorted(tier_all):
        add(f"| {tier} | {tier_all[tier]} |")
    add("")

    ordered = sorted(
        tasks,
        key=lambda t: (
            SEVERITY_ORDER.get(t["severity"], 9),
            t["status"] in TERMINAL,
            t["id"],
        ),
    )
    add("## Tasks")
    add("")
    add(
        "| id | sev | tier | project | file:line | title | category | status | "
        "host | discovered-by | evidence-before | fix-summary | evidence-after | commit | blocked-reason |"
    )
    add("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for task in ordered:
        add(
            "| "
            + " | ".join(esc(task[field]) for field in FIELDS)
            + " |"
        )
    add("")

    LEDGER_MD.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(
        f"total:{len(tasks)} done:{done} open:{open_count} blocked:{blocked} "
        f"open_by_sev:" + ",".join(f"{s}={sev_open.get(s, 0)}" for s in ("S0", "S1", "S2", "S3"))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
