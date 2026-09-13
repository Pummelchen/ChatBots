#!/usr/bin/env python3
"""Check THIRD-PARTY-NOTICES.md against the resolved dependency graph.

ChatBots ships the packages pinned in `Package.resolved` inside any distributed binary, so
their licence terms travel with it. This compares the inventory table in
`THIRD-PARTY-NOTICES.md` against the lockfile and fails on any difference in either
direction: adding a dependency is a one-line manifest edit that nothing else notices, and its
attribution would otherwise go missing silently.

    python3 tools/third-party-notices.py

It deliberately does not write the notices file. Copying a licence in automatically is how a
copyleft or unlicensed dependency gets shipped unremarked, so each licence is read and
recorded by hand and this only proves the inventory stayed complete. It needs no network and
no dependency checkout, which is what lets it run as a plain CI gate.
"""

from __future__ import annotations

import json
import pathlib
import re
import sys
from typing import Any, cast

ROOT: pathlib.Path = pathlib.Path(__file__).resolve().parent.parent
RESOLVED: pathlib.Path = ROOT / "Package.resolved"
NOTICES: pathlib.Path = ROOT / "THIRD-PARTY-NOTICES.md"

# Marks the inventory table, so the check reads exactly the rows a human reads.
TABLE_START: str = "<!-- inventory:start -->"
TABLE_END: str = "<!-- inventory:end -->"
ROW: re.Pattern[str] = re.compile(
    r"^\| `(?P<name>[^`]+)` \| (?P<version>[^ |]+) \|", re.MULTILINE
)


def resolved_packages(path: pathlib.Path) -> dict[str, str]:
    """Read the pinned packages from a lockfile.

    Args:
        path: The `Package.resolved` to read.

    Returns:
        Package identity, lower-cased, to pinned version.

    Raises:
        SystemExit: The lockfile is unreadable or not the JSON it should be.
    """
    try:
        document = cast("dict[str, Any]", json.loads(path.read_text(encoding="utf-8")))
    except OSError as error:
        print(f"cannot read {path}: {error}", file=sys.stderr)
        raise SystemExit(2) from error
    except json.JSONDecodeError as error:
        print(f"{path} is not valid JSON: {error}", file=sys.stderr)
        raise SystemExit(2) from error

    pins = document.get("pins")
    if pins is None:
        # SwiftPM wrote the pins under "object" before the v2 lockfile format.
        pins = cast("dict[str, Any]", document.get("object", {})).get("pins", [])

    packages: dict[str, str] = {}
    for pin in cast("list[dict[str, Any]]", pins):
        identity = str(pin.get("identity") or pin.get("package") or "")
        version = str(cast("dict[str, Any]", pin.get("state", {})).get("version", ""))
        if identity:
            packages[identity.lower()] = version
    return packages


def recorded_packages(path: pathlib.Path) -> dict[str, str]:
    """Read the inventory table out of the notices file.

    Args:
        path: The notices file to read.

    Returns:
        Package name, lower-cased, to the version recorded beside it.

    Raises:
        SystemExit: The file is unreadable, or carries no marked table, in which case there is
            no inventory to compare and reporting "no differences" would be a false pass.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        print(f"cannot read {path}: {error}", file=sys.stderr)
        raise SystemExit(2) from error

    start = text.find(TABLE_START)
    end = text.find(TABLE_END)
    if start < 0 or end < 0 or end < start:
        print(f"{path} carries no marked inventory table", file=sys.stderr)
        raise SystemExit(2)

    packages: dict[str, str] = {}
    for match in ROW.finditer(text[start:end]):
        packages[match.group("name").lower()] = match.group("version")
    return packages


def main() -> int:
    resolved = resolved_packages(RESOLVED)
    recorded = recorded_packages(NOTICES)

    missing = sorted(set(resolved) - set(recorded))
    extra = sorted(set(recorded) - set(resolved))
    stale = sorted(
        name
        for name in set(resolved) & set(recorded)
        if resolved[name] != recorded[name]
    )

    for name in missing:
        print(f"missing from {NOTICES.name}: {name} {resolved[name]}", file=sys.stderr)
    for name in extra:
        print(
            f"recorded but no longer resolved: {name} {recorded[name]}", file=sys.stderr
        )
    for name in stale:
        print(
            f"version differs for {name}: pinned {resolved[name]}, recorded {recorded[name]}",
            file=sys.stderr,
        )

    if missing or extra or stale:
        return 1
    print(f"the third-party notices cover all {len(resolved)} resolved packages")
    return 0


if __name__ == "__main__":
    sys.exit(main())
