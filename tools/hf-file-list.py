#!/usr/bin/env python3
"""List the files a Hugging Face checkpoint offers, one per line.

The API's `siblings` response does not include sizes, so they are read separately with a
HEAD request by the installer. Documentation files are skipped: they are not part of the
model and would just be wasted bandwidth.

Kept as its own file rather than an inline heredoc so the installer stays readable.
"""

import json
import sys

SKIP = {".gitattributes", "README.md", "LICENSE", "LICENSE.txt", ".gitignore", "tokenizer.model"}


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: hf-file-list.py <api-response.json>", file=sys.stderr)
        return 2
    try:
        with open(sys.argv[1]) as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        print(f"could not read the model metadata: {error}", file=sys.stderr)
        return 1

    siblings = data.get("siblings") or []
    names = [
        entry.get("rfilename", "")
        for entry in siblings
        if entry.get("rfilename") and entry.get("rfilename") not in SKIP
    ]
    if not names:
        print("the checkpoint lists no files", file=sys.stderr)
        return 1

    for name in names:
        print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
