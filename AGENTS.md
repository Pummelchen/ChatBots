# ChatBots

<!-- agent-harnesses:begin -->
> **One instruction file.** This is it. Codex, DeepSeek Harness, OpenCode,
> Qwen Code, Qoder and Zed read `AGENTS.md` directly, and Claude Code reads it
> through the committed `CLAUDE.md`, which is the `@AGENTS.md` import plus a
> comment saying why it is committed rather than a symlink.
> **Edit only this file** — do not add a second set of instructions anywhere.
>
> Do **not** add `.rules`, `.cursorrules`, `.windsurfrules`, `.clinerules`,
> `.github/copilot-instructions.md` or `AGENT.md`. Zed takes the *first match*
> from that list, **ahead of `AGENTS.md`**, so any one of them silently
> replaces this file for every Zed user.
<!-- agent-harnesses:end -->

Two or more local MLX LLMs argue with each other on a Mac, watched from a SwiftUI
app or a browser. Four products share one package — `ChatBots` (the SwiftUI app),
`chatbots-cli` (a headless engine runner), `chatbots-probe` (a transport probe) and
`ChatBotsCore` (the library). Two front ends share one conversation engine: the
desktop app reaches it over WebTransport/QUIC, the website over HTTP through Caddy.
Models run locally via MLX; OpenAI-compatible backends and Tavily tools are
supported. Release `1.0` is the first: `tools/make-release.sh` builds and publishes it, and
`bash tools/install.sh` in a checkout remains the way to get a working install with its models.
Swift 6.4 / SwiftPM, package floor macOS 26, Apple Silicon only.

## Layout

- `Sources/ChatBotsCore/` — the engine-agnostic domain: 99 files in topic directories. `Engine/`
  (the MLX engine, the engine service and the turn loop), `Conversation/` (the engine that drives a
  room), `Room/` (seats, personas, rosters, modes and the social library), `Prompt/`, `Research/`
  (the moderator, its reading and the report), `HTTP/` (the server and its API), `Transport/`
  (WebTransport and certificates), `OpenAI/`, `Attachments/`, `Models/` and `Support/`. The two
  **generated** files, `WebAssets.swift` and `NameLists.swift`, stay at the target root because the
  embed tools write them there by name.
- `Sources/ChatBotsApp/` — the SwiftUI app, with `Views/` holding the window and its rows.
  `Sources/ChatBotsCLI/` — `main.swift` plus one file per mode. `Sources/ChatBotsProbe/` — the
  transport probe.
- `Tests/ChatBotsCoreTests/` and `Tests/ChatBotsAppTests/` — **swift-testing**, one file per subject
  with its fixtures beside it; `tools/mac-checks.sh` measures every test bundle rather than naming
  one.
- `web/` (`index.html`; the stylesheets `style.css`, `style-panes.css`, `style-panels.css`;
  the module entry `app.js` with `app-core.js`, `app-screen.js`, `app-transcript.js`,
  `app-controls.js`, `app-lineup.js`, `app-commands.js`; and `deltas.js`, `votes.js`) and the
  six `names/*.txt` lists are the **sources** for the two generated files.
- `tools/` — the install and start scripts (`lib/` holds the phases they source), `mac-checks.sh`
  (the Mac gate), `check-file-sizes.sh` (the 500-line rule, which CI calls too), `make-release.sh`
  (the packaging and publishing command) with `check-identity.sh` and `set-version.sh`, the embed
  and notice tools, the pinned-tool fetchers, the device-capture helpers and the static-analysis
  waivers in `analysis-waivers.txt`.
- `VERSION` — the one authoritative version. `docs/release-notes-v<version>.md` is the notes for
  the release of that version; the notes for a release that has not happened yet end in
  `SHA256_PENDING` and `ARCHIVE_BYTES_PENDING`, which `tools/make-release.sh` substitutes.
- `docs/` — `toolchain.md` (what to install and which versions the gates expect),
  `webtransport-plan.md`, and the screenshots the README and wiki use.
- `Caddyfile` fronts the engine on `:7788`; `SECURITY.md` states the trust boundary and
  `RELEASE.md` the release standard.

## Build, test, run

```bash
swift build
swift test
bash tools/install.sh            # end-user setup: toolchain, ~3 GB of models, app
bash tools/install.sh --model huihui9b --yes   # also fetch another catalogue checkpoint
                                 # (--models all takes the whole catalogue, ~12 GB)

bash tools/start-app.sh          # app plus API server
bash tools/start-web-desktop.sh  # also start-web-mobile.sh, start.sh

bash tools/make-release.sh       # package a release (dry run; --publish to tag and upload)
```

Every start script takes `--help` and `--local-only` (which binds `127.0.0.1`).
The assembled app also lands at `~/Applications/ChatBots.command`.

Warnings-as-errors is **not** a flag here: `Package.swift` sets
`treatAllWarnings(as: .error)` per target, so no invocation can bypass it.

## Identity

`VERSION` at the repository root is the one authoritative value, a semantic version
(`1.0`); the tag is `v` plus it. Nothing else declares it: `tools/make-app.sh` reads
the file and writes both `CFBundleShortVersionString` and `CFBundleVersion` from it, so
the bundle cannot misreport what it is. `tools/check-identity.sh` fails when the file is
malformed, when the bundle builder has grown a copy of its own, or when the release notes
for that version are missing; it runs in CI and as the ninth gate of
`tools/mac-checks.sh`, and `tools/make-release.sh` checks the built bundle's copy.
`tools/set-version.sh <X.Y[.Z]>` is the one command a bump needs. The shipped checkpoint is
a *decision* rather than a number a release propagates, so it keeps one declaration and a
test that pins it (`Tests/ChatBotsCoreTests/DefaultCheckpointTests.swift`).

## Gates

- Linux CI (`.github/workflows/checks.yml`) on every push/PR:
  `python3 tools/embed-web.py --check` and `python3 tools/embed-names.py --check` —
  the generated files must be in step with their sources — plus
  `third-party-notices.py`, `bash -n` over every tracked shell script, `python3 -m
  py_compile` over the Python, `shellcheck`, `ruff`, `pyright`, `gitleaks` over the
  full history, `semgrep` (through `tools/semgrep-waivers.py`), `osv-scanner`,
  `npm ci` with `eslint` and `prettier` over the JavaScript, and
  `tools/check-file-sizes.sh` — no code file over 500 lines — and
  `tools/check-identity.sh`, which fails when `VERSION` and anything derived from it
  disagree. None of them is advisory: a finding fails the job.
- The two toolchain pinning checks: the three release binaries CI installs are fetched
  by `tools/fetch-analysis-tools.sh` with a pinned SHA-256 each, and a step fails if
  those versions disagree with `tools/toolchain-versions.txt`.
- Two structural assertions: the bundle's `LSMinimumSystemVersion` must equal
  `Package.swift`'s `.macOS(.vN)`, and `install.sh` must not hardcode an OS literal.
- The mac-only gate is `tools/mac-checks.sh`, nine gates in one command: the file-size
  check, `swift build --build-tests`, `swift test --enable-code-coverage`,
  `llvm-cov report`, `swiftlint lint`, `swift-format lint` over `Sources`/`Tests`
  excluding the two generated files, the two Node web-rule checks, `eslint` and
  `prettier` over the JavaScript, and the identity
  check. swiftlint and
  swift-format are judged against **recorded waivers** in
  `tools/analysis-waivers.txt`, not against zero — that file also carries the semgrep
  findings this project accepts, and is the only place either gate reads them from.
  The JavaScript toolchain comes from `npm ci` against the committed
  `package-lock.json`, and a missing install fails the gate rather than skipping it.
  The size limit is one number in one script (`tools/check-file-sizes.sh`), called by
  both CI and `mac-checks.sh`, so the two cannot disagree about which file is too long.
- No git hooks and no pre-commit config.

## Traps

- **There is deliberately no Swift job in CI.** No hosted image is macOS 26/arm64
  with MLX, so a Swift job "would be a red build that says nothing about the code".
  `tools/mac-checks.sh` on a Mac is the real Swift gate — do not add CI that
  pretends otherwise.
- **Never hand-edit `Sources/ChatBotsCore/WebAssets.swift` or `NameLists.swift`.**
  Edit `web/` or `names/` and run the embed tools; swiftlint and swift-format exclude
  both by name, and `--check` fails CI when they are stale.
- **The suite is swift-testing, not XCTest.** A successful run still prints
  `Test Suite 'All tests' … Executed 0 tests`. The real result is the
  `Test run with N tests in M suites` line, which is what `mac-checks.sh`
  greps — `1048 tests in 195 suites` when this was written, and the line, not the
  number, is the thing to read. Do not read the XCTest zero as "no tests ran".
- **The website listens on every interface and `/api/*` has no password**, so anyone
  on the LAN can read and steer conversations. The engine itself is loopback-only on
  7789 and is never exposed directly; `--local-only` inserts `bind 127.0.0.1`.
  Without Caddy the engine serves the site itself on 7789, already loopback-only.
- **WebTransport is pinned `exact: "1.3.7"` on purpose**: 1.3.6 treated the
  connection ceiling as a listener-lifetime budget and stopped accepting after ~16
  connects. A version range would move that behaviour silently.
- `swift build` accepts a single `--product` and silently builds only the last one,
  so `tools/make-app.sh` loops one product per invocation.
- Apple silicon and macOS 26 are hard floors — MLX runs on the GPU and WebTransport
  requires 26. `tools/install.sh` fails if `uname -m` is not `arm64`.
- `tools/install.sh` downloads ~3 GB of models into the git-ignored `models/`; no
  weights are committed.
- `docs/webtransport-plan.md` says "Status: implemented"; its 372-test figure is
  historical, not current.

## Releasing

**Read [`RELEASE.md`](RELEASE.md) before cutting a release.** It is this repository's
own release standard — edited here, not deployed from anywhere — and it carries both
the general rules and this repository's own section. Do not improvise a release.

The non-negotiables:

- **Apple Silicon only** — build native `arm64` (M1–M6). Never `--arch x86_64`,
  never `ARCHS=arm64 x86_64`, and never `lipo -create`, which is how a universal
  binary gets made.
- **Assert it** — `lipo -archs <binary>` must report exactly `arm64`. A build that
  silently produced a fat binary is a release defect, not a build option.
- **Every release carries the artifacts.** A tag alone is not a release.
- **Identity is single-sourced and enforced** — never bump one declaration of the
  version or build number on its own; the build or CI must fail on a mismatch.
- **Dry run first**; publish only on an explicit flag.
- **Never fetch a model, dataset or dependency to make a gate pass.** A check that
  cannot run is reported *not checked*, and the release notes must name it.
