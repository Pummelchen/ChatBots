#!/usr/bin/env python3
"""List the files a Hugging Face checkpoint offers, one per line.

The API's `siblings` response does not include sizes, so they are read separately with a
HEAD request by the installer. Files this installer does not download are skipped, each for
the reason recorded on `SKIP` below — repository prose, and the vocabularies the app does
not read — so no bandwidth is spent on them.

Kept as its own file rather than an inline heredoc so the installer stays readable.
"""

from __future__ import annotations

import json
import sys

# The API response is JSON, so `json.load` hands back `Any` and the fields are only known once
# checked. This alias names the boundary; the code below narrows the two shapes it reads.
type JsonValue = (
    None | bool | int | float | str | list[JsonValue] | dict[str, JsonValue]
)

# Files a checkpoint offers that this installer does not download, each with its own reason rather
# than one label that fits none of them (A194):
#
#   * repository metadata and prose — `.gitattributes`, `README.md`, `LICENSE`, `LICENSE.txt`,
#     `.gitignore` — which are not the model and would only be wasted bandwidth;
#   * `tokenizer.model`, the SentencePiece vocabulary. That is a *model* file, not documentation: it
#     is skipped because `Sources/ChatBotsCore/ModelStore.swift` treats `tokenizer.json` as the
#     tokenizer a local checkpoint must have, so a checkpoint offering only `tokenizer.model` is
#     rejected by the app as incomplete either way, and one offering both does not need the duplicate
#     (~2 MB).
#
# Frozen because the constant is only ever read, and saying so keeps it that way.
SKIP: frozenset[str] = frozenset(
    {
        ".gitattributes",
        "README.md",
        "LICENSE",
        "LICENSE.txt",
        ".gitignore",
        "tokenizer.model",
    }
)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: hf-file-list.py <api-response.json>", file=sys.stderr)
        return 2
    try:
        with open(sys.argv[1]) as handle:
            data: JsonValue = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        print(f"could not read the model metadata: {error}", file=sys.stderr)
        return 1

    if not isinstance(data, dict):
        print("the model metadata is not a JSON object", file=sys.stderr)
        return 1
    raw_siblings = data.get("siblings")
    siblings: list[JsonValue] = []
    if isinstance(raw_siblings, list):
        siblings = raw_siblings

    names: list[str] = []
    for entry in siblings:
        if not isinstance(entry, dict):
            continue
        filename = entry.get("rfilename")
        if isinstance(filename, str) and filename and filename not in SKIP:
            names.append(filename)
    if not names:
        print("the checkpoint lists no files", file=sys.stderr)
        return 1

    for name in names:
        print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
