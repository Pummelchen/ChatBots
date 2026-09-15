#!/bin/bash
#
# ChatBots — where one file from a checkpoint's list belongs on disk.
#
#     usage: tools/model-target-path.sh <model-dir> <listed-name>
#
# Prints the path to download to, creating the directory it needs, and exits non-zero for a name that
# is not a plain path inside the model directory.
#
# The file list comes from the hub, so a name is *data* rather than a path this project chose, and two
# things follow from that:
#
#   * A checkpoint may list a nested path — `original/config.json` is the usual one — and `curl -o`
#     fails when the directory does not exist. The installer created only the model directory itself,
#     so a fresh install of any such checkpoint died on the first nested file (A186).
#   * A name is not trusted to stay inside the model directory: `../../x` would write outside it, which
#     is the shape A29 found in attachment names. A name containing `..` at all is refused rather than
#     resolved, because the check has to be simple enough to be obviously right.
#
# Kept as a script rather than a shell function inside the installer so it can be tested without
# running a three-gigabyte download.

set -uo pipefail

dir="${1:-}"
name="${2:-}"
if [ -z "$dir" ] || [ -z "$name" ]; then
    echo "usage: model-target-path.sh <model-dir> <name>" >&2
    exit 2
fi

case "$name" in
    /*|*..*)
        echo "refusing '$name': it is not a plain path inside the checkpoint" >&2
        exit 1
        ;;
esac

target="$dir/$name"
if ! mkdir -p "$(dirname "$target")"; then
    echo "could not create $(dirname "$target")" >&2
    exit 1
fi
printf '%s\n' "$target"
