# Inventory, dependency graph and tier table

Committed before any fix. §2 of the brief.

## 2.1 Projects, languages, build systems, entry points, primary host

There is **one project**: the SwiftPM package `ChatBots` (tools-version 6.4, `Package.swift`),
plus its browser front end and its tooling. Products:

| Project / product | Kind | Language(s) | Build system | Entry point |
| --- | --- | --- | --- | --- |
| `ChatBotsCore` | library | Swift 6.4 | SwiftPM | `Sources/ChatBotsCore/` |
| `ChatBots` | macOS app (executable) | Swift 6.4 | SwiftPM + `tools/make-app.sh` bundle | `Sources/ChatBotsApp/ChatBotsApp.swift` (`@main`) |
| `chatbots-cli` | executable | Swift 6.4 | SwiftPM | `Sources/ChatBotsCLI/main.swift` |
| `chatbots-probe` | executable | Swift 6.4 | SwiftPM | `Sources/ChatBotsProbe/main.swift` |
| `web/` | browser front end (static + JS) | JS/HTML/CSS | none (served by Caddy / engine) | `web/index.html` |
| `tools/` | install / release / analysis tooling | Python 3.14, Bash 5.3, Node 26 | none (scripts) | `tools/install.sh`, `tools/make-release.sh`, `tools/mac-checks.sh` |
| `Caddyfile` | reverse proxy | Caddy | Caddy | site on `:7788` → engine `:7789` |

**No C, Objective-C, C++ or Cython source exists.** The C99 standard, `-pedantic-errors`,
ASan/UBSan and the "every native-memory module is Tier A" rule have no targets here.

Primary host: `Node1.local` (macOS 27.0, arm64, Xcode 27.0, Swift 6.4). See
`AUDIT/environment.md`.

## 2.2 Dependency graph (direct deps + cross-project contracts, 2-hop cap)

Direct SwiftPM dependencies (from `Package.swift` / `Package.resolved`):

- `mlx-swift-lm` (`MLXLLM`, `MLXVLM`, `MLXLMCommon`, `MLXHuggingFace`) — `from: 3.31.4`
- `swift-huggingface` (`HuggingFace`) — `from: 0.9.0`
- `swift-transformers` (`Tokenizers`) — `from: 1.3.0`
- `WebTransport` — `exact: 1.3.7`

Cross-project / cross-product contracts (all Tier A on the ">1 consumer" rule):

| Contract | Producer | Consumers |
| --- | --- | --- |
| HTTP API (`/api/*`, `/s/<id>`) schemas in `HTTP/APIModels.swift` + routes | `ChatBotsCore/HTTP` | `web/` (JS), SwiftUI app (`ChatControllerConnection`), `chatbots-cli`, `chatbots-probe`, Caddy proxy |
| WebTransport frame protocol (`EngineProtocol`, `TurnEvents`) | `ChatBotsCore/Engine` + `Transport` | SwiftUI app, `chatbots-probe`, tests |
| Generated web assets (`WebAssets.swift`, `NameLists.swift`) | `tools/embed-web.py`, `tools/embed-names.py` from `web/` + `names/` | `ChatBotsCore/HTTP` (serves them), tests |
| `VERSION` mirror contract | `VERSION` | `tools/make-app.sh`, `tools/check-identity.sh`, release notes |
| Env/config contract | `TAVILY_API_KEY`, `DEEPSEEK_API_KEY`, `CHATBOTS_TRACE_API`, `.secrets.env`, `.run/` | engine, CLI, app, `tools/start*.sh` |
| Model catalogue / on-disk layout | `Models/ModelCatalog.swift` | `ModelStore`, `tools/install.sh`, `tools/lib/install-models.sh` |
| macOS floor (`Package.swift .macOS(.v26)`) | `Package.swift` | `tools/make-app.sh`, `tools/lib/install-checks.sh`, CI |

Anything coupling at 2 hops is Tier A and is not recursed further.

## 2.3 Trust boundaries

1. **LAN browser → Caddy → engine HTTP.** `Caddyfile` binds every interface by design; `/api/*`
   and `/s/<id>` have no password. Untrusted requests, untrusted bodies, untrusted paths.
2. **Desktop app → WebTransport (loopback).** `.localDevelopmentSelfSigned`; the engine
   fingerprint is reported and logged but not enforced (`SECURITY.md`).
3. **LLM output → tool dispatch.** A model can request web search / fetch; its arguments are
   untrusted input to a privileged action.
4. **Fetched web content → prompt.** Untrusted text re-enters the model context (prompt injection).
5. **Attachments → decode/extract.** PDF/images/docx from the network.
6. **Cloud OpenAI-compatible endpoint → engine.** Untrusted response bodies; credential handling.
7. **Swift ↔ POSIX/libc.** Files, sockets, file modes, `socket()`/`bind()`, `SecIdentity`.
8. **Swift ↔ WebTransport C API** and **Swift ↔ MLX (C++ via module map).** Native-interop seams.

## 2.4 Tier table

Tier A — deep manual (authn/authz, credentials, untrusted parsing, network-facing, persistent
data, irreversible ops, >1-consumer contracts, unsafe/native memory, LLM output driving
privileged actions). Every file listed is read line by line.

| Module / file | Tier | Why |
| --- | --- | --- |
| `Sources/ChatBotsCore/HTTP/*.swift` (14) | A | Network-facing, untrusted request parsing, path/URL handling |
| `Sources/ChatBotsCore/Transport/*.swift` (6) | A | Network boundary, TLS key/cert on disk, POSIX native seam |
| `Sources/ChatBotsCore/Engine/*.swift` (21) | A | LLM output driving privileged actions, MLX native seam, process spawn |
| `Sources/ChatBotsCore/Research/*.swift` (11) | A | SSRF/network fetch, API key, untrusted web content into the prompt |
| `Sources/ChatBotsCore/OpenAI/*.swift` (6) | A | Credential handling, untrusted backend responses |
| `Sources/ChatBotsCore/Attachments/*.swift` (5) | A | Untrusted file formats, temp files, decode |
| `Sources/ChatBotsCore/Conversation/*.swift` (12) | A | Persistent data (store + transcript), irreversible writes |
| `Sources/ChatBotsCore/Models/*.swift` (2) | A | Downloads to disk, path from a model id, credentials-free but destructive |
| `Sources/ChatBotsCore/Support/UserSettings.swift`, `RunDirectory.swift` | A | Config + secret file, path containment |
| `Sources/ChatBotsCore/Support/ErrorText.swift`, `TextZoom.swift`, `ThreadGrouping.swift` | B | Pure display/logic helpers |
| `Sources/ChatBotsCore/Prompt/*.swift` (4) | A | Prompt-trust boundary: instructs the model, receives untrusted content |
| `Sources/ChatBotsCore/Room/*.swift` (11) | A | `AgentSpec`/`ChatModels` carry keys and seat config; personas feed prompts |
| `Sources/ChatBotsApp/*.swift` (12) | A | Process spawn (`EngineSupervisor`), credentials, network client |
| `Sources/ChatBotsApp/Views/*.swift` (18) | B | UI rendering of untrusted data (tool-first, manual on findings) |
| `Sources/ChatBotsCore/NameLists.swift`, `WebAssets.swift` | C | Generated by `tools/embed-*.py`; never hand-edited |
| `Sources/ChatBotsCLI/*.swift` (12) | A/B | Headless runner + serve command are a production path; mixed |
| `Sources/ChatBotsProbe/main.swift` | B | Diagnostic probe |
| `web/*.js`, `web/index.html` | A | Renders untrusted LLM/API data in the LAN-served page (XSS) |
| `web/*.css` | C | Stylesheets |
| `tools/*.py` (10) | B (A for release/install) | `make-release.sh`/`install.sh` mutate the released artifact |
| `tools/*.sh`, `tools/lib/*.sh` (20) | B (A for release/install) | Same; `Caddyfile` is a network boundary |
| `Caddyfile` | A | Network trust boundary |
| `Tests/**` (150) | C | Scanner-only (formatter/linter/secret scan) |
| `docs/**`, `README.md`, `AGENTS.md`, `promo/**`, `names/**` | C | Docs/data |

Tier B is gated by the automated tools (swiftlint, swift-format, semgrep, osv-scanner,
shellcheck, ruff, pyright, gitleaks); a human only reads tool findings, coverage gaps and
complexity/change hotspots. Tier C gets formatter/linter/secret-scan only.

**Tier coverage is disclosed in the final report** so reduced inspection is visible, never hidden.
Tiering reduces how much surface is human-read; it does not reduce how many findings get fixed.
