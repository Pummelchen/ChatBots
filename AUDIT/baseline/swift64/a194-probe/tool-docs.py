#!/usr/bin/env python3
"""A194 probe — the tool descriptions against what the tools do.

Three descriptions drifted from the code: `capture-devices.py`'s header described Chrome's
`--screenshot` command line while the tool drives the DevTools protocol, and its `-thumb.png` display
copy was written and never used; `hf-file-list.py` filed `tokenizer.model` — a model file — under
"Documentation files"; and `start.sh`'s help was a `sed` range that stopped before the `--view phone`
explanation and advertised a desktop/mobile `--open` distinction the code never had.

This runs the tools rather than reading them where it can: the real `build_index` over a patched
output directory, the real `hf-file-list.py` over synthetic and real API responses, and the real
`start.sh --help`. Three mutations then show the checks are load-bearing.

    python3 AUDIT/baseline/swift64/a194-probe/tool-docs.py
"""

from __future__ import annotations

import importlib.util
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import types

ROOT: pathlib.Path = pathlib.Path(__file__).resolve().parents[4]
TOOLS: pathlib.Path = ROOT / "tools"

failures = 0


def check(name: str, ok: bool, detail: str = "") -> None:
    global failures
    if ok:
        print(f"  ok    {name}")
    else:
        failures += 1
        print(f"  FAIL  {name}{' — ' + detail if detail else ''}")


def load_module(path: pathlib.Path, name: str) -> types.ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(script: pathlib.Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(script), *arguments] if script.suffix == ".sh" else [sys.executable, str(script), *arguments],
        capture_output=True,
        text=True,
        check=False,
    )


# ── start.sh ────────────────────────────────────────────────────────────────────────────────
def help_text(script: pathlib.Path) -> str:
    return run(script, "--help").stdout


def start_sh_checks(script: pathlib.Path) -> list[tuple[str, bool, str]]:
    """The help says what the options do, and no more than the code does."""
    text = help_text(script)
    source = script.read_text()
    code_lines = [
        line.strip()
        for line in source.splitlines()
        if "OPEN_WHERE" in line and not line.strip().startswith("#")
    ]
    # The only things the code does with the value: default it, take it, and compare it with `none`.
    distinctions = [
        line
        for line in code_lines
        if re.search(r'OPEN_WHERE"?\s*(==|!=)?\s*"?[a-z]', line) and '"none"' not in line
    ]
    return [
        (
            "the help includes the --view phone explanation the old range stopped before",
            "forces the single-column phone layout" in text,
            "",
        ),
        (
            "the help describes --open as opening the page",
            "open the page in the default browser" in text,
            "",
        ),
        (
            "the help no longer advertises a desktop/mobile --open value",
            "desktop | mobile | none" not in text,
            "",
        ),
        (
            "and the code really has no such distinction",
            not distinctions,
            f"lines that branch on the value: {distinctions}",
        ),
    ]


# ── capture-devices.py ──────────────────────────────────────────────────────────────────────
def index_html(module: types.ModuleType, directory: pathlib.Path) -> str:
    """The real `build_index`, with the output directory pointed at a temporary one."""
    module.OUT = directory
    rows = [
        {
            "file": "a.png",
            "thumb": "a-thumb.png",
            "name": "Phone A",
            "width": 390,
            "height": 844,
            "pixelRatio": 3.0,
            "class": "phone",
            "mode": "thread",
            "orientation": "portrait",
        },
        {
            "file": "b.png",
            "thumb": None,
            "name": "Tablet B",
            "width": 768,
            "height": 1024,
            "pixelRatio": 2.0,
            "class": "tablet",
            "mode": "split",
            "orientation": "portrait",
        },
    ]
    for name in ("a.png", "a-thumb.png", "b.png"):
        (directory / name).write_bytes(b"not really a png")
    module.build_index(rows)
    return (directory / "index.html").read_text()


def capture_device_checks(module: types.ModuleType, directory: pathlib.Path) -> list[tuple[str, bool, str]]:
    html = index_html(module, directory)
    sources = re.findall(r'src="([^"]+)"', html)
    missing = [name for name in sources if not (directory / name).exists()]
    header = module.__doc__ or ""
    return [
        (
            "a card with a display copy shows it and links the capture",
            '<a href="a.png"><img src="a-thumb.png"' in html,
            "",
        ),
        (
            "the index does not embed the full-size capture it has a copy of",
            'src="a.png"' not in html,
            "",
        ),
        (
            "a card with no display copy falls back to the capture and says so",
            'src="b.png"' in html and "full size" in html,
            "",
        ),
        (
            "every image the index names exists beside it",
            not missing,
            f"missing: {missing}",
        ),
        (
            "the header describes the DevTools call the tool makes, not Chrome's --screenshot",
            "Page.captureScreenshot" in header and "--screenshot" not in header,
            "",
        ),
    ]


def downscale_check(module: types.ModuleType, directory: pathlib.Path) -> tuple[str, bool, str]:
    """The display copy is a real, smaller file when ImageMagick is there, and None when it is not."""
    module.OUT = directory
    original = ROOT / "Sources" / "ChatBotsApp" / "Resources" / "AppIcon-1024.png"
    capture = directory / "icon.png"
    shutil.copyfile(original, capture)
    result = module.downscale("icon.png")
    if shutil.which("magick"):
        ok = (
            result is not None
            and result.exists()
            and result.name == "icon-thumb.png"
            and result.stat().st_size < capture.stat().st_size
        )
        return ("the display copy is written and smaller than the capture", ok, f"returned {result}")
    return ("downscale reports honestly when there is no ImageMagick", result is None, f"returned {result}")


# ── hf-file-list.py ─────────────────────────────────────────────────────────────────────────
# The default checkpoint's own list, as the hub served it on 2026-09-16.
REAL_SIBLINGS = [
    ".gitattributes",
    "README.md",
    "chat_template.jinja",
    "config.json",
    "model.safetensors",
    "model.safetensors.index.json",
    "preprocessor_config.json",
    "processor_config.json",
    "tokenizer.json",
    "tokenizer_config.json",
    "video_preprocessor_config.json",
    "vocab.json",
]


def payload(directory: pathlib.Path, names: list[str]) -> pathlib.Path:
    path = directory / "api.json"
    path.write_text(json.dumps({"siblings": [{"rfilename": name} for name in names]}))
    return path


def listing(script: pathlib.Path, path: pathlib.Path) -> tuple[int, str]:
    result = run(script, str(path))
    return result.returncode, result.stdout


def file_list_checks(script: pathlib.Path, directory: pathlib.Path) -> list[tuple[str, bool, str]]:
    mixed = [
        ".gitattributes",
        "README.md",
        "LICENSE",
        "tokenizer.model",
        "tokenizer.json",
        "config.json",
        "model-00001-of-00002.safetensors",
        "original/config.json",
    ]
    code, out = listing(script, payload(directory, mixed))
    listed = out.split()
    code_real, out_real = listing(script, payload(directory, REAL_SIBLINGS))
    listed_real = out_real.split()
    source = script.read_text()
    return [
        (
            "the repository prose and metadata are not downloaded",
            code == 0 and "README.md" not in listed and "LICENSE" not in listed,
            out,
        ),
        (
            "a redundant SentencePiece vocabulary is skipped",
            "tokenizer.model" not in listed,
            out,
        ),
        (
            "nothing else is filtered out, nested path and shard names included",
            listed == ["tokenizer.json", "config.json", "model-00001-of-00002.safetensors", "original/config.json"],
            out,
        ),
        (
            "the default checkpoint lists every file it offers but the prose",
            sorted(listed_real) == sorted(set(REAL_SIBLINGS) - {".gitattributes", "README.md"}),
            out_real,
        ),
        (
            "the skip list gives tokenizer.model its own reason instead of calling it documentation",
            "Documentation files" not in source
            and "SentencePiece vocabulary. That is a *model* file" in source
            and "ModelStore.swift" in source,
            "",
        ),
        (
            "and the module docstring no longer says the same thing",
            "Documentation files are skipped" not in source,
            "",
        ),
    ]


def main() -> int:
    work = pathlib.Path(tempfile.mkdtemp(prefix="a194-"))
    try:
        start_sh = TOOLS / "start.sh"
        capture_tool = TOOLS / "capture-devices.py"
        list_tool = TOOLS / "hf-file-list.py"

        print("start.sh — the help against the code")
        for name, ok, detail in start_sh_checks(start_sh):
            check(name, ok, detail)

        print("\ncapture-devices.py — the header and the display copy")
        module = load_module(capture_tool, "capture_devices")
        capture_dir = work / "captures"
        capture_dir.mkdir()
        for name, ok, detail in capture_device_checks(module, capture_dir):
            check(name, ok, detail)
        name, ok, detail = downscale_check(module, capture_dir)
        check(name, ok, detail)

        print("\nhf-file-list.py — what is downloaded and what it is called")
        for name, ok, detail in file_list_checks(list_tool, work):
            check(name, ok, detail)

        print("\nmutations — each one has to be caught")

        original = start_sh.read_text()

        # M0 is the counterweight to M1: the help really is the header, so a line added to a copy's
        # header reaches that copy's help — which is what stops it drifting behind the header again.
        follows = work / "start-extra.sh"
        follows.write_text(
            original.replace(
                "#   --open <where>", "# A194 probe header line\n#   --open <where>", 1
            )
        )
        check(
            "M0 a line added to a copy's header appears in its help",
            "A194 probe header line" in help_text(follows),
            "the help did not follow the header",
        )

        # M1: the help back in a fixed range that stops before the last explanation.
        fixed_range = subprocess.run(
            ["sed", "-n", "2,33p", str(start_sh)], capture_output=True, text=True, check=False
        ).stdout
        check(
            "M1 the header is longer than the range the old help printed",
            "forces the single-column phone layout" not in fixed_range,
            "the old range already covered it",
        )

        # M2: an index that embeds the capture instead of the display copy.
        mutant_source = capture_tool.read_text().replace(
            'src="{r.get("thumb") or r["file"]}"', 'src="{r["file"]}"'
        )
        mutant_tool = work / "capture-mutant.py"
        mutant_tool.write_text(mutant_source)
        mutant_module = load_module(mutant_tool, "capture_devices_mutant")
        mutant_dir = work / "mutant-captures"
        mutant_dir.mkdir()
        mutant_checks = dict(
            (name, ok) for name, ok, _ in capture_device_checks(mutant_module, mutant_dir)
        )
        check(
            "M2 the index check sees an index that ignores the display copy",
            mutant_checks["the index does not embed the full-size capture it has a copy of"] is False,
            "the check accepted the mutant",
        )

        # M3: the skip filter removed, so the prose is downloaded again.
        mutant_list = work / "list-mutant.py"
        mutant_list.write_text(
            list_tool.read_text().replace(" and filename not in SKIP", "")
        )
        _, mutant_out = listing(mutant_list, payload(work, ["README.md", "model.safetensors"]))
        check(
            "M3 the file-list check sees a tool that downloads the prose",
            "README.md" in mutant_out.split(),
            "the check accepted the mutant",
        )

        print()
        if failures == 0:
            print("all A194 probe checks passed")
            return 0
        print(f"{failures} A194 probe check(s) failed")
        return 1
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
