#!/usr/bin/env bash
# The pinned analysis binaries the CI job runs, fetched and verified before they are unpacked.
#
# Why this exists. The workflow piped each release asset straight into `tar`:
#
#     curl -fsSL "https://github.com/…/shellcheck-v0.11.0.linux.x86_64.tar.xz" | tar -xJ -C "$tools"
#
# A version-pinned URL is not integrity. A GitHub release asset can be deleted and re-uploaded by
# anyone with release rights on that repository, and the job then executes whatever is there — the
# same repository whose `tools/fetch-metal.sh` pins a SHA-256 for its own download, and whose workflow
# header claimed the tools were pinned. Every asset here is checked against a pinned SHA-256 before it
# is unpacked, and an empty pin is an error rather than "no verification needed", by design.
#
# The Python and Node tools are deliberately not handled here. `pip install ruff==0.16.7` and
# `npm install --global pyright@1.1.414` name artefacts those registries refuse to publish twice, so
# for them the version *is* the pin; a GitHub release asset has no such rule, which is why only these
# three need digests.
#
# usage: tools/fetch-analysis-tools.sh --into <dir>     fetch, verify and unpack into <dir>
#        tools/fetch-analysis-tools.sh --verify-only    fetch and verify only, unpacking nothing
# exit:  0 every artefact verified, 1 a digest mismatch or a missing pin, 2 a usage error

set -euo pipefail

SHELLCHECK_VERSION=0.11.0
GITLEAKS_VERSION=8.30.1
OSV_SCANNER_VERSION=2.5.1

# The digests of the three assets named below, from the GitHub releases API's own `digest` field and
# checked byte-for-byte against the downloaded files. To move a version, change it here and re-derive
# all
# three rather than carrying a digest across:
#
#   curl -fsSL "https://api.github.com/repos/<owner>/<repo>/releases/tags/v<version>" \
#     | python3 -c 'import json,sys; [print(a["name"], a.get("digest")) for a in json.load(sys.stdin)["assets"]]'
#
#   the shellcheck asset, shellcheck-v0.11.0.linux.x86_64.tar.xz (2 559 196 bytes)
SHELLCHECK_SHA256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
#   the gitleaks asset, gitleaks_8.30.1_linux_x64.tar.gz (8 230 402 bytes)
GITLEAKS_SHA256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
#   the osv-scanner asset, osv-scanner_linux_amd64 (57 725 090 bytes)
OSV_SCANNER_SHA256=f9f25499a2c8cc367b3af45df2ea7eeca7fbccceab9c35079968f4b3652194be

into=""
verify_only=0
while [ $# -gt 0 ]; do
    case "$1" in
        --into)
            into="${2:-}"
            shift 2
            ;;
        --verify-only)
            verify_only=1
            shift
            ;;
        -h | --help)
            sed -n '2,26p' "$0"
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [ "$verify_only" -eq 0 ]; then
    if [ -z "$into" ]; then
        echo "error: --into <dir> is required (or use --verify-only)" >&2
        exit 2
    fi
    # These are the Linux builds the CI job runs. Somewhere else the download and the digests are
    # still worth checking — that is what --verify-only is for — but the binaries would not run.
    if [ "$(uname -s)" != "Linux" ]; then
        echo "error: these are Linux binaries and this is $(uname -s); use --verify-only" >&2
        exit 2
    fi
    mkdir -p "$into"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The hash tool differs by platform: `sha256sum` is coreutils, `shasum -a 256` is what macOS ships.
# Both `-c` forms read "<digest>  <file>" lines and exit non-zero on a mismatch, which is the whole
# check.
verify() {
    if [ -z "$1" ]; then
        echo "error: no SHA-256 pinned for $2" >&2
        exit 1
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        echo "$1  $2" | sha256sum -c -
    else
        echo "$1  $2" | shasum -a 256 -c -
    fi
}

fetch() {
    # Bounded the way the installer's downloads are: a connection that stalls once established
    # must fail this step — visibly, with the digest check never reached — rather than hold the job
    # until its own timeout, and a handshake that never completes is bounded separately.
    curl -fsSL --connect-timeout 20 --speed-limit 1024 --speed-time 30 -o "$2" "$1"
}

shellcheck_archive="$work/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz"
fetch "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" \
    "$shellcheck_archive"
verify "$SHELLCHECK_SHA256" "$shellcheck_archive"
if [ "$verify_only" -eq 0 ]; then
    tar -xJ -C "$work" -f "$shellcheck_archive"
    mv "$work/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" "$into/"
fi
echo "shellcheck ${SHELLCHECK_VERSION} verified"

gitleaks_archive="$work/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
fetch "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
    "$gitleaks_archive"
verify "$GITLEAKS_SHA256" "$gitleaks_archive"
if [ "$verify_only" -eq 0 ]; then
    tar -xz -C "$into" -f "$gitleaks_archive" gitleaks
fi
echo "gitleaks ${GITLEAKS_VERSION} verified"

osv_scanner_binary="$work/osv-scanner"
fetch "https://github.com/google/osv-scanner/releases/download/v${OSV_SCANNER_VERSION}/osv-scanner_linux_amd64" \
    "$osv_scanner_binary"
verify "$OSV_SCANNER_SHA256" "$osv_scanner_binary"
if [ "$verify_only" -eq 0 ]; then
    mv "$osv_scanner_binary" "$into/osv-scanner"
    chmod +x "$into/osv-scanner"
fi
echo "osv-scanner ${OSV_SCANNER_VERSION} verified"
