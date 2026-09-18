#!/usr/bin/env python3
"""List the files a Hugging Face checkpoint offers, one per line.

The API's `siblings` response does not always include sizes, so they are read separately with a
HEAD request by the installer when they are missing. Files this installer does not download are
skipped, each for the reason recorded on `SKIP` below — repository prose, and the vocabularies the
app does not read — so no bandwidth is spent on them.

Given a second argument, the per-file SHA-256 the API publishes for a Git LFS object is written
there as `name<TAB>sha256`. That is the one piece of per-file metadata this script used to
discard, and it is what lets the installer check a downloaded file's *content* rather than only
its length — a length cannot tell a substituted payload from the real one.

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
# than one label that fits none of them:
#
#   * repository metadata and prose — `.gitattributes`, `README.md`, `LICENSE`, `LICENSE.txt`,
#     `.gitignore` — which are not the model and would only be wasted bandwidth;
#   * `tokenizer.model`, the SentencePiece vocabulary. That is a *model* file, not documentation: it
#     is skipped because `Sources/ChatBotsCore/Models/ModelStore.swift` treats `tokenizer.json` as the
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
    if len(sys.argv) not in (2, 3):
        print("usage: hf-file-list.py <api-response.json> [hashes-file]", file=sys.stderr)
        return 2
    try:
        with open(sys.argv[1], encoding="utf-8") as handle:
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
    hashes: list[tuple[str, str]] = []
    for entry in siblings:
        if not isinstance(entry, dict):
            continue
        filename = entry.get("rfilename")
        if not isinstance(filename, str) or not filename or filename in SKIP:
            continue
        names.append(filename)
        # A Git LFS object carries its own SHA-256; a file stored directly does not, and that is
        # not an error — the installer falls back to its length check for those.
        lfs = entry.get("lfs")
        if isinstance(lfs, dict):
            sha = lfs.get("sha256")
            if isinstance(sha, str) and len(sha) == 64:
                hashes.append((filename, sha.lower()))
    if not names:
        print("the checkpoint lists no files", file=sys.stderr)
        return 1

    if len(sys.argv) == 3:
        try:
            with open(sys.argv[2], "w", encoding="utf-8") as handle:
                for name, sha in hashes:
                    handle.write(f"{name}\t{sha}\n")
        except OSError as error:
            print(f"could not write the hash list: {error}", file=sys.stderr)
            return 1

    for name in names:
        print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
