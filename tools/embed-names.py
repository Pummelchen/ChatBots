#!/usr/bin/env python3
"""Turn the name lists in `names/` into `Sources/ChatBotsCore/NameLists.swift`.

The lists are plain text on purpose — one name per line, grouped by a section marker — so
they can be edited without touching Swift. They are embedded into the binary so the app works
from anywhere rather than depending on being run next to the source, which is the same reason
the web interface is embedded.

    python3 tools/embed-names.py            # regenerate
    python3 tools/embed-names.py --check    # fail if out of date (used by the build script)

Exits non-zero on a malformed file rather than shipping a partial list: a missing section
marker would otherwise produce a language with no names, or with every name in the wrong list.
"""

from __future__ import annotations

import pathlib
import sys
from collections.abc import Mapping, Sequence

ROOT: pathlib.Path = pathlib.Path(__file__).resolve().parent.parent
SOURCE: pathlib.Path = ROOT / "names"
TARGET: pathlib.Path = ROOT / "Sources" / "ChatBotsCore" / "NameLists.swift"

# The language codes, and what to call each in the interface. The order here is the order in
# the generated file, so the diff stays stable. Read-only, so the annotation says so.
LANGUAGES: Sequence[tuple[str, str]] = [
    ("english", "English"),
    ("french", "French"),
    ("german", "German"),
    ("spanish", "Spanish (Latino)"),
    ("brazilianPortuguese", "Brazilian Portuguese"),
    ("italian", "Italian"),
]

FILES: Mapping[str, str] = {
    "english": "english.txt",
    "french": "french.txt",
    "german": "german.txt",
    "spanish": "spanish.txt",
    "brazilianPortuguese": "brazilian-portuguese.txt",
    "italian": "italian.txt",
}


def swift_literal(text: str) -> str:
    r"""`text` as a Swift string literal, escapes and all.

    The lists are data files that people edit, and this used to paste each name straight into a
    `"…"` literal: a name with a quote, a backslash or a control character in it produced Swift that
    does not compile, in a file nobody edits by hand and whose breakage surfaces as a build failure.
    The web embedder escapes its input for the same reason.

    Escaped by character rather than by a chain of `replace` calls so the order cannot matter, and
    anything below a space — which a Swift literal cannot carry literally — becomes `\u{…}`.
    """
    escaped: list[str] = []
    for character in text:
        if character == "\\":
            escaped.append("\\\\")
        elif character == '"':
            escaped.append('\\"')
        elif character == "\n":
            escaped.append("\\n")
        elif character == "\r":
            escaped.append("\\r")
        elif character == "\t":
            escaped.append("\\t")
        elif ord(character) < 0x20 or ord(character) == 0x7F:
            escaped.append(f"\\u{{{ord(character):x}}}")
        else:
            escaped.append(character)
    return '"' + "".join(escaped) + '"'


def parse(path: pathlib.Path) -> dict[str, list[str]]:
    """Read one list file into {"female": [...], "male": [...]}.

    Section markers are required and explicit rather than positional: a file that is edited
    and ends up with the wrong number of names would otherwise silently move names from one
    list to the other.
    """
    sections: dict[str, list[str]] = {"female": [], "male": []}
    current: str | None = None
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("["):
            marker = line.strip("[]").lower()
            if marker not in sections:
                raise SystemExit(f"{path.name}:{number}: unknown section {line!r}")
            current = marker
            continue
        if current is None:
            raise SystemExit(
                f"{path.name}:{number}: {line!r} appears before a [female] or [male] marker"
            )
        if line in sections[current]:
            raise SystemExit(f"{path.name}:{number}: {line!r} is listed twice")
        sections[current].append(line)
    for name, values in sections.items():
        if not values:
            raise SystemExit(f"{path.name}: no {name} names")
    return sections


def generate() -> str:
    lists: dict[str, dict[str, list[str]]] = {
        code: parse(SOURCE / FILES[code]) for code, _ in LANGUAGES
    }

    out: list[str] = [
        """// ChatBotsCore — the names participants are given at startup
//
// Generated from `names/` by `tools/embed-names.py`; edit the text files there, not here.
// Six languages, each with a female and a male list.
//
// Kept as text rather than as Swift literals so the lists can be edited and reviewed like
// data, which is what they are. The generated file is checked in so the build needs no extra
// step, and `tools/embed-names.py --check` catches the two drifting apart.

import Foundation

/// A language the app can draw names from.
public enum NameLanguage: String, Sendable, Codable, CaseIterable, Identifiable {
"""
    ]
    for code, _ in LANGUAGES:
        out.append(f"    case {code}\n")
    out.append("""
    public var id: String { rawValue }

    public var label: String {
        switch self {
""")
    for code, label in LANGUAGES:
        out.append(f"        case .{code}: {swift_literal(label)}\n")
    out.append("        }\n    }\n\n")
    out.append("    /// The female and male names this language offers.\n")
    out.append("    var names: NameList {\n        switch self {\n")
    for code, _ in LANGUAGES:
        female = ", ".join(swift_literal(n) for n in lists[code]["female"])
        male = ", ".join(swift_literal(n) for n in lists[code]["male"])
        out.append(
            f"        case .{code}:\n"
            f"            NameList(female: [{female}],\n"
            f"                     male: [{male}])\n"
        )
    out.append("        }\n    }\n}\n\n")

    out.append("""/// One language's names, split by gender.
public struct NameList: Sendable, Hashable {
    public var female: [String]
    public var male: [String]

    public init(female: [String], male: [String]) {
        self.female = female
        self.male = male
    }

    public func names(for gender: Gender) -> [String] {
        switch gender {
        case .female: female
        case .male: male
        }
    }
}

/// The names the participants are given at startup.
public enum NameLists {

    /// Every language, in the order they are declared.
    public static var all: [NameLanguage] { NameLanguage.allCases }

    public static func list(for language: NameLanguage) -> NameList { language.names }

    /// A name at random from one language.
    ///
    /// Random on purpose: two runs of the app should not open with the same pair of
    /// participants, which is the point of the exercise. The choice is saved with the rest of
    /// the settings, so a name does not change under a conversation that is already running.
    public static func random(
        _ gender: Gender, language: NameLanguage, using generator: inout some RandomNumberGenerator
    ) -> String {
        let names = list(for: language).names(for: gender)
        guard !names.isEmpty else { return "Agent" }
        return names[Int.random(in: 0..<names.count, using: &generator)]
    }

    /// A name drawn from any language, which is what the app uses.
    ///
    /// Deliberately not matching a language to a locale: a German name is a perfectly good
    /// name for a participant in an English conversation, and mixing them is more interesting
    /// than always drawing from one list.
    public static func random(
        _ gender: Gender, using generator: inout some RandomNumberGenerator
    ) -> String {
        random(gender, language: all.randomElement(using: &generator) ?? .english,
               using: &generator)
    }
}

/// Which list a name is drawn from.
public enum Gender: String, Sendable, Codable, CaseIterable, Identifiable {
    case female
    case male

    public var id: String { rawValue }
}
""")
    return "".join(out)


def main() -> int:
    check = "--check" in sys.argv
    wanted = generate()
    current = TARGET.read_text() if TARGET.exists() else ""
    if wanted == current:
        return 0
    if check:
        print(
            "NameLists.swift is out of date with names/.\nRun: python3 tools/embed-names.py",
            file=sys.stderr,
        )
        return 1
    TARGET.write_text(wanted)
    print(f"wrote {TARGET.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
