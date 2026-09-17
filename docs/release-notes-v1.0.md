# ChatBots 1.0 — release notes

ChatBots runs two or more local MLX models against each other on a Mac, watched from a SwiftUI
app or a browser. This is the first release; every claim below names the check that would fail
if it stopped being true, and the checks that did not run are named last.

## The archive

`ChatBots-1.0-macos-arm64.tar.gz` and its `.sha256` sit on the release page. Inside,
`ChatBots.app` carries the engine `chatbots-cli`, the probe `chatbots-probe` and MLX's Metal
kernels in `Contents/MacOS/`; `bin/` holds the executables and kernels again, with `LICENSE`,
`THIRD-PARTY-NOTICES.md`, `SECURITY.md` and `README-binaries.txt`. No model weights.

Backed by `tools/make-release.sh`, which assembles the tree and writes the digest with
`shasum -a 256`; `tools/third-party-notices.py` checks the notice inventory against
`Package.resolved` in CI, and `tools/make-app.sh` fails when the notices are missing.

## Apple silicon only, macOS 26 or later

Native `arm64`, no Intel build and no universal binary; macOS 26 is the floor, because MLX
runs on the GPU and WebTransport requires it. Backed by `tools/make-release.sh`, which runs
`lipo -archs` over every Mach-O file in the staged app and fails unless each reports exactly
`arm64` (at least three must be found), and by the CI check that `LSMinimumSystemVersion`
equals `Package.swift`'s `.macOS(.v26)`.

## The version it reports

`VERSION` at the repository root holds `1.0`, and the bundle's `CFBundleShortVersionString`
and `CFBundleVersion` are both written from it, so a person can say what they are running from
the artefact alone. Backed by `tools/check-identity.sh` (CI, and gate 8 of
`tools/mac-checks.sh`), which fails on a malformed `VERSION`, a copy in `tools/make-app.sh`, or
missing notes; by `tools/make-release.sh`, which re-reads the built bundle; and by
`tools/set-version.sh <X.Y.Z>`, the one command a bump needs.

## The shipped checkpoint

The default is `mlx-community/Qwen3.5-4B-MLX-4bit`, declared once as
`AgentSpec.defaultModelID`; the installer, the CLI defaults and the OpenAI client all read
that declaration. Backed by `Tests/ChatBotsCoreTests/DefaultCheckpointTests.swift`, which pins
the value — which checkpoint ships is a decision, not a number a release propagates — holds
that the literal appears in exactly one source file, and holds that `tools/install.sh` derives
the id and its directory rather than copying either.

## Two front ends over one engine

The app window and the browser interface at `http://localhost:7788` are clients of one
conversation engine, so a conversation started in one appears in the other. The app uses
WebTransport/QUIC; the browser uses HTTP, through Caddy when installed and directly from the
loopback engine when not. Backed by `WebTransportSessionTests.swift`, `HTTPServerTests.swift`,
`EmbeddedWebAssetTests.swift` and `TransportCheckTests.swift`; WebTransport is pinned exactly
to `1.3.7` in `Package.resolved`.

## Show mode

Strong personalities argue about a topic you choose, with no consensus required and no end
condition. Backed by `ModePersonaTests.swift` and `ConversationEngineTests.swift`.

## Research mode

Specialists investigate a question from different methods and produce a report, every claim
labelled and the disagreements and gaps named; a Moderator decides what the question still
owes and hands the next piece of work to the analyst whose method fits it. Backed by
`ResearchEngineTests.swift` ("A research session end to end"), `ResearchReportLabelTests.swift`
("Unlabelled claims are counted against the report"), `DirectedAssignmentTests.swift` and
`ModeratorIdentityTests.swift`.

## Personas, rosters and line-ups

Each seat has a persona, the room has a roster, and a line-up puts a chosen panel in front of a
ready-made question; participant names come from the bundled lists. Backed by
`PersonaTests.swift`, `RosterTests.swift`, `LineupTests.swift` and `NameTests.swift`.

## OpenAI-compatible backends

A seat can run against DeepSeek, LM Studio or any other OpenAI-compatible server instead of a
local checkpoint, and the built-in DeepSeek key is sent only to its own host. Backed by
`OpenAIResponsesTests.swift`, `EndpointPolicyTests.swift` and `BuiltInKeyTests.swift`.

## Tavily web search

A local seat can be given the `web_search` tool, which queries Tavily when a key is configured
and the seat has search enabled. Backed by `ClientsSearchTests.swift`, `TavilyKeyTests.swift`
and `ResearchSearchBudgetTests.swift`.

## Documents and images

Documents and images can be attached to a conversation, converted where the format needs it,
and offered to a model that can see them. Backed by `AttachmentTests.swift`,
`DocumentConversionTests.swift`, `ImageDecodeTests.swift` and `VisionCapabilityTests.swift`.

## Kept conversations, share links and export

Every conversation is written to disk as it runs; a kept one can be reopened or deleted, a
read-only link replays one in a browser, and a conversation or report exports as text or
Markdown. Backed by `ConversationStoreTests.swift`, `ShareLinkTests.swift`,
`SharedConversationTests.swift`, `TranscriptWriterTests.swift` and
`SavedConversationHTTPTests.swift`.

## The security boundary

`SECURITY.md` states the boundary: the engine binds `127.0.0.1` only, while the website, once
started, listens on every interface with no password on `/api/*`, so anyone who can reach that
port can read and steer conversations; `--local-only` keeps it on this Mac. The response
boundary is backed by `SecurityHeaderTests.swift`, `CORSTests.swift`,
`EndpointPolicyTests.swift` and `TraceSwitchTests.swift`; the listener behaviour itself is a
decision written in `Caddyfile` and `tools/start.sh`, not a check.

## What this release was checked with

`tools/mac-checks.sh` runs eight gates on the release Mac: file sizes, `swift build
--build-tests` with warnings-as-errors, `swift test --enable-code-coverage`, an `llvm-cov`
report over `Sources/`, `swiftlint lint`, `swift-format lint`, the two Node web-rule checks and
`tools/check-identity.sh`. The suite measured 1048 tests in 195 suites (1012 in 185, plus 36 in
10); the style gates are judged against the recorded waivers in `tools/analysis-waivers.txt`
(`swiftlint` 217, `swift-format` 444 at the time of writing); the Node checks ran 34 cases for
the streaming merge and 12 for the verdict rule. The coverage gate reports a number and sets no
floor, so it cannot fail on a coverage drop. `tools/make-release.sh` then builds from a clean
scratch path, scans the log for warnings from `Sources/` or `Tests/`, and re-reads the bundle's
identity before packing. CI runs the Linux-side gates on every push and pull request: generated
files, file sizes, third-party notices, `bash -n` and `shellcheck`, `py_compile`, `ruff`,
`pyright`, `gitleaks` over the full history, `semgrep` through `tools/semgrep-waivers.py`,
`osv-scanner` and `tools/check-identity.sh`.

## Checks that did not run, and why

- **Real inference with the shipped checkpoint — not checked, no input.** This checkout has no
  model weights: `models/` is absent and git-ignored, and `tools/install.sh` downloads about
  3 GB into it. No checkpoint could be loaded, so none was; `TurnLoopModelTests.swift` ("The
  turn loop runs on a stubbed model") covers prompt assembly, streaming and the returned turn
  without weights.
- **Notarisation and Developer ID signing — not checked.** There is no Apple Developer ID.
  `tools/make-app.sh` ad-hoc signs each component and the bundle (`codesign --sign -`) and
  reports a failure rather than hiding one, but nothing notarises, so a downloaded copy is
  refused by Gatekeeper; `README-binaries.txt` carries the `xattr -dr com.apple.quarantine`
  command for a user who has verified the digest.
- **A Swift job in CI — not checked, deliberately.** No hosted runner image is macOS 26 on
  Apple silicon with MLX, so the Swift gates cannot run there; `tools/mac-checks.sh` on a Mac
  is the Swift gate.
- **The semgrep rule set — not reproducible from this repository.** The scan runs with
  `--config auto`, so its rules are fetched from the Semgrep registry at scan time and no
  version pin here covers them: the scan ran, but the policy did not come from this checkout.

## Checksum

The digest and archive size are substituted at publish time, from the archive that was built:

```
SHA256_PENDING  ChatBots-1.0-macos-arm64.tar.gz
ARCHIVE_BYTES_PENDING  bytes
```
