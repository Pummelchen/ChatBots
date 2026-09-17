#!/usr/bin/env bash
# ChatBots — package a release, and publish it only when told to.
#
# This is the one command RELEASE.md asks for: it checks the preconditions §1.4 names, runs the
# gates §1.5 names, builds the products from a clean scratch path so the package cannot come
# from an incremental build, assembles the archive §1.6 describes, asserts the architecture
# §1.2.2 requires, writes the digest §1.2.5 requires, substitutes the notes §1.8 requires — and
# then stops. `--publish` is the explicit flag §1.2.6 asks for: it tags the commit that was
# built, pushes the tag, creates the Release with the archive and its checksum, and downloads
# them again to verify §1.9.
#
# Everything it produces is staged under `dist/release/<version>/` (git-ignored, like `dist/`),
# including the record of what was checked and the exact build log.
#
# `--reuse-staging` publishes the artifact a previous dry run already built: it re-checks that the
# record names this same commit, that the archive still matches its digest, and that the clean
# build passed, so a publish retry does not need a second clean build. Without it the release is
# built from scratch.
#
# usage: bash tools/make-release.sh [--publish] [--gates-log <file>] [--scratch <dir>] [--reuse-staging]
# exit:  0 when the run finished (see the report for whether it published), 1 failed check, 2 usage

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"

PUBLISH=0
GATES_LOG=""
SCRATCH=""
REUSE=0

usage() {
    # The header comment, and only it: stop at the first line that is not one.
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --publish) PUBLISH=1; shift ;;
        --gates-log) GATES_LOG="${2:?--gates-log needs a file}"; shift 2 ;;
        --scratch) SCRATCH="${2:?--scratch needs a directory}"; shift 2 ;;
        --reuse-staging) REUSE=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *)
            printf 'unknown argument: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

for tool in swift xcrun lipo shasum tar gh git; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf 'missing required tool: %s\n' "$tool" >&2
        exit 2
    }
done

step() { printf '\n=== %s ===\n' "$1"; }

die() {
    printf 'FAIL  %s\n' "$1" >&2
    exit 1
}

# ---------------------------------------------------------------- identity and staging

[ -f VERSION ] || die "no VERSION at the repository root; run tools/set-version.sh <X.Y.Z>"
VERSION="$(tr -d '[:space:]' < VERSION)"
printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || die "VERSION holds '$VERSION', which is not a semantic version"
TAG="v$VERSION"
NAME="ChatBots-$VERSION-macos-arm64"
STAGE="$ROOT/dist/release/$VERSION"
STAGING="$STAGE/$NAME"
APP="$STAGING/ChatBots.app"
ARCHIVE="$STAGE/$NAME.tar.gz"
CHECKSUM="$ARCHIVE.sha256"
NOTES="docs/release-notes-v$VERSION.md"
RECORD="$STAGE/release-record.txt"
SCRATCH="${SCRATCH:-$ROOT/.build/release-scratch-$VERSION}"
SLUG="$(git remote get-url origin | sed -E 's#(git@|https://)github\.com[:/]##; s#\.git$##')"

mkdir -p "$STAGE"
[ "$REUSE" -eq 1 ] || : > "$RECORD"

record() {
    printf '%s\n' "$1" | tee -a "$RECORD"
}

record "release record — ChatBots $VERSION ($TAG)"
record "started: $(date -u '+%Y-%m-%dT%H:%M:%SZ')  host: $(hostname -s)  publish: $PUBLISH  reuse: $REUSE"
record "repository: $SLUG"

# ---------------------------------------------------------------- preconditions (RELEASE.md §1.4)

step "1/7  preconditions"
[ "$(uname -m)" = "arm64" ] || die "this is $(uname -m); the release is arm64 only"
FLOOR="$(grep -oE '\.macOS\(\.v[0-9]+\)' Package.swift | grep -oE '[0-9]+' | head -1)"
OS_VERSION="$(sw_vers -productVersion)"
OS_MAJOR="${OS_VERSION%%.*}"
[ "$OS_MAJOR" -ge "$FLOOR" ] || die "macOS $OS_VERSION is below the package floor of $FLOOR"
SWIFT_VERSION="$(swift --version 2>&1 | head -1)"
FREE_GIB="$(df -g "$ROOT" | awk 'NR == 2 { print $4 }')"
[ "$FREE_GIB" -ge 10 ] || die "only ${FREE_GIB} GiB free; a clean build and the archive need 10"
MEM_FREE="$(memory_pressure -Q 2>/dev/null | sed -n 's/.*free percentage: \([0-9]*\)%.*/\1/p')"
[ -n "$MEM_FREE" ] && [ "$MEM_FREE" -ge 20 ] || die "memory pressure reports ${MEM_FREE:-unknown}% free"
if [ -n "$(git status --porcelain)" ]; then
    die "the tree is dirty; a release is cut from a clean tree"
fi
HEAD_SHA="$(git rev-parse HEAD)"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if ! gh auth status >/dev/null 2>&1; then
    die "gh is not authenticated; the release is published with it"
fi
ACCOUNT="$(gh api user -q .login)"
[ "$ACCOUNT" = "Pummelchen" ] || die "gh is authenticated as $ACCOUNT, not the repository owner"
record "  macOS $OS_VERSION, floor $FLOOR, $SWIFT_VERSION"
record "  ${FREE_GIB} GiB free, memory ${MEM_FREE}% free"
record "  tree clean on $BRANCH at $HEAD_SHA; gh account $ACCOUNT"

# A competing build of *this repository* would share nothing with our scratch path, but it
# would take the machine's CPU and it is what §1.4 asks about. Anything else that is merely
# compiling (another session's scratch work) is named and left alone: it is not ours to stop.
COMPETING=""
while read -r pid; do
    [ -n "$pid" ] || continue
    cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
    case "$cwd" in
        "$ROOT"*) COMPETING="$COMPETING $pid:$cwd" ;;
    esac
done < <(pgrep -f 'swift-build|swift-frontend|swiftc|xcodebuild' || true)
[ -z "$COMPETING" ] || die "a build of this repository is running:$COMPETING — stop it and re-run"

OTHER="$(pgrep -fl 'swift-build|swift-frontend|swiftc|xcodebuild' 2>/dev/null | head -5 || true)"
if [ -n "$OTHER" ]; then
    record "  other compilers on the machine (not this repository, left alone):"
    printf '%s\n' "$OTHER" | while read -r line; do record "    $line"; done
fi

if [ "$PUBLISH" -eq 1 ]; then
    if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
        TAGGED="$(git rev-parse "refs/tags/$TAG^{commit}")"
        [ "$TAGGED" = "$HEAD_SHA" ] || die "tag $TAG points at $TAGGED, not at HEAD ($HEAD_SHA)"
        record "  tag $TAG already exists and points at HEAD"
    else
        record "  tag $TAG does not exist; it will be created at $HEAD_SHA"
    fi
fi

# ---------------------------------------------------------------- gates (RELEASE.md §1.5)

if [ "$REUSE" -eq 1 ]; then
    step "2/7  reusing the staged release"
    grep -q "at $HEAD_SHA" "$RECORD" || die "the record at $RECORD is not for $HEAD_SHA; run without --reuse-staging"
    grep -q "clean build succeeded" "$RECORD" || die "the record shows no clean build; run without --reuse-staging"
    [ -f "$ARCHIVE" ] || die "the staged archive $ARCHIVE is gone; run without --reuse-staging"
    [ -f "$CHECKSUM" ] || die "the staged checksum is gone; run without --reuse-staging"
    [ -f "$STAGE/release-notes.md" ] || die "the staged notes are gone; run without --reuse-staging"
    ( cd "$STAGE" && shasum -a 256 -c "$NAME.tar.gz.sha256" ) >/dev/null \
        || die "the staged archive no longer matches its checksum"
    SHA256="$(awk '{ print $1 }' "$CHECKSUM")"
    BYTES="$(stat -f%z "$ARCHIVE")"
    record "  reusing $ARCHIVE from the earlier run at $HEAD_SHA"
    record "  sha256 $SHA256 — verified against the checksum beside it"
else
step "2/7  gates"
if [ -n "$GATES_LOG" ]; then
    # A gate run that already happened on this same commit may be reused; its output is copied
    # into the record rather than paraphrased, so the release says what was actually measured.
    [ -f "$GATES_LOG" ] || die "--gates-log $GATES_LOG does not exist"
    cp "$GATES_LOG" "$STAGE/gates-reused.txt"
    grep -q 'Mac-only gates passed' "$GATES_LOG" || die "the reused gate log does not show a passing run"
    record "  gates reused from $GATES_LOG (recorded in gates-reused.txt)"
else
    bash tools/check-identity.sh | tee "$STAGE/identity.txt"
    bash tools/mac-checks.sh | tee "$STAGE/mac-checks.txt" || die "mac-checks.sh failed"
    grep -q 'Mac-only gates passed' "$STAGE/mac-checks.txt" || die "mac-checks.sh did not report a passing run"
    record "  gates: tools/check-identity.sh and tools/mac-checks.sh (recorded in mac-checks.txt)"
fi
bash tools/check-identity.sh --tag "$TAG" >> "$RECORD"

# ---------------------------------------------------------------- clean build (RELEASE.md §1.5.4)

step "3/7  clean scratch build and bundle"
record "  scratch path: $SCRATCH (removed and rebuilt for this release)"
rm -rf "$SCRATCH" "$STAGING"
mkdir -p "$STAGING"
if ! bash tools/make-app.sh --scratch "$SCRATCH" --out "$APP" > "$STAGE/clean-build.log" 2>&1; then
    tail -n 25 "$STAGE/clean-build.log" >&2
    die "the clean build failed; the log is $STAGE/clean-build.log"
fi

# The pattern wants a diagnostic that *is* an error: `path:line:col: error: …`, or SwiftPM's
# own `error: …` at the start of a line. A warning whose prose happens to contain "an error:"
# — the SwiftPM cache says exactly that — is not one, which is why the first version of this
# scan failed a build that had succeeded.
if grep -nE '(^|: )error: |^error: |The following build commands failed' "$STAGE/clean-build.log" >/dev/null; then
    grep -nE '(^|: )error: |^error: |The following build commands failed' "$STAGE/clean-build.log" >&2
    die "the clean build reported errors"
fi

# Warnings from our own code fail the release; warnings from the build system or a dependency
# do not, but each one is written into the record verbatim, because "no warnings" and "no
# warnings we looked at" are different sentences.
grep -nE 'warning:' "$STAGE/clean-build.log" > "$STAGE/build-warnings.txt" || true
# "Ours" means the line names a file under this checkout's own Sources/ or Tests/ — not a
# dependency that happens to keep its code in a directory called `Sources/`, which is most of
# them. In practice our sources cannot warn at all (warnings are errors per target), so this is
# the belt to that braces: it fails the release if one ever gets through.
OURS="(^|[^-])(($ROOT/)?(Sources|Tests)/)"
if grep -E "warning:.*$OURS" "$STAGE/build-warnings.txt" > "$STAGE/our-warnings.txt"; then
    cat "$STAGE/our-warnings.txt" >&2
    die "the clean build warned about this repository's own sources"
fi
rm -f "$STAGE/our-warnings.txt"
WARNING_COUNT="$(grep -c 'warning:' "$STAGE/clean-build.log" || true)"
record "  clean build succeeded; $WARNING_COUNT warning line(s), none from this repository's sources"
if [ "$WARNING_COUNT" -gt 0 ]; then
    record "  warning kinds: $(grep -oE '\[-W[a-z0-9+-]+\]' "$STAGE/build-warnings.txt" | sort -u | tr '\n' ' ')"
    head -5 "$STAGE/build-warnings.txt" | sed 's/^[0-9]*://' | sed 's/^/    /' | while read -r line; do record "$line"; done
    [ "$WARNING_COUNT" -le 5 ] || record "    … and $((WARNING_COUNT - 5)) more, verbatim in build-warnings.txt"
fi

# ---------------------------------------------------------------- artifact checks

step "4/7  the bundle says what it is (RELEASE.md §1.3)"
PLIST="$APP/Contents/Info.plist"
[ -f "$PLIST" ] || die "the assembled bundle has no Info.plist"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c Print:CFBundleShortVersionString "$PLIST")"
PLIST_BUILD="$(/usr/libexec/PlistBuddy -c Print:CFBundleVersion "$PLIST")"
[ "$PLIST_VERSION" = "$VERSION" ] || die "the bundle reports $PLIST_VERSION, VERSION holds $VERSION"
[ "$PLIST_BUILD" = "$VERSION" ] || die "the bundle's build number is $PLIST_BUILD, not $VERSION"
record "  bundle identity: CFBundleShortVersionString and CFBundleVersion are both $VERSION"

# ---------------------------------------------------------------- assemble the archive

step "5/7  the archive, and arm64 only (RELEASE.md §1.2.2, §1.6)"
mkdir -p "$STAGING/bin"
for product in chatbots-cli chatbots-probe mlx.metallib; do
    [ -f "$APP/Contents/MacOS/$product" ] || die "the bundle has no $product, so the archive would be incomplete"
    cp "$APP/Contents/MacOS/$product" "$STAGING/bin/"
done
[ -f LICENSE ] || die "there is no LICENSE to ship"
[ -f THIRD-PARTY-NOTICES.md ] || die "there are no third-party notices to ship"
[ -f SECURITY.md ] || die "there is no SECURITY.md to ship"
for bundle in "$APP/Contents/Resources/"*.bundle; do
    cp -R "$bundle" "$STAGING/bin/"
done
cp LICENSE "$STAGING/LICENSE"
cp THIRD-PARTY-NOTICES.md "$STAGING/THIRD-PARTY-NOTICES.md"
cp SECURITY.md "$STAGING/SECURITY.md"

cat > "$STAGING/README-binaries.txt" <<TXT
ChatBots $VERSION — macOS $FLOOR or later, Apple silicon only (arm64)

This archive contains:

  ChatBots.app         the SwiftUI app. It carries its own engine (chatbots-cli) and the
                       transport probe (chatbots-probe) in Contents/MacOS/, plus the Metal
                       kernels the models run on.
  bin/chatbots-cli     the engine on its own, for a headless run or an HTTP/WebTransport server.
  bin/chatbots-probe   the transport diagnostic the troubleshooting notes tell you to run.
  LICENSE              the MIT licence this project is released under.
  THIRD-PARTY-NOTICES.md  the licences of every dependency the binaries link.
  SECURITY.md          the trust boundary, and how to report a problem.

Not code-signed or notarised: this build is ad-hoc signed only, so Gatekeeper refuses it on
first launch. After checking the digest beside this archive, clear the quarantine flag:

  xattr -dr com.apple.quarantine ChatBots.app

Model weights are not included — they are multi-gigabyte downloads, not build output. In a
checkout, \`bash tools/install.sh\` fetches the checkpoint the app ships with into \`models/\`;
the app finds a local checkpoint there. Without one, the app starts and reports that no
checkpoint is available.

This build is arm64 only, and it says so: \`lipo -archs ChatBots.app/Contents/MacOS/ChatBots\`
prints \`arm64\`. The app reports its own version as $VERSION
(CFBundleShortVersionString in ChatBots.app/Contents/Info.plist).
TXT

# The arch assertion runs here, over the finished staging tree, so it covers everything the
# archive will contain — the app's own Mach-O files and the stand-alone copies in `bin/` — rather
# than the bundle alone. §1.2.2 asks about the artifact, and the artifact is what gets tarred.
ARCH_FAILURES=0
MACHO_COUNT=0
while IFS= read -r file; do
    file -b "$file" | grep -q 'Mach-O' || continue
    MACHO_COUNT=$((MACHO_COUNT + 1))
    ARCHS="$(lipo -archs "$file" 2>&1)"
    if [ "$ARCHS" != "arm64" ]; then
        printf 'FAIL  %s reports %s\n' "$file" "$ARCHS" >&2
        ARCH_FAILURES=$((ARCH_FAILURES + 1))
    fi
done < <(find "$STAGING" -type f -perm -u+x 2>/dev/null)
[ "$MACHO_COUNT" -ge 3 ] || die "only $MACHO_COUNT Mach-O files found; the archive is incomplete"
[ "$ARCH_FAILURES" -eq 0 ] || die "$ARCH_FAILURES Mach-O file(s) are not exactly arm64"
record "  lipo -archs: all $MACHO_COUNT Mach-O files in the archive report exactly arm64"

( cd "$STAGE" && COPYFILE_DISABLE=1 tar -czf "$NAME.tar.gz" "$NAME" )
( cd "$STAGE" && shasum -a 256 "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )
SHA256="$(awk '{ print $1 }' "$CHECKSUM")"
BYTES="$(stat -f%z "$ARCHIVE")"
HUMAN="$(du -h "$ARCHIVE" | awk '{ print $1 }')"
record "  $NAME.tar.gz — $BYTES bytes ($HUMAN), sha256 $SHA256"

# ---------------------------------------------------------------- the notes (RELEASE.md §1.8)

fi

step "6/7  release notes"
[ -f "$NOTES" ] || die "no release notes at $NOTES"
if grep -q 'SHA256_PENDING' "$NOTES"; then
    sed -e "s/SHA256_PENDING/$SHA256/" -e "s/ARCHIVE_BYTES_PENDING/$BYTES/" "$NOTES" \
        > "$STAGE/release-notes.md"
elif [ -f "$STAGE/release-notes.md" ] && grep -q "$SHA256" "$STAGE/release-notes.md"; then
    : # already substituted by the run that built this archive
elif grep -q "$SHA256" "$NOTES"; then
    cp "$NOTES" "$STAGE/release-notes.md"
else
    die "$NOTES carries neither the pending placeholders nor the real digest"
fi
grep -q "$SHA256" "$STAGE/release-notes.md" || die "the published notes do not quote the digest"
record "  notes: $NOTES (placeholders substituted into release-notes.md)"

# ---------------------------------------------------------------- publish (RELEASE.md §1.7, §1.9)

step "7/7  publish"
if [ "$PUBLISH" -eq 0 ]; then
    cat <<SUMMARY

Dry run complete — nothing was tagged and nothing was published.

  archive   $ARCHIVE
  checksum  $CHECKSUM
  sha256    $SHA256
  bytes     $BYTES
  notes     $STAGE/release-notes.md
  record    $RECORD

Re-run with --publish to tag $TAG at $HEAD_SHA and create the Release.
SUMMARY
    exit 0
fi

[ "$BRANCH" = "main" ] || die "publishing is done from main, and this is $BRANCH"
if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
    git tag -a "$TAG" -m "ChatBots $VERSION" "$HEAD_SHA"
    record "  created tag $TAG at $HEAD_SHA"
fi
git push origin "refs/tags/$TAG"
record "  pushed tag $TAG"

if gh release view "$TAG" --repo "$SLUG" >/dev/null 2>&1; then
    record "  the Release for $TAG already exists; verifying it instead of recreating it"
else
    gh release create "$TAG" "$ARCHIVE" "$CHECKSUM" \
        --repo "$SLUG" \
        --title "ChatBots $VERSION" \
        --notes-file "$STAGE/release-notes.md" \
        --latest
    record "  created the Release for $TAG"
fi

step "verifying the published release (RELEASE.md §1.9)"
VERIFY_DIR="$(mktemp -d)"
trap 'rm -rf "$VERIFY_DIR"' EXIT
gh release download "$TAG" --repo "$SLUG" --dir "$VERIFY_DIR"
( cd "$VERIFY_DIR" && shasum -a 256 -c "$NAME.tar.gz.sha256" ) | tee -a "$RECORD"
[ -f "$VERIFY_DIR/$NAME.tar.gz" ] || die "the downloaded release has no archive"
[ -f "$VERIFY_DIR/$NAME.tar.gz.sha256" ] || die "the downloaded release has no checksum"
ASSETS="$(gh release view "$TAG" --repo "$SLUG" --json assets -q '.assets[].name' | sort | tr '\n' ' ')"
gh release view "$TAG" --repo "$SLUG" --json body -q .body | grep -q "$SHA256" \
    || die "the published notes do not quote the digest"
record "  assets: $ASSETS"
record "  downloaded archive verifies against its checksum; notes quote the digest"
record "  url: $(gh release view "$TAG" --repo "$SLUG" --json url -q .url)"
record "finished: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

printf '\nPublished: %s\n' "$(gh release view "$TAG" --repo "$SLUG" --json url -q .url)"
