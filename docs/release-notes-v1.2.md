# ChatBots 1.2 — release notes

ChatBots runs two or more local MLX models against each other on a Mac, watched from a SwiftUI
app or a browser. **1.2 is a repository-process release: it changes no product code.** The app, the
engine and the command-line tools are the same sources as 1.1. What it carries is the repository's
housekeeping after the September 2026 audit — a changelog, one written standard for the task
tracker, and one place where open work lives.

**If you are running 1.1 there is nothing here to upgrade for.** No behaviour differs, and the
checks that back this release are the same ones that backed 1.1.

## The archive

`ChatBots-1.2-macos-arm64.tar.gz` and its `.sha256` sit on the release page. Inside,
`ChatBots.app` carries the engine `chatbots-cli`, the probe `chatbots-probe` and MLX's Metal
kernels in `Contents/MacOS/`; `bin/` holds the executables and kernels again, with `LICENSE`,
`THIRD-PARTY-NOTICES.md`, `SECURITY.md` and `README-binaries.txt`. No model weights.

Backed by `tools/make-release.sh`, which assembles the tree and writes the digest, and by the notice
checks in `tools/third-party-notices.py` and `tools/make-app.sh`, which fail when one is missing.

## Apple silicon only, macOS 26 or later

Native `arm64`, no Intel build and no universal binary; macOS 26 is the floor, because MLX runs on
the GPU and WebTransport requires it. Backed by `tools/make-release.sh`, which runs `lipo -archs`
over every Mach-O file in the staged archive and fails unless each reports exactly `arm64`, and by
the CI check that `LSMinimumSystemVersion` equals `Package.swift`'s `.macOS(.v26)`.

## The version it reports

This release is `1.2`, tag `v1.2`. `VERSION` at the repository root is the one authoritative value
for it, and the bundle's `CFBundleShortVersionString` and `CFBundleVersion` are both written from
that file. The scheme is `X.Y` — this project has no patch axis, so there is no `1.2.0`. Backed by
`tools/check-identity.sh` (CI, and gate 9 of `tools/mac-checks.sh`), which fails on a malformed
`VERSION`, a copied version, or missing notes, and by `tools/set-version.sh <X.Y[.Z]>`, the one
command a bump needs.

## What changed since 1.1

Nothing that runs. All of it is how the repository keeps its own record:

- **A `CHANGELOG.md` now exists**, which both `AGENTS.md` and `RELEASE.md` already required and
  neither had: it is the announcement for a release and the place history goes — what was tried,
  measured, accepted or rejected. The 1.1 entry records the four security findings the owner
  accepted and the options that were declined instead.
- **Open work lives in exactly one place**, the wiki's Project Tracker: a single table under
  `## Tasks`, with status as a column rather than a heading, governed by
  `docs/task-table-standard.md`. `AGENTS.md` points at both.
- **The audit's second table is gone.** `AUDIT/ledger.md` and the script that rendered it were a
  competing backlog; `AUDIT/` now holds the record — `ledger.json` with all 107 findings, the
  evidence logs and the probes — and no open-work list. Its status note was also stale, still
  reporting a task open and Phase E blocked, and was rewritten.
- **The 1.1 release notes were rewritten** after publication, from a 432-line changelog of audit
  ids and Swift internals into 190 lines of release notes. The release page carries the same text.

## What this release was checked with

`tools/mac-checks.sh` runs nine gates: file sizes, a warnings-as-errors build, the test suite with
coverage, an `llvm-cov` report, `swiftlint --strict`, `swift-format --strict`, the two Node web-rule
checks, `eslint`, `prettier` and the identity check. The suite measures **1102 tests in 201 suites**;
both style gates report zero under `--strict`; the coverage gate reports a number and sets no floor.
`tools/make-release.sh` then builds from a clean scratch path and re-reads the bundle's identity
before packing, and CI runs the Linux-side gates on every push, none of them advisory.

The code in this archive is the code that was verified on a second, independent host at 1.1 — a
fresh clone of the same sources and toolchain, all nine gates, the same 1102 tests. Because not one
source file changed between 1.1 and 1.2, that verification still describes this archive, and it was
not repeated for a documentation release. The record, including the one honest difference it states
about coverage, is in `AUDIT/evidence-phase-e-host.md`.

## Checks that did not run, and why

- **Real inference with the shipped checkpoint — not checked, no input.** This checkout has no model
  weights: `models/` is absent and git-ignored, and `tools/install.sh` downloads about 3 GB into it.
- **Notarisation and Developer ID signing — not checked.** There is no Apple Developer ID. The app
  builder ad-hoc signs each component and the bundle and fails when it cannot, but nothing notarises,
  so a downloaded copy is refused by Gatekeeper until the quarantine flag is cleared.
- **A Swift job in CI — not checked, deliberately.** No hosted runner image is macOS 26 on Apple
  silicon with MLX, so the Swift gates cannot run there; `tools/mac-checks.sh` on a Mac is the gate.
- **Swift analysis by CodeQL — not checked.** CodeQL's default setup analyses `actions`, `python`
  and `javascript-typescript` here; its Swift autobuild cannot parse this package's Swift 6.4
  manifest, so a Swift database was uploaded once and never analysed. That orphaned database has
  been deleted. Real coverage needs advanced setup on an `xcode-27` runner with `build-mode: manual`.
- **The semgrep rule set — not reproducible from this repository.** The scan runs with `--config
  auto`, so its rules are fetched from the Semgrep registry at scan time and no version pin here
  covers them.
- **ThreadSanitizer — no run recorded.** `AUDIT/tool-coverage.md` names
  `swift test --sanitize=thread`, but no log shows a run of it; the concurrency work was checked
  instead by the Swift 6 language mode and a strict-concurrency probe.
- **A Python dependency audit — nothing to scan.** There is no `requirements.txt` or lock file for
  `tools/`, so there are no third-party Python packages to check.
- **The installer's interactive catalogue menu has no behavioural test.** It is covered by the build
  and the suites that drive the real paths, not by a test that asserts the menu's behaviour.

## Checksum

The digest and archive size are substituted at publish time, from the archive that was built:

```
SHA256_PENDING  ChatBots-1.2-macos-arm64.tar.gz
ARCHIVE_BYTES_PENDING  bytes
```
