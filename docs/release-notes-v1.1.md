# ChatBots 1.1 — release notes

ChatBots runs two or more local MLX models against each other on a Mac, watched from a SwiftUI
app or a browser. 1.1 follows the September 2026 pre-production audit; its headline change is that
the engine now proves who it is before the app hands it any credential. Every claim names the check
that would fail if it stopped being true, the checks that did not run are named last, and the full
record is in `AUDIT/ledger.json`.

## The archive

`ChatBots-1.1-macos-arm64.tar.gz` and its `.sha256` sit on the release page. Inside,
`ChatBots.app` carries the engine `chatbots-cli`, the probe `chatbots-probe` and MLX's Metal
kernels in `Contents/MacOS/`; `bin/` holds the executables and kernels again, with `LICENSE`,
`THIRD-PARTY-NOTICES.md`, `SECURITY.md` and `README-binaries.txt`. No model weights.

Backed by `tools/make-release.sh`, which assembles the tree and writes the digest, and by the notice
checks in `tools/third-party-notices.py` and `tools/make-app.sh`, which fail when one is missing.

## Apple silicon only, macOS 26 or later

Native `arm64`, no Intel build and no universal binary; macOS 26 is the floor, because MLX runs on
the GPU and WebTransport requires it. Backed by `tools/make-release.sh`, which runs `lipo -archs`
over every Mach-O file in the staged archive and fails unless each reports exactly `arm64` (at
least three must be found), and by the CI check that `LSMinimumSystemVersion` equals
`Package.swift`'s `.macOS(.v26)`.

## The version it reports

This release is `1.1`, tag `v1.1`. `VERSION` at the repository root is the one authoritative value
for it, and the bundle's `CFBundleShortVersionString` and `CFBundleVersion` are both written from
that file, so a person can say what they are running from the artefact alone. Backed by
`tools/check-identity.sh` (CI, and gate 9 of `tools/mac-checks.sh`), which fails on a malformed
`VERSION`, a copied version, or missing notes; by `tools/make-release.sh`, which re-reads the built
bundle's keys; and by `tools/set-version.sh <X.Y[.Z]>`, the one command a bump needs.

## The engine now proves who it is

Before this release the app adopted whatever process answered on the engine's transport port and
then sent it every seat's cloud API key from the Keychain; the local transport does not verify the
peer, so a same-user process that took the port was adopted and handed the keys. Now the engine
writes a fresh random token to its run directory, readable only by its owner, before it accepts a
connection, and echoes it over a transport-only identity request. The app reads the same file and
adopts only an engine that returns the token, reporting one that cannot identify itself and sending
it nothing. No HTTP route or status snapshot returns the token.

The limits are part of the note. The file is owner-only but readable by any process running as the
same user, so it closes the window in which the port is taken before the engine starts; it does not
make a same-user attacker impossible. A token also outlives an engine killed with `SIGKILL`, and
the certificate fingerprint is still reported rather than enforced, so an impersonating loopback
peer would not be revealed by it. An engine started by an older build cannot identify itself and
will not be adopted — intended, and the case on the first run after updating.

Backed by `SessionTokenTests.swift`, `SessionTokenTransportTests.swift`, `SessionTokenHTTPTests.swift`
and `EngineIdentityTests.swift`; the control was watched live (`AUDIT/evidence-0058-live.md`).

## Credentials and private files

Secrets on disk are now private: a group- or world-readable `.secrets.env` is restricted when
read, kept conversations and their index are owner-only, and the engine's TLS key is never briefly
world-readable. Programs the engine starts inherit a short allow-list of variables and never a
cloud key or the trace switch, and the Tavily key is refused on the command line.

Backed by `BuiltInKeyTests.swift`, `TraceSwitchTests.swift` and
`CertificateIdentityIntegrityTests.swift`; shellcheck covers the start scripts.

## Input the engine cannot trust

Fetched pages and search summaries enter the prompt inside an explicit untrusted-data fence, and a
topic or seat name can no longer forge a transcript boundary or a `[timestamp] NAME` speaker line.
A model id cannot escape the models directory; redirects are reported rather than followed with a
bearer key attached; and loopback, private, link-local and unspecified addresses are refused. An
absurd viewport is answered as unknown instead of trapping, a declared context window and the
generation cap are clamped so neither can overflow, and a PDF's page count is bounded. Attachments
are measured before decoding, capped at 256 MB, and a read error is reported rather than returned.

Backed by `TurnLoopRuleTests.swift`, `ResearchPromptTrustTests.swift`, `ShardedCheckpointTests.swift`,
`EndpointPolicyTests.swift`, `DeviceProfileTests.swift`, `ImageUploadTests.swift` and `RealExtractorTests.swift`.

## Conversations, turns and budgets

A conversation that cannot be saved is reported once instead of disappearing quietly, and deleting
the history also removes a stranded temporary. A turn that produces no text still charges the
research budget, a search retry is billed as two searches rather than one, one turn dispatches at
most eight tool calls, and Tavily's own answer is kept as the first search hit instead of dropped.

Backed by `ConversationReportingTests.swift`, `StoreRecoveryTests.swift`,
`ResearchSearchBudgetTests.swift` and `ClientsSearchTests.swift`.

## The transport and the HTTP surface

A fresh connection no longer fails with the previous session's error. A slow peer cannot hold the
server open: a request has a wall-clock ceiling, and the event feed closes once a client falls too
far behind. Responses carry their real status phrases, a seat setting the engine cannot honour is
refused with the values it accepts, a refused model change no longer renames the seat, and a changed
base URL or API key reaches the live client. An oversized or unparseable stream event fails the
stream, and endpoint routing matches parsed hosts rather than substrings.

Backed by `TransportLifecycleTests.swift`, `WebTransportSessionTests.swift`, `HTTPLimitTests.swift`,
`HTTPServerTests.swift`, `ClientsStreamTests.swift` and `EndpointPolicyTests.swift`.

## The app, the command line and the web front end

In the app, a refusal is now treated as a refusal: a rejected steer no longer clears the
moderator's draft, and a refused checkpoint is not shown as applied. Closing the window disconnects
the client before the engine is shut down, attachments are read off the main thread so large files
do not block it, and a corrupted text-scale preference is sanitised instead of crashing. On the
command line, flags only another mode can honour are refused, and a headless run exits non-zero
when a turn failed. In the browser, following stops when the reader scrolls, a typed topic is
committed before start, and Cmd or Ctrl+Enter no longer also presses Start.

Backed by `RefusalTests.swift` and `ZoomStepTests.swift`; the page's interaction fixes have no browser test.

## Building, releasing and the repository's own standards

A reused gate log must carry the commit it measured; a signature that fails fails the build; and a
scratch directory is refused unless it is inside the checkout's build tree, so the release path's
recursive delete cannot be pointed at the source. Model weights are verified against the per-file
SHA-256 the hub publishes at all three success points, and the installer now offers the whole
checkpoint catalogue with sizes.

Both style gates run `--strict` against zero and the waiver caps are gone: SwiftLint went from 206
findings to 0, swift-format from 306 diagnostics to 0, and Python's committed `ruff.toml` is clean.

Backed by the scripts themselves (`bash -n` and `shellcheck -S style` in CI), by gates 5 and 6 of
`tools/mac-checks.sh`, and by `ModelChoiceTests.swift` for the installer catalogue.

## What this release was checked with

`tools/mac-checks.sh` runs nine gates on the release Mac: file sizes, a warnings-as-errors build,
the test suite with coverage, an `llvm-cov` report, `swiftlint --strict`, `swift-format --strict`,
the two Node web-rule checks (34 and 12 cases), `eslint`, `prettier` and the identity check. The
suite measured 1102 tests in 201 suites against the audit's baseline of 1048 in 195; both style
gates report zero under `--strict`; the coverage gate reports a number and sets no floor.
`tools/make-release.sh` then builds from a clean scratch path and re-reads the bundle's identity
before packing, and CI runs the Linux-side gates on every push, none of them advisory.

The tree was verified a second time on an independent host, on a fresh clone of the same commit and
toolchain: all nine gates passed with the same 1102 tests in 201 suites
(`AUDIT/evidence-phase-e-host.md`). One honest difference the record states: the coverage total there
was much lower because the run measured a different object set, and the gate enforces no floor.

## Accepted risks

These are decisions on the record, not fixes. The repository owner reviewed them and accepted them
on 2026-09-18, and the behaviour each describes is still present and still deliberate.

- **The API is unauthenticated, and by default reachable from the LAN.** The engine binds loopback,
  but the shipped start script runs Caddy from a site address that carries no host, so the proxied
  `/api/*` and `/s/*` routes are served on every interface with no password: anyone who can reach
  the site can read every kept conversation and drive the run controls.
- **The published site is plaintext on every interface.** There is no TLS, so an on-path reader can
  also write. That default is what lets a phone on the same Wi-Fi use the interface; use
  `--local-only` to keep it on this Mac, or front it with your own authentication.
- **DNS rebinding defeats the same-origin check.** The check compares two names the browser derives
  from the URL it fetched, so a page that DNS-rebinds to this Mac looks same-origin to it. Accepted
  as part of the LAN-trust model above; authentication and a Host allow-list were both declined.
- **The session token has limits.** It closes the window in which the port is taken before the
  engine starts, but the file is readable by any process running as the same user, so it does not
  make a same-user attacker impossible; a token also survives an engine killed with `SIGKILL`.

## Checks that did not run, and why

- **Real inference with the shipped checkpoint — not checked, no input.** This checkout has no model
  weights: `models/` is absent and git-ignored, and `tools/install.sh` downloads about 3 GB into it;
  no checkpoint was loaded.
- **Notarisation and Developer ID signing — not checked.** There is no Apple Developer ID. The app
  builder ad-hoc signs each component and the bundle and fails when it cannot, and the release path
  verifies the built bundle, but nothing notarises, so a downloaded copy is refused by Gatekeeper.
- **A Swift job in CI — not checked, deliberately.** No hosted runner image is macOS 26 on Apple
  silicon with MLX, so the Swift gates cannot run there; `tools/mac-checks.sh` on a Mac is the gate.
- **The semgrep rule set — not reproducible from this repository.** The scan runs with `--config
  auto`, so its rules are fetched from the Semgrep registry at scan time and no version pin here
  covers them.
- **ThreadSanitizer — no run recorded.** The project's tool-coverage note names
  `swift test --sanitize=thread`, but no log or record shows a run of it or its result. The
  concurrency work was checked instead by the Swift 6 language mode and a strict-concurrency probe.
- **A Python dependency audit — nothing to scan.** There is no `requirements.txt` or lock file for
  `tools/`, so there are no third-party Python packages to check.
- **Some fixes have no behavioural test.** The transport's single-writer queue, the engine's
  load/unload ordering, the session-reuse probe's Metal gate, several app lifecycle changes and the
  installer's interactive catalogue menu are covered by the build and suites, not by a test.

## Checksum

The digest and archive size are substituted at publish time, from the archive that was built:

```
SHA256_PENDING  ChatBots-1.1-macos-arm64.tar.gz
ARCHIVE_BYTES_PENDING  bytes
```
