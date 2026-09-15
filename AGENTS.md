# ChatBots

<!-- agent-harnesses:begin -->
> **One instruction file.** This is it. Codex, DeepSeek Harness, OpenCode, Qwen Code, Qoder and Zed read `AGENTS.md` directly, and
> Claude Code reads it through the committed `CLAUDE.md`, which contains nothing
> but `@AGENTS.md`. **Edit only this file** — do not add a second set of
> instructions anywhere.
>
> Do **not** add `.rules`, `.cursorrules`, `.windsurfrules`, `.clinerules`, `.github/copilot-instructions.md` or `AGENT.md`. Zed takes the *first match* from that list, **ahead of
> `AGENTS.md`**, so any one of them silently replaces this file for every Zed user.
<!-- agent-harnesses:end -->

Two or more local MLX LLMs argue with each other on a Mac, watched from a SwiftUI
app or a browser. Four products share one package — `ChatBots` (the SwiftUI app),
`chatbots-cli` (a headless engine runner), `chatbots-probe` (a transport probe) and
`ChatBotsCore` (the library). Two front ends share one conversation engine: the
desktop app reaches it over WebTransport/QUIC, the website over HTTP through Caddy.
Models run locally via MLX; OpenAI-compatible backends and Tavily tools are
supported. No releases and no tags — deployment is `tools/install.sh` on a Mac.
Swift 6.4 / SwiftPM, package floor macOS 26, Apple Silicon only.

## Layout

- `Sources/ChatBotsCore/` — the engine-agnostic domain (46 files): the conversation
  engine, research moderator, personas, conversation store, `EngineService.swift`,
  `HTTPServer.swift`, and the two **generated** files `WebAssets.swift` and
  `NameLists.swift`.
- `Sources/ChatBotsApp/` — SwiftUI views. `Sources/ChatBotsCLI/` and
  `Sources/ChatBotsProbe/` — terminal runners.
- `Tests/ChatBotsCoreTests/` — mirrors the core; the suite is **swift-testing**.
- `web/` (`index.html`, `app.js`, `style.css`) and `names/*.txt` (six lists, 275
  names) are the **sources** for the two generated files.
- `tools/` — install/start scripts, `audit-checks.sh`, the embed scripts, notices and
  waiver tooling. `AUDIT/` — ledger, plan, environment, baseline.
- `Caddyfile` fronts the engine on `:7788`.

## Build, test, run

```bash
swift build
swift test
bash tools/install.sh            # end-user setup: toolchain, ~3 GB of models, app

bash tools/start-app.sh          # app plus API server
bash tools/start-web-desktop.sh  # also start-web-mobile.sh, start.sh
```

Every start script takes `--help` and `--local-only` (which binds `127.0.0.1`).
The assembled app also lands at `~/Applications/ChatBots.command`.

Warnings-as-errors is **not** a flag here: `Package.swift` sets
`treatAllWarnings(as: .error)` per target, so no invocation can bypass it.

## Identity

`tools/make-app.sh` declares `APP_VERSION="1.0"` and `APP_BUILD="1"` once and
expands them into the bundle's `Info.plist` (`CFBundleShortVersionString`,
`CFBundleVersion`). There is no root `VERSION` or `BUILD_NUMBER`, no tag and no
release, and nothing enforces the value against a release.

## Gates

- Linux CI (`.github/workflows/checks.yml`) on every push/PR:
  `python3 tools/embed-web.py --check`, `python3 tools/embed-names.py --check`,
  `bash AUDIT/render-ledger.sh --check` — the generated files and ledger tables must
  be in step. Plus `third-party-notices.py`, `bash -n` over the shell scripts,
  `python3 -m py_compile` over the Python, `shellcheck`, `ruff`, `pyright`,
  `gitleaks`, `semgrep` (through `tools/semgrep-waivers.py`), and `osv-scanner`.
- Two structural assertions: the bundle's `LSMinimumSystemVersion` must equal
  `Package.swift`'s `.macOS(.vN)`, and `install.sh` must not hardcode an OS literal.
- The mac-only gate is `tools/audit-checks.sh`: `swift build --build-tests`,
  `swift test --enable-code-coverage`, `llvm-cov report`, `swiftlint lint`, and
  `swift-format lint` over `Sources`/`Tests` excluding the two generated files.
  swiftlint and swift-format are judged against **recorded waivers** in
  `AUDIT/plan.md`, not against zero.
- No git hooks and no pre-commit config.

## Traps

- **There is deliberately no Swift job in CI.** No hosted image is macOS 26/arm64
  with MLX, so a Swift job "would be a red build that says nothing about the code".
  `tools/audit-checks.sh` on a Mac is the real Swift gate — do not add CI that
  pretends otherwise.
- **Never hand-edit `Sources/ChatBotsCore/WebAssets.swift` or `NameLists.swift`.**
  Edit `web/` or `names/` and run the embed tools; swiftlint and swift-format exclude
  both by name, and `--check` fails CI when they are stale.
- **The suite is swift-testing, not XCTest.** A successful run still prints
  `Test Suite 'All tests' … Executed 0 tests`. The real result is the
  `Test run with 824 tests in 139 suites` line, which is what `audit-checks.sh`
  greps. Do not read the XCTest zero as "no tests ran".
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

<!-- release-rules:begin -->
## Releasing

**Read [`RELEASE.md`](RELEASE.md) before cutting a release.** It carries the
generic rules every Pummelchen repository follows, plus this repository's own
section. Do not improvise a release.

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
<!-- release-rules:end -->
