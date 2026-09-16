#!/usr/bin/env python3
"""Regenerate Sources/ChatBotsCore/WebAssets.swift from the files in web/.

The web interface lives in `web/` so Caddy can serve it directly, and is embedded into the
core so the HTTP server can serve it too. This keeps the two identical: run it after
changing anything in `web/`.

    python3 tools/embed-web.py

Exits non-zero if the generated file was out of date and --check was passed, which is what
the build script uses to notice that someone edited one and not the other.
"""

from __future__ import annotations

import pathlib
import sys
from collections.abc import Sequence

ROOT: pathlib.Path = pathlib.Path(__file__).resolve().parent.parent
WEB: pathlib.Path = ROOT / "web"
TARGET: pathlib.Path = ROOT / "Sources" / "ChatBotsCore" / "WebAssets.swift"

# name, source file, content type, then the request paths it answers. Read-only, so the
# annotation says so; the trailing paths are variadic because an asset may answer several.
FILES: Sequence[tuple[str, str, str, *tuple[str, ...]]] = [
    ("indexHTML", "index.html", "text/html; charset=utf-8", "/", "/index.html"),
    ("styleCSS", "style.css", "text/css; charset=utf-8", "/style.css"),
    ("stylePanesCSS", "style-panes.css", "text/css; charset=utf-8", "/style-panes.css"),
    (
        "stylePanelsCSS",
        "style-panels.css",
        "text/css; charset=utf-8",
        "/style-panels.css",
    ),
    ("deltasJS", "deltas.js", "application/javascript; charset=utf-8", "/deltas.js"),
    ("votesJS", "votes.js", "application/javascript; charset=utf-8", "/votes.js"),
    ("appJS", "app.js", "application/javascript; charset=utf-8", "/app.js"),
    (
        "appCoreJS",
        "app-core.js",
        "application/javascript; charset=utf-8",
        "/app-core.js",
    ),
    (
        "appScreenJS",
        "app-screen.js",
        "application/javascript; charset=utf-8",
        "/app-screen.js",
    ),
    (
        "appTranscriptJS",
        "app-transcript.js",
        "application/javascript; charset=utf-8",
        "/app-transcript.js",
    ),
    (
        "appControlsJS",
        "app-controls.js",
        "application/javascript; charset=utf-8",
        "/app-controls.js",
    ),
    (
        "appLineupJS",
        "app-lineup.js",
        "application/javascript; charset=utf-8",
        "/app-lineup.js",
    ),
    (
        "appCommandsJS",
        "app-commands.js",
        "application/javascript; charset=utf-8",
        "/app-commands.js",
    ),
]

HEADER: str = """// ChatBotsCore — the web interface, embedded
//
// Generated from `web/` by `tools/embed-web.py`; edit the files there, not here. It is
// embedded rather than read from disk so the server works from anywhere — a release build
// lives in `.build/`, and looking for `web/` relative to the binary would be a source of
// "works on my machine". Caddy serves the same files from `web/` directly, so both paths
// lead to identical bytes.
//
// `web/` remains the single source: this file is generated, so the two cannot drift.

import Foundation

public enum WebAssets {

    public struct Asset: Sendable {
        public var contentType: String
        public var body: Data
    }

    /// Look up a path from a request, or nil when it is not an asset.
    public static func asset(for path: String) -> Asset? {
        switch path {
"""


def literal(text: str) -> str:
    text = text.replace("\\", "\\\\").replace('"""', '\\"\\"\\"')
    return '"""\n' + text + '\n"""'


def generate() -> str:
    out: list[str] = [HEADER]
    for name, filename, content_type, *paths in FILES:
        # One case with several patterns: Swift has no fallthrough between cases.
        patterns = ", ".join(f'"{p}"' for p in paths)
        out.append(
            f"        case {patterns}:\n"
            f'            return Asset(contentType: "{content_type}", body: Data({name}.utf8))\n'
        )
    out.append('        case "/favicon.ico":\n            return nil\n')
    out.append("        default:\n            return nil\n        }\n    }\n\n")
    for name, filename, _, *_ in FILES:
        out.append(
            f"    static let {name} = {literal((WEB / filename).read_text())}\n\n"
        )
    out.append("}\n")
    return "".join(out)


def main() -> int:
    check = "--check" in sys.argv
    wanted = generate()
    current = TARGET.read_text() if TARGET.exists() else ""
    if wanted == current:
        return 0
    if check:
        print(
            "WebAssets.swift is out of date with web/.\n"
            "Run: python3 tools/embed-web.py",
            file=sys.stderr,
        )
        return 1
    TARGET.write_text(wanted)
    print(f"wrote {TARGET.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
