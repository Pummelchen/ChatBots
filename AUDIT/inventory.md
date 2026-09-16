# AUDIT — scope inventory (§2)

Produced before any audit pass, as §2 requires, for the 2026-09-13 audit: branch `audit/2026-09-13`
from `main` @ `a6d6999`. The 2026-09-15 re-audit re-derived the scope against Swift 6.4 and Xcode 27
in the section at the end of this file; its branch is `audit/2026-09-15` from `main` @ `02ddd4e`.

> **Scope note, stated before anything else.** The brief describes "a monorepo with 20+
> increasingly interdependent projects". The working tree is **not** a monorepo: it is a
> SwiftPM package (this project) alongside sibling repositories in `Coding/` — `Converter`,
> `MCPSearch`, `WebTransport`, `NVMAI`, `OpenRA`, `Minecraft`, `FXNews`, `XAIOS` and others.
> An audit was already in flight in `Converter` (Phase A, `5fa6546`) and `MCPSearch` (Phase B,
> `82f8f3e`, with a session still committing at 09:45), so they are owned elsewhere and were
> not touched. **This inventory and every task below cover this repository only.** If the
> intent was the whole workspace, the other projects need their own inventory; §0 forbids
> narrowing a task's scope, and equally forbids silently widening it.

## 2.1 Units, languages, build systems, entry points, host class

| Unit | Kind | Language | Built by | Entry point | Host class |
| --- | --- | --- | --- | --- | --- |
| `ChatBotsCore` | library (18 700 LOC) | Swift 6 | SwiftPM | — | Mac (macOS 26) |
| `ChatBots` | executable | Swift 6 / SwiftUI | SwiftPM | `ChatBotsApp.swift` (`@main`) | Mac only |
| `ChatBotsCLI` | executable | Swift 6 | SwiftPM | `Sources/ChatBotsCLI/main.swift` | Mac only |
| `ChatBotsProbe` | executable | Swift 6 | SwiftPM | `Sources/ChatBotsProbe/main.swift` | Mac only |
| `ChatBotsCoreTests` | test target | Swift 6 | SwiftPM | 555 tests, 77 suites | Mac only |
| `web/` | static front end | HTML/CSS/JS | none (served) | `web/index.html` | any browser |
| `web/style.css` | stylesheet | CSS | none | — | any browser |
| `tools/` | tooling | POSIX sh (7) + Python (5) | none | `install.sh`, `start*.sh`, `make-app.sh`, `capture-devices.py`, … | Mac (installer/build) |
| `names/` | data | text | none | embedded into `NameLists.swift` | — |
| `Caddyfile` | config | Caddyfile | Caddy | `:7788` | Mac |
| `ChatBots.wiki` | documentation | Markdown | separate git repo | wiki | — |

Total tracked: 116 Swift, 7 shell, 5 Python, 1 JS, 1 HTML, 1 CSS, plus config and docs
(`git ls-files`). **No C, C++, C# or .NET code exists in this repository**, so §1's
sanitizer/memory-checker and .NET requirements have nothing to apply to here.

## 2.2 Dependency graph

**Internal.** `ChatBotsCore` is the hub: the app, the CLI, the probe and the test target all
depend on it, and nothing depends on the executables.

```
ChatBots ─┐
ChatBotsCLI ─┼──▶ ChatBotsCore ──▶ MLX / WebTransport / HTTP
ChatBotsProbe ─┘
ChatBotsCoreTests ─┘
```

The engine is a **separate process** the app supervises (`chatbots-cli --serve
--transport webtransport`), so there is a process boundary as well as a library boundary, and
the wire protocol (`EngineProtocol.swift`) is the contract across it.

**External (direct, via `Package.resolved`).**

| Package | Pinned | Why it matters |
| --- | --- | --- |
| `WebTransport` (Pummelchen) | 1.3.7, `from: "1.3.7"` | the app↔engine channel; **a sibling project in this workspace** |
| `mlx-swift-lm` (ml-explore) | 3.31.4 | inference |
| `swift-huggingface` | 0.10.1 | hub download |
| `swift-transformers` | 1.3.4 | tokenizer/chat template |
| transitively: `swift-crypto`, `swift-jinja`, `swift-syntax`, `swift-collections`, `swift-numerics`, `swift-asn1`, `eventsource`, `yyjson`, `swift-argument-parser`, `mlx-swift` | see `Package.resolved` | — |

**Implicit coupling inside the repository** — these are contracts with no compiler behind them:

| Contract | Producers | Consumers |
| --- | --- | --- |
| `EngineProtocol` frames (length-framed, tagged) | app client, probe client | engine server, tests |
| HTTP API routes (`/api/*`) | `APIServer.translate` | `web/app.js` |
| Generated `WebAssets.swift` | `web/` via `tools/embed-web.py` | Caddy path **and** engine-served path |
| Generated `NameLists.swift` | `names/` via `tools/embed-names.py` | engine |
| `ConversationStore` format | engine writes, `formatVersion` 3 | app, CLI, share pages |
| `APISnapshot` JSON shape | engine | app, web, CLI |
| Env vars | `TAVILY_API_KEY`, `DEEPSEEK_API_KEY`, `CHATBOTS_SEATS`, `HF_HUB_CACHE`, `MLX_METALLIB`(?) | engine, app, CLI, tools |
| `.secrets.env` | installer/user | `BuiltInKeys`, `TavilyClient` |
| Ports | 7788 Caddy, 7789 engine HTTP, 7790 WebTransport, 7795 transport check, 7900+ tests | Caddyfile, scripts, app, probe |
| Paths | `.run/`, `models/`, `~/Library/Application Support/ChatBots`, `~/Library/Preferences`, Keychain | app, engine, CLI, installer |

**Cross-project.** The only real one is `WebTransport`: a sibling repository **and** a pinned
dependency, so a change there is a change to this project's transport. It moved 1.3.6 → 1.3.7
during this work for the connection-ceiling fix, and this repository's `from: "1.3.7"` floor is
what makes that fix mandatory rather than optional.

## 2.3 Trust boundaries

Ordered by how much untrusted input crosses them.

| # | Boundary | Reachability | What crosses it |
| --- | --- | --- | --- |
| T1 | **Caddy `http://:7788`** — all interfaces, no authn | **LAN** | the whole `/api/*` surface: read every conversation, start/stop runs, change topic/seats, upload documents, plus `/s/<id>` share pages |
| T2 | Engine HTTP `127.0.0.1:7789` | loopback | the same API, direct |
| T3 | WebTransport `127.0.0.1:7790` | loopback | the app↔engine protocol; self-signed identity, fingerprint **logged but not enforced** |
| T4 | Document/image ingestion | via T1/T2, and the app | arbitrary files → PDFKit / `textutil` extractors → model context |
| T5 | Outbound Tavily / OpenAI-compatible endpoints | network | queries and conversation text leave; **their responses come back as model input** |
| T6 | Model output | internal | written to the transcript, rendered by the web UI and the share page, exported to files |
| T7 | Saved conversations on disk | local files | read/written by the engine; served by `/api/conversations` and `/s/<id>` |
| T8 | Child process | local | the app locates and spawns `chatbots-cli`; its stdout/stderr go to a log file |

Initial L4 checks already performed, so they are recorded as verified rather than re-opened:

* **HTML escaping is correct.** `web/app.js:248` escapes `&`, `<`, `>` *before* inserting its own
  `<p>`/`<code>` tags, and `SharedConversationPage.swift` builds every node with `textContent`
  and documents that there is no `innerHTML` in that file on purpose. XSS from model output is
  handled on both surfaces.
* **No secrets are compiled in.** `TavilyKeyTests` fails if a key returns to `TavilyClient.swift`;
  keys resolve from the environment or the gitignored `.secrets.env` with no default.

## 2.4 Blast radius

| Unit | Consumers | Consequence of a defect |
| --- | --- | --- |
| `ChatBotsCore` | 4 (app, CLI, probe, tests) | **highest** — every front end and the whole suite |
| `EngineProtocol` / wire format | both clients, server, tests | app and CLI lose the engine simultaneously |
| `APISnapshot` shape | app, web, CLI, share page | every surface mis-renders at once |
| `ConversationStore` format | engine, app, CLI | on-disk compatibility; `formatVersion` gates it |
| `WebAssets.swift` ↔ `web/` | Caddy path + engine path | the two served pages diverge (this has already happened once) |
| `TavilyClient` / `BuiltInKeys` | engine, CLI | credential handling (was the site of the leaked-key incident) |
| tools/ scripts | humans, CI | a broken installer ships a broken app (this has already happened once) |

Anything with more than one consumer is audited at higher severity, per §2.4.

---

# Re-audit 2026-09-15 — scope, re-measured

The previous inventory stands; this section records what changed under Swift 6.4 / Xcode 27 and
corrects one premise of the brief.

## §2 — the workspace is not a monorepo, re-verified

The brief describes "a monorepo with 20+ increasingly interdependent projects". Enumerated on
2026-09-15, `/Users/node1/Downloads` holds **three projects and three wiki checkouts**:

| Path | Kind | Notes |
| --- | --- | --- |
| `ChatBots` | **the project this audit covers** | SwiftPM package + `web/` + `tools/` |
| `MCPSearch` | sibling project | separate repository; read-only for this audit |
| `AISessionServer` | sibling project | separate repository; currently on its own `audit/2026-09-15` branch, i.e. another session |
| `chatbots-wiki-ro`, `mcps-wiki-ro`, `aisessionserver-wiki` | wiki checkouts | documentation, not code |

There is no shared build, no shared schema and no cross-project dependency beyond the one already
recorded (`Pummelchen/WebTransport`, which is both a sibling and a pinned dependency). §0 forbids
narrowing a task's scope and equally forbids widening it silently, so **this re-audit covers
`ChatBots` only**, and the 20+ project premise is recorded as not matching the workspace.

## §2.1 — units, re-measured

| Unit | Count | Host class |
| --- | --- | --- |
| Swift sources | 173 files, **46 258 LOC** | Mac (macOS 27, Xcode 27) |
| Swift tests | 102 files, **824 `@Test` in 139 `@Suite`** | Mac |
| Shell (`tools/` 7 + `AUDIT/` 4) | 11 | Mac |
| Python (`tools/`) | 7 | Mac or Linux |
| Web (`web/`) | `index.html`, `app.js`, `style.css` | any browser |
| `names/`, `Caddyfile`, `Package.resolved` | data/config | — |

**No C, C++, Objective-C or C# exists in this repository**, re-verified: `git ls-files` matches none of
`.c .h .cpp .cc .cs .m .mm`. §1's C sanitizer/memory-checker and .NET requirements therefore have no
target here; §1's toolchain requirement that *does* bite is Swift 6.4 with strict concurrency and
warnings-as-errors, which the package sets via `.swiftLanguageMode(.v6)` +
`.treatAllWarnings(as: .error)`.

## §2.3 — trust boundaries, re-checked

Unchanged, with one addition now that share pages are proxied: **T1 (Caddy on the LAN) now carries
`/s/<id>` as well as `/api/*`** — the A99 fix that made share links work in the shipped configuration
also made kept conversations reachable from the network through the documented deployment. That is
consistent with the documented "website is reachable from the LAN" position and with `SECURITY.md`;
it is recorded here because a boundary changed shape.
