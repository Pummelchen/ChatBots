#!/usr/bin/env bash
# ChatBots — the version is stated once and everything that names it agrees.
#
# `VERSION` at the repository root is the one authoritative value. Anything else that carries
# the number is a mirror, and this fails when a mirror disagrees rather than at release time.
# It checks what can be checked without building: the file is a semantic version, the bundle
# builder derives from it instead of declaring its own copy, the release notes for it exist,
# and — when a tag is named — the tag is `v` followed by it.
#
# The built app's `CFBundleShortVersionString` is a mirror too, and it is checked where it
# exists: `tools/make-release.sh` reads it out of the assembled bundle.
#
# usage: bash tools/check-identity.sh [--tag <tag>]
# exit:  0 when the identity is consistent, 1 when it is not

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

tag=""
while [ $# -gt 0 ]; do
    case "$1" in
        --tag)
            tag="${2:?--tag needs a tag name}"
            shift 2
            ;;
        -h | --help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            printf 'unknown argument: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

failed=0

fail() {
    printf 'FAIL  identity: %s\n' "$1"
    failed=1
}

if [ ! -f VERSION ]; then
    fail "there is no VERSION file at the repository root"
    exit 1
fi

version="$(tr -d '[:space:]' < VERSION)"
if printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
    printf 'PASS  identity: VERSION is the semantic version %s\n' "$version"
else
    fail "VERSION holds '$version', which is not a semantic version (expected X.Y or X.Y.Z)"
    exit 1
fi

# The bundle builder must derive the version, not carry one. A literal here is a second
# declaration, and two declarations are how a wrong version ships. "Derives" is tested two
# ways: the assignment's right-hand side starts with a digit (a literal) rather than with a
# substitution, and at least one assignment reads `VERSION`.
literal_version() {
    grep -nE "^[[:space:]]*$1=[\"']?[0-9]" tools/make-app.sh >/dev/null 2>&1
}

if literal_version APP_VERSION; then
    fail "tools/make-app.sh assigns APP_VERSION a literal; it must read VERSION"
elif grep -qE '^[[:space:]]*APP_VERSION=.*VERSION' tools/make-app.sh; then
    printf 'PASS  identity: tools/make-app.sh derives the version from VERSION\n'
else
    fail "tools/make-app.sh does not read VERSION when it sets APP_VERSION"
fi

if literal_version APP_BUILD; then
    fail "tools/make-app.sh assigns APP_BUILD a literal; this project versions by semantic version only"
fi

notes="docs/release-notes-v${version}.md"
if [ -f "$notes" ]; then
    printf 'PASS  identity: %s exists\n' "$notes"
else
    fail "no release notes at $notes"
fi

if [ -n "$tag" ]; then
    if [ "$tag" = "v${version}" ]; then
        printf 'PASS  identity: the tag %s matches VERSION\n' "$tag"
    else
        fail "the tag is $tag but VERSION is $version (expected v$version)"
    fi
fi

if [ "$failed" -ne 0 ]; then
    printf 'FAIL  identity: the version and its mirrors disagree\n'
    exit 1
fi

printf 'PASS  identity: %s is stated once and agrees everywhere\n' "$version"
