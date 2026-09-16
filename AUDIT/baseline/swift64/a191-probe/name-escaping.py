#!/usr/bin/env python3
"""A191 probe — a name with a quote, a backslash or a newline in it.

`tools/embed-names.py` pasted each name from `names/*.txt` straight into a Swift string literal. A name
with a quote, a backslash, a newline or a control character in it therefore produced Swift that does not
compile — in a committed generated file that nobody edits by hand. This runs the escaping, the *old*
interpolation beside it, and the whole generator over a list that contains such a name, compiling what it
produces with the toolchain that builds the app.

    usage: python3 AUDIT/baseline/swift64/a191-probe/name-escaping.py
"""

from __future__ import annotations

import importlib.util
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[4]
SPEC = importlib.util.spec_from_file_location("embed_names", ROOT / "tools" / "embed-names.py")
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

failures = 0


def check(name: str, condition: bool, detail: str = "") -> None:
    global failures
    if condition:
        print(f"  ok    {name}")
    else:
        failures += 1
        print(f"  FAIL  {name}{f' — {detail}' if detail else ''}")


def runs_as_swift(literal: str) -> tuple[bool, str]:
    """Whether `let name = <literal>; print(name)` compiles and runs, and what it printed."""
    with tempfile.TemporaryDirectory() as directory:
        source = pathlib.Path(directory) / "probe.swift"
        source.write_text(f"let name = {literal}\nprint(name)\n", encoding="utf-8")
        run = subprocess.run(
            ["swift", str(source)], capture_output=True, text=True, timeout=120, check=False
        )
        return run.returncode == 0, (run.stdout + run.stderr).strip()


print("the escapes")
cases = {
    'a"b': '"a\\"b"',
    "a\\b": '"a\\\\b"',
    "a\nb": '"a\\nb"',
    "a\tb": '"a\\tb"',
    "a\x01b": '"a\\u{1}b"',
    "Grüße": '"Grüße"',
    "Ada": '"Ada"',
}
for name, expected in cases.items():
    got = MODULE.swift_literal(name)
    check(f"{name!r} becomes {expected}", got == expected, f"got {got!r}")

print("\nthe old interpolation, compiled — this is the finding")
for name in ['a"b', "a\\b", "a\nb"]:
    compiles, output = runs_as_swift(f'"{name}"')
    print(f"  {name!r} as the old generator wrote it: compiles={compiles}")
    check(f"the old interpolation for {name!r} does not compile", not compiles)

print("\nwhat the generator now writes, compiled")
for name in ['a"b', "a\\b", "a\nb", "a\x01b", "Grüße", "Ada"]:
    literal = MODULE.swift_literal(name)
    compiles, output = runs_as_swift(literal)
    check(f"the escaped form of {name!r} compiles and prints it back", compiles and output == name,
          f"compiles={compiles}, printed {output!r}")

print("\nthe whole generator, over a list with such a name in it")
with tempfile.TemporaryDirectory() as directory:
    names = pathlib.Path(directory) / "names"
    names.mkdir()
    for file in (ROOT / "names").iterdir():
        shutil.copy(file, names / file.name)
    english = names / "english.txt"
    text = english.read_text(encoding="utf-8")
    english.write_text(text.replace("[female]\n", '[female]\nAda "The Quote"\nAda\\Backslash\n', 1),
                       encoding="utf-8")
    original = MODULE.SOURCE
    MODULE.SOURCE = names
    try:
        generated = MODULE.generate()
    finally:
        MODULE.SOURCE = original
    with tempfile.TemporaryDirectory() as build:
        source = pathlib.Path(build) / "NameLists.swift"
        source.write_text(generated, encoding="utf-8")
        run = subprocess.run(["swift", str(source)], capture_output=True, text=True, timeout=180, check=False)
    check("the generated file compiles with a hostile name in the lists", run.returncode == 0,
          (run.stdout + run.stderr).strip()[:200])
    check("and it carries the name", "Ada \\\"The Quote\\\"".replace("\\\\", "\\") in generated)

print("\nthe counterweight: the committed file is still the generator's output")
step = subprocess.run([sys.executable, str(ROOT / "tools" / "embed-names.py"), "--check"],
                      capture_output=True, text=True, check=False)
check("tools/embed-names.py --check passes", step.returncode == 0, step.stderr.strip()[:200])

if failures == 0:
    print("\nall A191 probe checks passed")
    sys.exit(0)
print(f"\n{failures} A191 probe check(s) failed")
sys.exit(1)
