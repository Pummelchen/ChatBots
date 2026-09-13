# AUDIT — task ledger

Machine-readable twin: `ledger.json` (same ids; carries every field of §8's schema).
**This file wins on conflict with the wiki.**

Branch `audit/2026-09-13` from `main` @ `a6d6999`, fast-forwarded into `main` when the audit was
complete. Baseline and evidence: [`plan.md`](plan.md),
[`baseline/`](baseline). Fleet and toolchain: [`environment.md`](environment.md).
Scope and trust boundaries: [`inventory.md`](inventory.md).

Statuses: START → PROGRESS → TEST → AUDIT → DONE, plus BLOCKED. Gates are in `plan.md`; a status
does not advance without its artifact.

> **Session entry point.** Re-read this file and `environment.md` first, then resume from the
> highest-severity task that is not DONE or BLOCKED. Do not restart from scratch.

## Status

The tables in this section are **generated from [`ledger.json`](ledger.json)** by
`AUDIT/render-ledger.sh`; `--check` fails when they drift, and Phase E runs it. **`ledger.json` is
the authoritative enumeration** — it is what every gate reads (`phase-e.sh` section 11,
`verify-done-commits.sh`) — and the prose sections below are the record of each fix and the
reasoning behind it. If this file and the JSON disagree, the JSON is right and the renderer has not
been run.

<!-- BEGIN GENERATED: ledger status — rendered from ledger.json by AUDIT/render-ledger.sh -->
| Metric | Count |
| --- | --- |
| Tasks enumerated | 130 |
| DONE | 130 |
| START | 0 |
| PROGRESS | 0 |
| BLOCKED | 0 |

### Open — 0

Nothing is open.

### Every task — 130

| id | sev | status | commit | unit | title |
| --- | --- | --- | --- | --- | --- |
| A01 | S1 | DONE | c91a310 | deploy/APIServer | The website binds every interface and the whole API is unauthenticated |
| A02 | S1 | DONE | 7b28844 | tests | The core inference path and the installer's smoke test are effectively uncovered |
| A03 | S2 | DONE | 8673488 | build | No warnings-as-errors gate, though the baseline is already 0 warnings |
| A04 | S2 | DONE | 31dc2e3 | CI | CI runs no build, test, lint, type-check, scanner or coverage step |
| A05 | S2 | DONE | 3ef1cc6 | concurrency | Five @unchecked Sendable declarations, none with a written justification |
| A06 | S2 | DONE | 4c96beb | style | swiftlint 401 findings and swift-format 29900 diagnostics with no repository config |
| A07 | S2 | DONE | b85fc8b | typing | Python is 3.14 but unannotated and unchecked |
| A08 | S2 | DONE | 6c1ef31 | deps | WebTransport is pinned by range while the project has twice depended on an exact transport behaviour |
| A09 | S3 | DONE | 53183e6 | tooling | SAST: insecure-websocket and dynamic-urllib findings in the dev-only DevTools client |
| A10 | S3 | DONE | f6dc8c2 | tooling | shellcheck -S style reports 4 findings, and the recorded count was wrong twice before it was right |
| A100 | S2 | DONE | 9cb2007 | transport client | The reader uses the REQUEST timeout as its idle receive timeout, so a stream quiet for longer than that fails the connection |
| A101 | S2 | DONE | de2762d | attachments | BMP and TIFF are accepted and sent as media types the Responses API does not document, the mirror of A52 |
| A102 | S2 | DONE | 1c22615 | test infrastructure | One full-suite run aborted with a Network.framework fatal error, reduced but not fixed by A40's single-close |
| A103 | S2 | DONE | 482e036 | prompt trust boundary | Attachment document text is still promoted into the system role, so a crafted document can inject instruction into every seat's prompt |
| A104 | S2 | DONE | f2ca64d | tool dispatch | Tool dispatch runs the injected registry rather than the tool set the caller passed, so disabling a tool does not prevent it running |
| A105 | S3 | DONE | 791d2ee | research quality | A95's directed-engagement path identifies the moderator's assignment by an exact phrase, so rewording the assignment silently disables it |
| A106 | S3 | DONE | 37a7849 | key handling | A user-typed key is still taken verbatim, so a pasted key with a trailing newline suppresses the missing-key warning |
| A107 | S3 | DONE | 597f30d | inference client | A failed or incomplete response does not end the read loop, so the turn waits out the request timeout |
| A108 | S2 | DONE | 836fe7e | test infrastructure | Two pre-existing sources of full-suite flakiness, both reproducing with the newest suites excluded |
| A109 | S2 | DONE | 767aef3 | audit environment / repository integrity | Dropbox renames .git/index to a conflicted copy, which git reads as an empty index and shows the whole tree as deleted |
| A11 | S3 | DONE | 067d953 | docs | Neither the README nor the wiki states that running the website exposes the API to the LAN |
| A110 | S2 | DONE | 81a4f4a | engine API | APISnapshot carries no revision and its only ordering field is whole-second, so a reply racing a push within one second can still regress the interface's state |
| A111 | S3 | DONE | 4590a21 | settings | The stored-attachment doc claims the saved record carries the extracted text, which it does not |
| A112 | S3 | DONE | f200e05 | app attachments | Restored-but-not-loaded files appear as ordinary attachment chips, distinguished only by a notice the user can dismiss |
| A113 | S3 | DONE | 7eeea5a | probe and CLI arguments | The probe's own arguments have the two defects A59 and A62 just fixed in the CLI's |
| A114 | S3 | DONE | 4ee7df0 | CLI arguments | Five more CLI flags silently keep their defaults or are silently ignored when they cannot take effect |
| A115 | S2 | DONE | 48615c6 | engine protocol conformance | Three MLXEngine methods are synchronous while the protocol requirement is async, so a call on the concrete type silently resolves to the protocol's no-op default |
| A116 | S2 | DONE | — | audit environment / build integrity | Dropbox corrupted the build directory: 5 334 conflicted copies inside .build and a module cache compiled at a checkout path that no longer exists |
| A117 | S2 | DONE | 078efd0 | audit tooling / process | The done-commit guard separated its fields with U+0001, which bash consumes as its own CTLESC marker, so it skipped all 109 DONE tasks and exited 0 |
| A118 | S2 | DONE | 33568a4 | audit documentation / source of truth | ledger.md is declared the audit's source of truth and the entry point for the next session, but it enumerates 28 tasks and stops at A89; A90-A116 appear nowhere in it |
| A119 | S3 | DONE | ffea5f5 | web front end / engine API | The page POSTs a layout diagnostic to /api/client-report, a route that has never existed in any commit, and the 404 is swallowed by design |
| A12 | — | DONE | f9a359b | tests | AddressSanitizer over the whole suite: clean |
| A120 | S3 | DONE | 4aa3b46 | app lifecycle / engine API | The engine the app spawns opens an HTTP listener on 7788 that the app does not use, so it cannot start at all while Caddy holds that port |
| A121 | S2 | DONE | 3c7f9a6 | installer | The installer accepts macOS 14 while the package and the bundle require macOS 26, so a Sonoma user downloads ~3 GB and builds before the app refuses to launch |
| A122 | S3 | DONE | 4e5e89d | transport smoke test | TransportCheck declares a timeout it never uses and creates both child pipes without ever draining them |
| A123 | S2 | DONE | 9fa23a7 | audit tooling / process | The build gate counted SwiftPM's dependency-cache notices as compiler warnings, so a clean tree failed the acceptance run |
| A124 | S2 | DONE | 9fa23a7 | audit tooling / dependencies | The dependency gate scanned the sanitizer scratch directories and reported 16 vulnerabilities from third-party example projects, not from this repository's resolved set |
| A125 | S2 | DONE | 9fa23a7 | audit tooling / style gates | The style gates measured generated code and the recorded waivers were below the tree they govern, so Phase E could not have passed on the branch it was written for |
| A126 | S3 | DONE | 9fa23a7 | web front end | A99's layout diagnostic passed a template literal to console.info, which semgrep reports as an unsafe format string |
| A127 | S3 | DONE | 9fa23a7 | audit tooling / reporting | The acceptance statement reported the done-commit gate as passing with an empty count, because it read the blank line above the summary |
| A128 | S3 | DONE | c14db8a | audit tooling / process | The build gate's error count matched SwiftPM's cache notices, so a green section reported four errors |
| A129 | S2 | DONE | cf589e9 | CI / audit tooling | The CI semgrep step ran with `--error` and would have failed on the very findings the audit waived in writing, and it had never executed because the workflow does not run on the audit branch |
| A13 | — | DONE | — | tests | ThreadSanitizer over the whole suite: one data race found |
| A130 | S3 | DONE | cf589e9 | CI / audit tooling | The CI dependency step scanned the whole tree with `-r .` — the same defect A124 fixed in phase-e.sh, in the second copy of the same check |
| A14 | S1 | DONE | 0de3123 | HTTPServer | isRunning/lastError are raced between the listener callback and waitUntilReady |
| A15 | S1 | DONE | 8ece1d3 | EngineService/DocumentImport | Attaching a document blocks the engine main actor for the whole conversion, subprocess wait included |
| A16 | S3 | DONE | 9c53771 | ChatBotsCLI | --serve has no signal handling, so the listener is never shut down and nothing is flushed on exit |
| A17 | S1 | DONE | 0de3123 | HTTPServer | streams is appended on the main actor without the lock that every other access takes |
| A18 | S1 | DONE | 0de3123 | tests | The suite is not hermetic: three tests need the developer's private models/ and .secrets.env and fail on a fresh clone |
| A19 | S2 | DONE | 0de3123 | process / git history | A DONE task was committed with its evidence and its ledger entry but without its fix: 948ea29 claims A14 and A17 and contains no source change |
| A20 | S1 | DONE | e9d45ef | web front end | Stored DOM XSS: the live-pane header interpolates the moderator-supplied seat name into innerHTML |
| A21 | S2 | DONE | 8111b1a | installer | The model-download integrity check silently degrades to 'accept any size' when the HEAD request yields nothing |
| A22 | S2 | DONE | 18100dd | start script | stop_all kills a stale PID from a pid file without checking the process is ours |
| A23 | S2 | DONE | 38fbe08 | device capture tool | capture-devices.py prints a viewport mismatch but cannot fail the run |
| A24 | S2 | DONE | b803b3c | installer | A native binary artifact is downloaded with no integrity check and embedded in the signed app |
| A25 | S3 | DONE | ba18733 | installer | install.sh interpolates the project path into `bash -c`, so an apostrophe in the path is command injection |
| A26 | S3 | DONE | ae957c0 | installer | run_with_timeout kills the wrapper but not the process tree it timed out on |
| A27 | S3 | DONE | ca1af81 | devtools client | cdp.py stop() refuses to terminate any Chrome started with a non-default profile |
| A28 | S2 | DONE | fbe94c1 | audit baseline | Three recorded counts are wrong and the rest are not reproducible from the commands that produced them |
| A29 | S0 | DONE | 208540c | engine intake | The attachment filename is used verbatim as a filesystem path: unauthenticated arbitrary file write |
| A30 | S1 | DONE | cbf39c7 | HTTP server | A negative Content-Length passes both guards and is used as a slice offset, trapping the process |
| A31 | S1 | DONE | 679551f | HTTP server | SSE connections are never reaped, so streams and connections grow for the life of the process |
| A32 | S1 | DONE | c63b7b3 | WebTransport | A frame over the protocol cap is swallowed by try?, permanently desyncing the session |
| A33 | S1 | DONE | b88eee1 | turn loop | Restarting a running conversation orphans the new turn loop, so Stop and Pause become no-ops |
| A34 | S1 | DONE | 59555f0 | persistence | ConversationStore.save destroys the records it deliberately refuses to read |
| A35 | S1 | DONE | 3752067 | app state | A turn ending is never observed, so isGenerating sticks on forever: stuck UI, duplicated answer, disabled controls |
| A36 | S1 | DONE | 84fc613 | document import | The conversion timeout can never fire: the pipe reads block forever first, and the drain order can deadlock |
| A37 | S2 | DONE | f1dd7a7 | HTTP server | The HTTP listener has no read or idle deadline and no connection cap |
| A38 | S2 | DONE | 6229d1f | WebTransport client | A failed openBidirectionalStream leaks the session and leaves isConnected true |
| A39 | S2 | DONE | 219e3ce | WebTransport client | Replies are matched by queue order, and removeFirst() assumes in-order completion |
| A40 | S3 | DONE | 9a4dc18 | WebTransport server | stop() leaves live WebTransport sessions serving and never closes them |
| A41 | S2 | DONE | d870f3d | memory | An orphaned unbounded event stream retains every event, including a full prompt per turn, for the process lifetime |
| A42 | S2 | DONE | 978550d | compaction | MLXEngine.compact mutates a local spec that generate() never reads, so maxTokens and thinking-off are ignored |
| A43 | S2 | DONE | e5e2872 | inference | The reasoning ceiling truncates the turn instead of forcing an answer, and unlimited thinking gets less headroom than high |
| A44 | S2 | DONE | 60e2f49 | research mode | Reopening a finished research conversation and pressing Start writes a second report with zero turns |
| A45 | S2 | DONE | 2ed98a8 | context accounting | Auto-compaction is measured against a static window instead of the engine's learned one |
| A46 | S2 | DONE | 4242b40 | app attachments | Attachment chips print '0 words' / 'Zero bytes' because the engine's summary and token count are discarded |
| A47 | S2 | DONE | cb94c56 | app attachments | Saved source material is silently discarded at launch and then erased from settings |
| A48 | S2 | DONE | 6371ed5 | app requests | ChatController issues overlapping requests against a client whose protocol is documented as one-request-at-a-time, so replies cross |
| A49 | S2 | DONE | 265b309 | app lifecycle | The wait-then-SIGKILL engine teardown is dead code, so an owned engine can outlive the app |
| A50 | S3 | DONE | 30f930c | app lifecycle | A startup timeout reports .idle, discarding the failure reason the app exists to show |
| A51 | S3 | DONE | b9bcebb | app UI | 'Models > Load ...' is a no-op placeholder presented as a working control |
| A52 | S2 | DONE | 4e49a37 | attachments | An accepted image with unrecognized magic bytes, notably HEIC, is silently never sent |
| A53 | S2 | DONE | 54800d4 | model store | A partial sharded download is reported as a complete checkpoint |
| A54 | S2 | DONE | c7c062c | inference client | A truncated SSE stream is accepted as a finished turn: the terminal event is never required |
| A55 | S3 | DONE | 34a7f1f | key handling | A CRLF .secrets.env yields a key that cannot authenticate, and the app does not report it missing |
| A56 | S3 | DONE | 251c8de | web search | The 'empty results' retry is decided before the blank-result filter runs |
| A57 | S3 | DONE | 2ed35d2 | inference client | The engine re-probes /v1/models every turn and misreports an unparseable body as 'no model loaded' |
| A58 | S3 | DONE | 00b7186 | document import | A PDF reports truncation one character early and the joined text exceeds the declared ceiling |
| A59 | S2 | DONE | 8d1d646 | probe | chatbots-probe reports 'all cycles succeeded' and exits 0 when --cycles 0 probes nothing, and aborts on a negative count |
| A60 | S2 | DONE | c8dccf8 | CLI smoke tests | --benchmark and --session-probe exit 0 when a seat fails to load, reporting success for a checkpoint that never loaded |
| A61 | S2 | DONE | 66349a9 | CLI | A legal single-seat roster crashes the flag paths that hard-index seat 2 |
| A62 | S2 | DONE | 53a9bba | CLI | An out-of-range --port traps the process, --port 0 announces an unusable URL, and an invalid --transport-port is silently swallowed |
| A63 | S3 | DONE | ef47f52 | stream pacing | StreamPacerPool.generationRates is written but never read, so the learned rate never seeds a new pacer |
| A64 | S3 | DONE | e328e82 | stream pacing | StreamPacerPool.minimumRate is dead API and its comment contradicts the pacer's actual floor |
| A65 | S3 | DONE | 07a3cb8 | CLI diagnostics | --memory-probe prints memoryLimit under both 'gpuLimit' and 'memLimit' |
| A66 | S3 | DONE | 6790b53 | CLI | Flags are accepted in modes where they do nothing, without warning |
| A67 | S1 | DONE | efddc6d | research quality | `.answered` is decided by keyword substring presence and then reported as a complete, undisputed investigation |
| A68 | S2 | DONE | f099d87 | prompt injection | The report synthesis prompt concatenates the untrusted transcript with its own rules, with no boundary |
| A69 | S2 | DONE | 83bf5f6 | trust boundary | Peer-model and API-supplied text is promoted into another seat's system message unescaped |
| A70 | S2 | DONE | 2ab2157 | prompt correctness | Research sessions get an entertainment persona in the shared opening brief |
| A71 | S2 | DONE | 88cbede | research quality | Position changes are counted as 'added nothing', so research sessions converge early |
| A72 | S2 | DONE | 4181af7 | report integrity | A mostly-unlabelled report is still declared labelled and traceable |
| A73 | S2 | DONE | c7e3079 | cost ceiling | The web-search ceiling is not reliably enforced and can also fire early |
| A74 | S3 | DONE | 489ef41 | determinism | The director picks a conflict by Dictionary iteration order, contradicting its own determinism contract |
| A75 | S1 | DONE | 127d3d3 | web surface / browser boundary | CORS is `Access-Control-Allow-Origin: *` and every preflight is answered, so any website the user visits can read every kept conversation and drive the engine |
| A76 | S3 | DONE | caed9f5 | web surface / browser boundary | No CSP, no X-Frame-Options or frame-ancestors, no X-Content-Type-Options, no Referrer-Policy |
| A77 | S2 | DONE | 77f2d67 | distribution / licensing | The shipped app redistributes ~14 third-party libraries with no licence notices or attribution |
| A78 | S3 | DONE | d33c6e4 | distribution / bundle metadata | `NSHumanReadableCopyright` carries a description instead of a copyright, and the bundle identifier and version are single-sourced in one script only |
| A79 | S3 | DONE | 5928f64 | repository hygiene | Python bytecode is not ignored, so running any helper script or the CI byte-compile step leaves untracked noise |
| A80 | S2 | DONE | 6113702 | device capture tool | A capture that renders no messages still only prints, so an empty capture is published on a green run |
| A81 | S3 | DONE | 5010700 | device capture tool | A reachable-but-not-ready health response spins the retry loop with no delay |
| A82 | S3 | DONE | 191563b | devtools client | Every landscape capture records `screen.orientation` as portrait |
| A83 | S3 | DONE | 2dcf802 | test infrastructure | The test port allocator is an in-process counter with no probe, so two runs of the suite on one machine collide from 7 900 upward |
| A84 | S2 | DONE | — | audit process / git | A commit made without a pathspec absorbed another lane's staged files, producing a mixed commit under a message that did not mention them |
| A85 | S3 | DONE | 38a9745 | device capture tool | The run summary counts only hard capture failures, so a failing run can print '3 captured, 0 failed.' |
| A86 | S3 | DONE | a56d16c | device capture tool | A failed health probe leaks its HTTPConnection until garbage collection |
| A87 | S2 | DONE | — | audit process / parallelism | Parallel Swift fix lanes cannot be isolated by scratch path or port: they compile the same module, so one lane's half-finished edit fails every other lane's build |
| A88 | S3 | DONE | dc34211 | device capture tool | The same connection-leak shape A86 fixed exists twice more, and one of them is called in a 90-iteration loop |
| A89 | S2 | DONE | a2ce3b5 | audit tooling | The ledger is written non-atomically, and the acceptance run's most important gate passed on a ledger it could not parse |
| A90 | S2 | DONE | ac80867 | context accounting | Public API still computes the incoherent unlimited-thinking cap, and a test pins that value |
| A91 | S3 | DONE | 8d82c41 | inference | A round abandoned at the reasoning ceiling can still fall through to tool dispatch |
| A92 | S2 | DONE | 8d48560 | turn loop | Every engine event is published twice, duplicating live text, tool-log entries and every subscriber's stream |
| A93 | S2 | DONE | 6ca2dbf | device capture tool | The documented capture command fails on a fresh checkout because `.run/` does not exist yet |
| A94 | S3 | DONE | c04a044 | device capture tool | The capture output directory is created only by main(), so any other caller of capture() or build_index() hits the same fresh-directory failure A93 fixed |
| A95 | S2 | DONE | 9468385 | research quality | Coverage is still keyword-presence based, so one SOURCED sentence naming all ten subjects still closes a session as fully answered |
| A96 | S3 | DONE | 146969a | research quality | `affinity` still scores with bare substring matching, deciding which seat is asked about what |
| A97 | S2 | DONE | d66386d | research quality | `hasBasis` matches bare substrings, and A67 made its looseness load-bearing |
| A98 | S2 | DONE | f14fac2 | web surface / browser boundary | In the documented configuration Caddy serves the page, so the CSP, nosniff, frame denial and referrer policy A76 added never reach it |
| A99 | S2 | DONE | e7243d4 | web surface / routing | Kept-conversation share links 404 in the documented deployment, because Caddy proxies only /api/* and the engine serves /s/<id> |

<!-- END GENERATED -->

---

## A01 — the website binds every interface and the whole API is unauthenticated

**S1** · unsafe · START · discovered by L4 pass

**Proven statically, not guessed.** `Caddyfile:27` is `http://:7788` — a Caddy site address with
no host, so Caddy listens on **every** interface. Everything under `/api/*` is reverse-proxied to
the engine (`Caddyfile:34`), and there is no authentication anywhere on that path: any peer that
can reach port 7788 can read every kept conversation, start, stop and steer runs, change the topic
and the seats, upload documents, and fetch any `/s/<id>` share page. `tools/start-web-desktop.sh`
and `start-web-mobile.sh` both start it that way, and the wiki actively recommends reaching it from
a phone over the LAN.

**Why it is S1 rather than S0.** Phone access is a deliberate feature, and the engine behind it is
loopback-only, so this is a *documented-ish* exposure rather than an accident. It is still a
missing-authorisation boundary on a network-reachable service holding private conversations, and
on a shared or untrusted Wi-Fi it is a straightforward disclosure. The owner may raise it to S0;
the task records the evidence either way.

**Expected-correct behaviour.** Either (a) the exposure is a stated, deliberate trust boundary —
documented in the README and the wiki, with the consequences spelled out and a one-command way to
bind loopback only — or (b) the API requires a credential when it is not on loopback. Doing
nothing is not an option, because right now the docs say "nothing is exposed to the network beyond
what you ask for" while the default start script exposes everything to the LAN.

**Fix direction (Phase C).** Cheapest correct first step is (a): make the trust boundary explicit
in the docs and add a documented `--local-only` binding. (b) is a larger design change and needs
its own task if chosen.

---

## A02 — the core inference path and the installer's smoke test are effectively uncovered

**S1** · test · START · discovered by L6 pass (coverage)

Measured with `llvm-cov` over `Sources/` (`baseline/coverage-sources.txt`): repository line coverage
is **71.6 %**, but the distribution is the finding:

| File | Line coverage |
| --- | --- |
| `MLXEngine.swift` | **2.2 %** (19/863) |
| `TransportCheck.swift` | **0 %** (0/216) |
| `OpenAIResponsesEngine.swift` | 11.0 % |
| `WebTools.swift` | 11.4 % |
| `TavilyClient.swift` | 16.5 % |
| `OpenAIResponsesClient.swift` | 53.2 % |
| `APIServer.swift` | 60.2 % |

`MLXEngine` is where the turn loop, prompt assembly, tool rounds, thinking ceilings and compaction
actually happen — and it is where the S1 "a started conversation produces no turns" defect lived.
`TransportCheck` is the check the installer runs to prove the channel works, and no test exercises
it.

**Expected-correct behaviour.** The logic inside these files that does not need a GPU — prompt
assembly, tool-round framing, thinking-budget accounting, refusal paths, the transport check's
reporting — should be covered by tests with a stubbed engine. Real-weight inference cannot be unit
tested on an 8 GB Mac and is not the ask; *logic* coverage is.

---

## A03 — no warnings-as-errors gate

**S2** · test · START

Baseline is **0 compiler warnings** in both configurations (`baseline/swift-build-*.log`), and
`Package.swift` sets Swift 6 language mode but no `-warnings-as-errors`. Nothing currently stops a
warning entering the tree, and §1 requires warnings-as-errors for Swift.

**Expected-correct behaviour.** `swiftSettings` in `Package.swift` enables
`.treatAllWarnings(as: .error)`; the build stays green because the baseline is clean. CI cannot
enforce it (A04), so the local build is the gate.

---

## A04 — CI runs no build, test, lint or scan step

**S2** · test · START

`.github/workflows/checks.yml` runs four steps: `embed-web.py --check`, `embed-names.py --check`,
`bash -n` over `tools/*.sh`, and `py_compile` over `tools/*.py`. There is no Swift build, no test
run, no linter, no formatter check, no type check, no coverage floor and no scanner.

The reason is real and already documented in that file: the package requires macOS 26 and a GPU,
and no hosted runner has either — so a Swift job there would be a red build that means nothing.

**Expected-correct behaviour.** Either a self-hosted runner on the Mac fleet runs the suite and the
swift-side gates, or the repository states in writing that those gates are local-only and gives
the exact commands. Leaving it implicit is what makes the gap easy to forget.

---

## A05 — four `@unchecked Sendable` declarations without written justification

**S2** · unsafe · START

`DocumentIngestor` (`Attachments.swift:269`), `HTTPServer` (`HTTPServer.swift:233`), `EventStream`
(`HTTPServer.swift:251`) and `ProgressBox` (`MLXEngine.swift:791`). §0 forbids `@unchecked
Sendable` as a *fix*; these are pre-existing, so the task is to justify or replace each one.
`ProgressBox` carries an `NSLock` and looks defensible; the two HTTP types are the ones to
scrutinise, since they own mutable state across queues.

**Expected-correct behaviour.** Each either gains a written invariant ("all mutable state is
guarded by X") or is replaced by an actor or a `Mutex`/`OSAllocatedUnfairLock`, which the codebase
already uses elsewhere.

---

## A06 / A07 / A08 / A09 / A10 / A11 (summarised)

* **A06 style** — `swiftlint` 401 findings (`line_length` 124, `trailing_comma` 93,
  `identifier_name` 33, `opening_brace` 26, `file_length` 21, `function_body_length` 21) and
  `swift-format lint` 29 900 diagnostics, both with no config. Expected: a committed config that
  encodes the project's actual style, so genuine findings are visible.
* **A07 typing** — `tools/*.py` on Python 3.14 with no annotations and no strict config; ruff 11
  errors, 5 files unformatted, pyright 2 errors (`capture-devices.py:303` operator on `object`,
  `cdp.py:288` return type). Expected: full annotations and a strict `pyright` config, per §1.
* **A08 deps — DONE**, see the section below.
* **A09 SAST** — `tools/cdp.py` insecure websocket (×2) and dynamic urllib. Dev-only, loopback
  DevTools client, so genuinely low; expected: an inline justification comment or a guard, so the
  scanner result is intentional rather than ignored.
* **A10 shellcheck** — 24 style notes, mostly SC2001 (`echo | sed` → parameter expansion).
  Expected: fixed or silenced with a reason.
* **A11 docs** — the README and wiki imply the engine is loopback-only and never exposed, while
  the website start scripts expose the full API to the LAN. Expected: the same documentation
  decision as A01(a).

---

## A12 — AddressSanitizer over the whole suite — **DONE (clean)**

**DONE** · test · discovered by §1's tooling requirement

```bash
swift test --sanitize=address --scratch-path ~/Library/Caches/ChatBots/audit-asan
# exit 0 — Test run with 555 tests in 77 suites passed
```

Evidence: [`baseline/swift-test-asan.log`](baseline/swift-test-asan.log). No `AddressSanitizer`
line appears anywhere in the log, no `error:`, and the exit status is 0.

**Why this was worth the ~20-minute instrumented rebuild:** in the sibling `MCPSearch` audit the
same command is what surfaced its only S0 — a deeply nested HTML document killing the process,
which the plain suite passed. A clean non-sanitized suite proves nothing about that class. Here it
is clean, which is a real result about this codebase rather than an assumption.

The scratch path is outside the Dropbox folder deliberately: instrumented builds are large, and
`.build` inside a synced folder was already the cause of one outage during this project's history.

---

## A13 — ThreadSanitizer over the whole suite — **DONE (one data race found)**

**DONE** · test · discovered by §1's tooling requirement

```bash
swift test --sanitize=thread --scratch-path ~/Library/Caches/ChatBots/audit-tsan
# TSAN_EXIT=1 · 555 tests passed · ThreadSanitizer: reported 1 warnings
```

Evidence: [`baseline/swift-test-tsan.log`](baseline/swift-test-tsan.log). **The suite still passed**
— which is the whole point of running it: TSan reported a race the tests could not see. It is
opened as its own task, **A14**, rather than folded into this one.

The expectation going in was clean, because the engine is actor-isolated throughout and the
transport is serialised. It was wrong, and that is worth recording: "expected clean" is not a
result.

---

## A14 — `isRunning` / `lastError` are raced between the listener callback and `waitUntilReady`

**S1** · unsafe · START · discovered by A13 (ThreadSanitizer)

**The report** (`baseline/swift-test-tsan.log:2541`):

```
WARNING: ThreadSanitizer: data race (pid=22050)
  Write of size 1 at 0x00010a20ca60 by thread T1:
    #0 closure #2 in HTTPServer.start()  HTTPServer.swift:356
  Previous read of size 1 at 0x00010a20ca60 by thread T3:
    #0 HTTPServer.waitUntilReady(timeout:)  HTTPServer.swift:380
```

**What it is.** `HTTPServer` holds `public private(set) var isRunning` (`:319`) and
`lastError` (`:322`) as plain stored properties. The listener's `stateUpdateHandler` writes them
from a Network.framework callback dispatched on `queue` (`:356`, `:358`, `:363`), while
`waitUntilReady` reads them from a Swift concurrency task (`:380`, `:381`). Nothing synchronises
the two.

**It is a production path, not a test artefact.** The trace surfaces it through
`SharedConversationTests` → `APIServer.start()`, but the same code runs whenever the engine starts:
`chatbots-cli --serve` calls `APIServer.waitUntilReady()` (`main.swift:649`) and refuses to start if
it returns false. This is the check that is supposed to turn "the port is held by somebody else"
into a reported failure.

**Impact.** On arm64 an aligned 1-byte load/store does not tear in practice, which is why the suite
passes. The real risk is the compiler: a read of a racy non-atomic may legally be hoisted out of
the poll loop in `waitUntilReady`, and then the loop spins to its deadline and reports a healthy
server as not ready. That is a wrong result on the startup path — the engine refuses to start, or
the installer's checks fail, with no obvious cause. It is also the second half of **A05**: this
type is one of the four `@unchecked Sendable` declarations, and this is exactly the mutable state
that conformance assumes does not need protecting.

**Graded S1, with the S0 case stated.** §7 maps "unsafe concurrency" to S1. If the owner considers
a startup path that can report the wrong answer to be a go-live blocker, this is S0; the evidence
supports either reading, so the grade is recorded with its reasoning rather than asserted.

**Expected-correct behaviour.** The two flags must be read and written under one lock, so that
`waitUntilReady` observes the listener's actual state. The public API (`isRunning`, `lastError`,
`waitUntilReady`) does not need to change.

**Fix direction (Phase C).** Guard both fields with a lock — the codebase already uses
`OSAllocatedUnfairLock` — and read them through accessors. That also lets `HTTPServer`'s
`@unchecked Sendable` carry a written invariant instead of being an assertion, and the fix should
be verified by re-running the TSan command above and getting exit 0 with no report. A test that
fails before and passes after is required by §8's TEST gate; the race itself needs the sanitizer,
so the test will assert the observable contract (the flags are coherent under concurrent access)
and the sanitizer run is the evidence that the race is gone.

---

## A15 — attaching a document blocks the engine's main actor

**S1** · perf · START · discovered by L5 pass

`DocumentIngestorProvider.ingestor.add(url:)` is synchronous, and the subprocess path ends in a
poll loop:

```swift
let outputData = out.fileHandleForReading.readDataToEndOfFile()   // blocks until EOF
let errorData  = err.fileHandleForReading.readDataToEndOfFile()
let deadline = Date.now.addingTimeInterval(timeout)
while process.isRunning, Date.now < deadline { usleep(20_000) }   // DocumentImport.swift:163-166
```

`EngineService` is `@MainActor`, and its `addAttachment` calls straight into that on the actor
(`EngineService.swift:325-357`). So while a document is being converted — a PDF extraction, or a
`textutil` subprocess that may run to its timeout — **every other request to the engine waits**:
the app's one-second state poll, the website, the transport push loop. The user sees a frozen
interface, and on a large PDF it is frozen for as long as the conversion takes.

**Expected-correct behaviour.** Conversion happens off the actor, and the engine stays responsive
while it runs. `DocumentIngestor` is already `Sendable`-conformant, and `addAttachment` is already
`async`, so the work can move to a detached task or a dedicated executor without changing the
public API — but the `@unchecked Sendable` justification for `DocumentIngestor` (A05) has to be
settled first, because this is exactly the state that crosses the boundary.

**Why S1 and not S2.** §7 puts "blocking calls on async paths" under performance (S2), but the
blocked actor is the one every front end and the transport share, so the failure is "the app stops
responding while a document converts", not "a conversion is slow".

---

## A16 — `serving` has no shutdown path

**S3** · incomplete · START · discovered by L7 pass

`chatbots-cli --serve` ends in `while true { try? await Task.sleep(for: .seconds(3600)) }`
(`main.swift:689`) with no `SIGINT`/`SIGTERM` handler. Ctrl-C kills the process, so
`WebTransportEngineServer.stop()`, the HTTP server's teardown and the child-process reaping never
run. Conversations are safe — `ConversationStore` writes on every turn — so this is not data loss;
it is a listener that is never told to release its port, and log output that is never flushed.

**Expected-correct behaviour.** A signal handler that stops the servers and exits, which is also
what makes `tools/start.sh --stop` and the installer's lifecycle predictable.

---

## Reviewed and clean (recorded so they are not re-opened)

* **72 `try?` sites** across 23 files. Sampled on the production paths — persistence, network,
  filesystem — and the ones that matter have explicit fallbacks
  (`ConversationStore` decode guards, `APIEndpointStore` defaults, `CertificateStore`). No silent
  swallow found on a path where the error would change behaviour. Two discard a result a user might
  care about (`ChatController.swift:255` moderator restore, `main.swift:498` engine load) but both
  fall back to a working default rather than continuing in a broken state. **Not a task.**
* **Force unwraps in `Sources/`: two.** `HTTPServer.swift:346` (`.init(rawValue: port)!`, `UInt16`,
  infallible in practice) and `StreamPacer.swift:163` (`pacers[key]!` immediately after a
  `guard pacers[key] != nil`). Safe but fragile; both are S3 style at most and neither is worth a
  fix commit on its own. **Not a task.**
* **No `Thread.sleep`, `DispatchSemaphore` or `DispatchQueue.sync` anywhere in `Sources/`.** The one
  blocking wait is A15's `usleep` poll.
* **L7 has a health endpoint** (`APIServer.swift:416`, `GET /api/health`) and the app flushes on
  `applicationWillTerminate`.

---

## A14 and A17 — the two `HTTPServer` races — **DONE**

**DONE** · unsafe · discovered by A13 and by review beside it

Both are the same defect in the same type: mutable state shared between the network queue and
everything else, protected in some places and not others.

| | Before | After |
| --- | --- | --- |
| A14 `isRunning` / `lastError` | plain stored properties, written by the listener's state handler on the network queue and read by `waitUntilReady` anywhere | private flags under `stateLock`, with `markRunning()` / `markStopped()` writers and lock-guarded accessors |
| A17 `streams` | appended on `@MainActor` under a comment claiming the array "is only ever touched on the main actor" while `stop()`, `closeStreams()` and `finish()` mutated it under `stateLock` | `addStream(_:)` takes the lock and is the only append |

**Failing → passing evidence is the sanitizer pair, and that is stated rather than worked around:**
a data race is not observable from a plain assertion, so the TEST gate is satisfied by

```
before: swift test --sanitize=thread …   →  TSAN_EXIT=1, race reported, 555 tests still passed
after:  swift test --sanitize=thread …   →  TSAN_AFTER_EXIT=0, 555 tests passed, no report
```

`baseline/swift-test-tsan.log` and `baseline/swift-test-tsan-after.log`. The plain suite passes
both before and after, which is exactly why it could not have caught either.

The two share one commit on purpose: same type, same `@unchecked Sendable` conformance, same
invariant. Splitting them would have committed a knowingly half-fixed conformance. The class doc
now states the invariant as it actually is — `connections`, `streams`, `running` and `failure`
under `stateLock`, `listener` touched only by `start()`/`stop()` — rather than claiming every
property is guarded.

**Correction, from A19.** The commit that first recorded this work (`948ea29`) carried the ledger
entry, the plan update and the sanitizer log — and no source change. The fix above was still
uncommitted in the working tree. The evidence was real, because the ThreadSanitizer re-run was
done against a tree with the fix applied; only the code was missing. It is committed for real in
the repair commit that A19 records, and `verify-done-commits.sh` now checks this mechanically
instead of trusting that it was done.

---

## A18 — the suite is not hermetic — **DONE**

**S1** · test · discovered by the early independent check on **node1**

A fresh clone of this branch on node1 builds cleanly (exit 0) and then **fails four assertions in
three tests**, because they read state that only exists on a machine where the project has been
installed:

| Test | Needs | On a fresh clone |
| --- | --- | --- |
| `BuiltInKeyTests.deepSeekGetsTheKey` (`:20`) | `.secrets.env` or `DEEPSEEK_API_KEY` | `BuiltInKeys.deepSeek` is nil → `try #require` **throws**, so it fails |
| `ImageUploadTests.localCheckpointSees` (`:136`) | `models/Qwen3.5-4B-MLX-4bit/config.json` | `declaresVision` is nil → fails |
| `AttachmentTests.localCheckpoint` (`:308`) | the same checkpoint | fails |

`BuiltInKeyTests` even carries the comment *"this test skips rather than fails when the file is
absent, as it would be in a fresh clone"* — and then uses `try #require`, which throws. The
comment states the intent the code does not implement, which is why nobody noticed.

**This would have blocked Phase E**, whose whole requirement is a green run from a fresh clone on
a host that did not develop the fix. Finding it on the first independent run rather than at the end
is the argument for doing that run early.

**Expected-correct behaviour.** The suite passes on a machine with no `models/`, no `.secrets.env`
and no network. Machine-local assertions become `.enabled(if:)`-gated, and `declaresVision` is
covered hermetically by pointing it at a synthetic checkpoint in a temporary directory — which
tests the logic rather than the presence of 3 GB of weights.

**Fix, in `0de3123`.** All three assertions are gated on the state they actually need:
`BuiltInKeyTests.deepSeekGetsTheKey` on a DeepSeek key existing, and
`ImageUploadTests.localCheckpointSees` and `AttachmentTests.localCheckpoint` on the default
checkpoint being on disk. The rule they were standing in for moved to two hermetic tests that need
no download: `AttachmentTests` now writes synthetic checkpoints into a temporary models root and
asserts that a config declaring a `vision_config` reads `true`, a text-only config reads a definite
`false`, and an absent model reads `nil` — the unknown/`false` distinction is the part that decides
whether the interface offers images on a guess, so it is asserted directly rather than incidentally.
**Coverage of the rule went up while the dependency on the machine went away.**

**Evidence — both directions, not just the happy one.**

| Run | Result |
| --- | --- |
| `node1`, fresh clone of `518c38e`, no `models/`, no `.secrets.env`, independent host | `BUILD_EXIT=0`, `TEST_EXIT=0`, **557 tests in 77 suites passed**; the three tests report exactly `skipped.` |
| this Mac, `swift test` | 557 tests in 77 suites passed |
| this Mac, `CHATBOTS_MODELS_DIR` aimed at an empty directory | passes, and the two vision tests report `skipped.` |

The third run is the one that shows the gate is keyed on the checkpoint rather than on the host: if
the gate were wrong in the permissive direction the test would have run and failed, and if it were
wrong in the restrictive direction it would have skipped on this Mac too.

**node1 was cleaned up afterwards** — `~/chatbots-audit` (2.5 GB) removed, with no
`~/Library/Caches/ChatBots`, and no chatbot- or audit-named residue left in the home directory.
Recorded in `environment.md`.

---

## A19 — a DONE task was committed without its fix — **DONE**

**S2** · process · found while re-entering Phase C

`948ea29` is titled *"audit(A14,A17): the two HTTPServer races, verified gone by ThreadSanitizer"*
and contains:

```
AUDIT/baseline/swift-test-tsan-after.log
AUDIT/baseline/test-warnings.txt
AUDIT/ledger.json
AUDIT/ledger.json.tmp
AUDIT/ledger.md
AUDIT/plan.md
```

No file under `Sources/`. At `HEAD`, `HTTPServer.swift` still had
`public private(set) var isRunning = false` — the plain stored property the commit message says
is now a private flag behind `stateLock`. **The ledger said DONE; the code was in the working
tree, uncommitted.** A 0-byte `ledger.json.tmp` rode along in the same commit.

This is worth its own task because of what it is *not*: the evidence was genuine. ThreadSanitizer
really had gone quiet, because the re-run was done against a tree with the fix applied. The
ledger was not wrong about the result — it was wrong about *where the result lives*. No amount of
care with evidence catches that, so the remedy is mechanical.

**Fix.**

- The fix is committed for real in the repair commit on this branch (see `ledger.json` for the
  hash, which the ledger sync following it records).
- `AUDIT/*.tmp` is ignored, so an interrupted ledger write cannot be committed again.
- `AUDIT/verify-done-commits.sh` reads every DONE task, extracts the source paths that task's own
  record names, and fails unless that task's commit touches one of them. It is deliberately
  narrow: a DONE task naming no source path — a CI file, a document, a decision — is reported as
  *skipped*, not as *passed*, so a clean run cannot be manufactured by naming nothing.

**The guard had the same defect it was written to catch, and it was found by using it.** Its
first version read its fields with `IFS=$'\t'`. A tab is *IFS whitespace*, so a run of tabs collapses
and leading or trailing ones are dropped — which meant that when a task's `commit` was empty, the
doubled tab vanished, every later field shifted one place left, `file_line` was read as `unit`, and
the task was reported as *"names no source path"* and skipped. **It therefore skipped precisely the
case it exists to catch.** Two tasks had empty commit fields, A04 and A20, and both were being
skipped while it printed a clean run.

Switching the separator to U+0001 — which is not IFS whitespace, so an empty field stays empty —
turned `skip A20 names no source path` into `FAIL A20 status DONE but commit is 'empty'`, and both
hashes are now recorded. That demonstration is kept here because it is the argument for the whole
task: **a control that has never been shown to fire on the failure it targets is a control that may
not be wired up.** The same standard was applied to A06's configs, to A03's gate and to A29's fix,
each of which was made to fail on purpose before being trusted.

**Verification.** `AUDIT/verify-done-commits.sh` exits 0 with every DONE task backed;
`git show --stat` of the repair commit lists `Sources/ChatBotsCore/HTTPServer.swift`;
`swift test` is 557 tests in 77 suites passing; `swift test --sanitize=thread` exits 0 with no
report.

**Second pass, recorded because the first one was wrong.** The guard as first written matched a
recorded path only in full, so it failed A14 and A17, whose records say `HTTPServer.swift:356`
rather than the full path the commit stores. That is the guard doing its job on its own author:
it was fixed to match a bare basename against the last path component (a path containing a
directory is still matched in full, so `Sources/A.swift` cannot be satisfied by
`Sources/B/A.swift`). It now exits 0 — `backed 3 · skipped 2 · unbacked 0` — and
`shellcheck -S style` is clean on it.


---

## A05 — a written justification for every `@unchecked Sendable` — **DONE**

**DONE** · unsafe · discovered by L2, closed in `3ef1cc6`

`@unchecked Sendable` is a promise the compiler stops checking. The ledger found four of them with
no statement of what was being promised; there are **five** — `ToolRegistry` post-dates the
enumeration and turned up under `grep` while the fix was being made. Every conformance in
`Sources/` now carries the invariant it is asserting:

| Type | What is confined, and by what |
| --- | --- |
| `HTTPServer` | `connections`, `streams`, `running`, `failure` under `stateLock`; `listener` touched only by `start()`/`stop()` |
| `EventStream` | private `open` under `lock`; all four accessors take it; `connection` is a `let` |
| `ProgressBox` | private `lastReported` under `lock`, whole read-modify-write; the callback runs *after* unlock |
| `ToolRegistry` | private `tools` under `lock`; `ToolProvider: Sendable` is what makes the escaping value safe |
| `DocumentIngestor` | declares no `var` at all — `let` immutability is the whole confinement |

Each type was read for a genuinely broken invariant rather than merely annotated; none was found,
so this closes without a new task. Doc comments only — **no code changed**, which is stated because
a justification that needed a code change to be true would have been a different task.

`swift build` 0 warnings 0 errors; `swift test` 557 tests in 77 suites passing.

---

## A08 — `WebTransport` is pinned exactly — **DONE**

**DONE** · deps · discovered by L0, closed in `6c1ef31`

`Package.swift` now reads `exact: "1.3.7"` in place of the `from: "1.3.7"` range, with the reason
written beside it: the transport is the security boundary for the engine connection, and two
behaviours this app depends on are tied to an exact version — the `newConnectionLimit` lifetime-cap
semantics that changed in 1.3.7, and the first-frame subscription trigger documented in
`WebTransportClient.connect()`. A range would let a future release move either behaviour under this
app without the version changing to notice.

**Stated deviation.** The literal `.exact("1.3.7")` spelling is deprecated under
swift-tools-version 6.3 and emits a manifest warning. Suppressing a warning is forbidden by §0, so
the non-deprecated labelled form `exact:` was used: the same exact requirement, without the
warning. Verified independently by the coordinator — the manifest builds with 0 warnings and
`swift package resolve` still resolves to 1.3.7 (`3df28f2a`).

---

## Phase D — the line-depth passes

Phase B's L1 (architecture/module) and L3 (line) passes were recorded as run but had not been
taken to line depth over the code, and the §5 placeholder hunt was closed on a single sweep. They
have now been run as seven read-only passes over disjoint slices covering **every file in
`Sources/`** (except the generated `WebAssets.swift`, which has its own byte-for-byte drift test),
**all 12 files in `tools/`** and the whole `web/` front end. Each pass reports what it examined and
found sound as well as what it found wrong, so the coverage claim is checkable rather than
asserted.

**What the passes found, in severity order.** Detail and evidence for each are in `ledger.json`.

| id | sev | finding |
| --- | --- | --- |
| **A20** ✅ | **S1** | **Stored DOM XSS — FIXED.** `web/app.js:502` interpolated the moderator-supplied seat name straight into `innerHTML`; `POST /api/seat` accepts an arbitrary name, so `<img src=x onerror=…>` was stored and ran in every client rendering a live turn — reachable by anyone who can reach the API, which per A01 is anyone on the LAN. The scaffold is now a fixed string and the name is assigned with `textContent`; `WebAssets.swift` regenerated; a regression test reads the bytes the server serves. |
| A21 | S2 | `tools/install.sh:191` — the model **integrity check fails open**: when the HEAD request yields no `Content-Length` the expected size is recorded as 0, which then means "accept any size" and skips the post-download check. |
| A22 | S2 | `tools/start.sh:99` — `stop_all` kills a stale PID from a pid file with no ownership check, though the correct `ps … \| grep -qE "chatbots\|caddy"` check already exists on the by-port branch. |
| A23 | S2 | `tools/capture-devices.py:277` — a viewport mismatch only prints; it cannot fail the run, though the docstring promises otherwise. |
| A24 | S2 | `tools/fetch-metal.sh:51` — a **native binary artifact** is downloaded with no digest or signature and embedded in the ad-hoc-signed app. |
| A28 | S2 | **Three recorded counts are wrong** and the rest are not reproducible from the commands that produced them — see the correction below. |
| A25 | S3 | `tools/install.sh:352` — the project path is interpolated into `bash -c`, so a directory name containing an apostrophe is command injection at install time. |
| A26 | S3 | `tools/install.sh:313` — `run_with_timeout` kills the wrapper, not the `swift run` grandchild it timed out on. |
| A27 | S3 | `tools/cdp.py:226` — `stop()` hardcodes the profile marker instead of checking `self.profile`, so a custom `--user-data-dir` leaves Chrome running. |

### A28 — the baseline counts are wrong, and it matters which way

Every number the audit measures against was re-derived from the tree. Three are wrong and several
cannot be reproduced at all:

| Recorded | Actual | How the wrong number happened |
| --- | --- | --- |
| `swiftlint` 401 findings | 401 when scoped to `Sources`/`Tests` | an **unscoped** `swiftlint lint` also lints `.build/checkouts` and reports ~37 000, so the scoping is load-bearing and was never written down |
| `swift-format` 29 900 diagnostics | not reproducible | 29 904 is the baseline file's *line* count |
| shellcheck 24 notes | **7** findings | 24 is the baseline file's *line* count |
| test-target warnings 5 sites | **8** | the capturing grep truncated multi-line diagnostics |
| "Force unwraps in `Sources/`: two … not a task" | **12** `!` sites | the review under-counted and signed off clean |
| ruff 11 · pyright 2 · semgrep 3 · gitleaks 0 · `try?` 72 across 23 files · ASan clean · TSan one race then clean | all reproduce exactly | — |

The errors run **both ways** — the warning count was understated, the shellcheck count overstated,
the force-unwrap review understated — so a reader cannot assume the error is conservative. Each
number in `plan.md` now carries the method that produced it, and A28's fix is to make that true of
every one of them.

The twelve `!` sites are themselves part of A28: all are currently unreachable traps
(`ZoomStore.levels.first!`/`.last!` on a 7-element literal; `mlx ?? openAI!` where both inits
guarantee `mlx`; three `Continuation!` that are only ever read with `?.`), so the fix is to declare
them as the optionals they already behave as, not to add runtime checks.

### Also re-verified while re-deriving the baseline

- **`main` is untouched**: local and `origin/main` both at `a6d6999`, zero commits on `main` since
  the audit branch was cut.
- **§5 placeholder sweep over tracked source: 0 markers.**
- **No `try!`, `as!` or `-Wno-` anywhere in `Sources/` or `Tests/`** — §0's forbidden fixes are absent.
- **No real credential is tracked**: the `sk-`/`tvly-` matches in the tree are test fixtures
  (`sk-test-…`, `tvly-test-…`), the gitignored `.secrets.env`, an ignored `.run/` log, and one
  binary false positive in `promo/App.png`. `AUDIT/` contains none.
- **The single `precondition`** (`ConversationEngine.swift:221`, seats non-empty) is **not**
  reachable from the network: `POST /api/roster` takes a roster *id* resolved from `RosterLibrary`,
  never a caller-supplied seat list. Not a finding.

### A20 — the stored XSS, closed

**DONE** · unsafe · discovered by the line-depth pass over `web/` and `tools/`

The live-pane header was the one render path in `web/app.js` that did not escape, and it carried
the one string in the file that is entirely moderator-controlled. `createLiveElement` built it with

```js
el.innerHTML = `<div class="msg-head"><span class="msg-who">${name.toUpperCase()}</span>` + …
```

and `name` is the seat's name from the server snapshot. `POST /api/seat` accepts an arbitrary name
and the rename field posts arbitrary `contentEditable` text, so renaming a seat to
`<img src=x onerror=…>` stored a script that ran in every client rendering a live turn in that
room. `.toUpperCase()` is not sanitisation — tag and attribute names are case-insensitive. Every
other path in the file already escaped (`bodyHTML`, `escapeHTML`, `textContent`), which is why
this read as safe.

**The fix** is the shape the rest of the file already uses: the scaffold stays a fixed string and
the name is assigned with `textContent`. `web/` remains the source of truth and
`tools/embed-web.py` regenerated `WebAssets.swift`, so the bytes the server serves carry it —
asserted by the existing byte-for-byte drift test.

**The guard, and why it is a guard rather than a comment.** A test reads the asset the server
actually serves — not the file — and asserts that `createLiveElement` sets the name as text and
contains no `${name` interpolation. Its first version delimited the function with a 900-character
window and **passed a body it had truncated**: adding the explanatory comment pushed `textContent`
past the window, so the test failed on correct code. That is the same failure mode as the counts
in A28 — a number standing in for the thing it was supposed to measure — so it now delimits the
function by its own closing brace. Recorded because a guard that can silently stop guarding is
worse than no guard: the A19 lesson in a different medium.

**Verification.** `swift build --build-tests` 0 warnings 0 errors under the new A03 gate;
`python3 tools/embed-web.py --check` exit 0; `swift test` **558 tests in 77 suites passed**.

### Findings from the remaining slices

The five slices still outstanding when the first batch was recorded have now reported. Every
finding below is a ledger entry with file:line, concrete impact and quoted evidence in
`ledger.json`; the table is generated from that file so the two cannot drift. **One of them is the
audit's first S0.**

| id | sev | file:line | what | status |
| --- | --- | --- | --- | --- |
| A29 | **S0** | `APIServer.swift:612 -> EngineService.swift:335` | The attachment filename is used verbatim as a filesystem path: unauthenticated arbitrary file write | DONE (`208540c`) |
| A30 | **S1** | `HTTPServer.swift:184,191` | A negative Content-Length passes both guards and is used as a slice offset, trapping the process | DONE (`cbf39c7`) |
| A31 | **S1** | `HTTPServer.swift:571` | SSE connections are never reaped, so streams and connections grow for the life of the process | DONE (`679551f`) |
| A32 | **S1** | `WebTransportServer.swift:219 and WebTransportClient.swift:278` | A frame over the protocol cap is swallowed by try?, permanently desyncing the session | DONE (`c63b7b3`) |
| A33 | **S1** | `ConversationEngine.swift:764` | Restarting a running conversation orphans the new turn loop, so Stop and Pause become no-ops | DONE (`b88eee1`) |
| A34 | **S1** | `ConversationStore.swift:122` | ConversationStore.save destroys the records it deliberately refuses to read | DONE (`59555f0`) |
| A35 | **S1** | `ChatController.swift:428-452` | A turn ending is never observed, so isGenerating sticks on forever: stuck UI, duplicated answer, disabled controls | DONE (`3752067`) |
| A36 | **S1** | `DocumentImport.swift:158-171` | The conversion timeout can never fire: the pipe reads block forever first, and the drain order can deadlock | DONE (`84fc613`) |
| A37 | **S2** | `HTTPServer.swift:519` | The HTTP listener has no read or idle deadline and no connection cap | DONE (`f1dd7a7`) |
| A38 | **S2** | `WebTransportClient.swift:97-100` | A failed openBidirectionalStream leaks the session and leaves isConnected true | DONE (`6229d1f`) |
| A39 | **S2** | `WebTransportClient.swift:184-190, :286` | Replies are matched by queue order, and removeFirst() assumes in-order completion | DONE (`219e3ce`) |
| A40 | **S3** | `WebTransportServer.swift:128` | stop() leaves live WebTransport sessions serving and never closes them | DONE (`9a4dc18`) |
| A41 | **S2** | `ConversationEngine.swift:230` | An orphaned unbounded event stream retains every event, including a full prompt per turn, for the process lifetime | DONE (`d870f3d`) |
| A42 | **S2** | `MLXEngine.swift:129` | MLXEngine.compact mutates a local spec that generate() never reads, so maxTokens and thinking-off are ignored | DONE (`978550d`) |
| A43 | **S2** | `MLXEngine.swift:503` | The reasoning ceiling truncates the turn instead of forcing an answer, and unlimited thinking gets less headroom than high | DONE (`e5e2872`) |
| A44 | **S2** | `ConversationEngine.swift:718` | Reopening a finished research conversation and pressing Start writes a second report with zero turns | DONE (`60e2f49`) |
| A45 | **S2** | `ConversationEngine.swift:1040` | Auto-compaction is measured against a static window instead of the engine's learned one | DONE (`2ed98a8`) |
| A46 | **S2** | `ChatController.swift:890-902` | Attachment chips print '0 words' / 'Zero bytes' because the engine's summary and token count are discarded | DONE (`4242b40`) |
| A47 | **S2** | `ChatController.swift:1026-1033 + ChatBotsApp.swift:33-34` | Saved source material is silently discarded at launch and then erased from settings | DONE (`cb94c56`) |
| A48 | **S2** | `ChatController.swift:675-687` | ChatController issues overlapping requests against a client whose protocol is documented as one-request-at-a-time, so replies cross | DONE (`6371ed5`) |
| A49 | **S2** | `EngineSupervisor.swift:149-166 + ChatBotsApp.swift:120` | The wait-then-SIGKILL engine teardown is dead code, so an owned engine can outlive the app | DONE (`265b309`) |
| A50 | **S3** | `EngineSupervisor.swift:129-131` | A startup timeout reports .idle, discarding the failure reason the app exists to show | DONE (`30f930c`) |
| A51 | **S3** | `Views/ControlBar.swift:266-279 + ChatController.swift:839-843` | 'Models > Load ...' is a no-op placeholder presented as a working control | DONE (`b9bcebb`) |
| A52 | **S2** | `Attachments.swift:160-176 + OpenAIResponsesEngine.swift:171-177, :215` | An accepted image with unrecognized magic bytes, notably HEIC, is silently never sent | DONE (`4e49a37`) |
| A53 | **S2** | `ModelStore.swift:129-142` | A partial sharded download is reported as a complete checkpoint | DONE (`54800d4`) |
| A54 | **S2** | `OpenAIResponsesClient.swift:492-538` | A truncated SSE stream is accepted as a finished turn: the terminal event is never required | DONE (`c7c062c`) |
| A55 | **S3** | `OpenAIResponsesClient.swift:165-184` | A CRLF .secrets.env yields a key that cannot authenticate, and the app does not report it missing | DONE (`34a7f1f`) |
| A56 | **S3** | `TavilyClient.swift:128-134` | The 'empty results' retry is decided before the blank-result filter runs | DONE (`251c8de`) |
| A57 | **S3** | `OpenAIResponsesEngine.swift:187, :99-157` | The engine re-probes /v1/models every turn and misreports an unparseable body as 'no model loaded' | DONE (`2ed35d2`) |
| A58 | **S3** | `DocumentImport.swift:68-82` | A PDF reports truncation one character early and the joined text exceeds the declared ceiling | DONE (`00b7186`) |
| A59 | **S2** | `ChatBotsProbe/main.swift:41, :68, :126` | chatbots-probe reports 'all cycles succeeded' and exits 0 when --cycles 0 probes nothing, and aborts on a negative count | START |
| A60 | **S2** | `Sources/ChatBotsCLI/main.swift:461-491` | --benchmark and --session-probe exit 0 when a seat fails to load, reporting success for a checkpoint that never loaded | START |
| A61 | **S2** | `Sources/ChatBotsCLI/main.swift:349, :468, :550, :557` | A legal single-seat roster crashes the flag paths that hard-index seat 2 | START |
| A62 | **S2** | `Sources/ChatBotsCLI/main.swift:133, :638` | An out-of-range --port traps the process, --port 0 announces an unusable URL, and an invalid --transport-port is silently swallowed | START |
| A63 | **S3** | `StreamPacer.swift:146-147, :161-163 + ChatController.swift:486` | StreamPacerPool.generationRates is written but never read, so the learned rate never seeds a new pacer | DONE (`ef47f52`) |
| A64 | **S3** | `StreamPacer.swift:134-135` | StreamPacerPool.minimumRate is dead API and its comment contradicts the pacer's actual floor | DONE (`e328e82`) |
| A65 | **S3** | `Sources/ChatBotsCLI/main.swift:538-544` | --memory-probe prints memoryLimit under both 'gpuLimit' and 'memLimit' | START |
| A66 | **S3** | `Sources/ChatBotsCLI/main.swift:626` | Flags are accepted in modes where they do nothing, without warning | START |

**A29 is the S0**, and it was found independently by two of the five passes. `POST /api/attachments`
takes a `filename` from the request body and `EngineService` appends it to a staging directory with
`appending(path:)` and writes the decoded bytes there. A filename of
`../../../../Users/<user>/Library/LaunchAgents/x.plist` therefore writes attacker-controlled bytes
anywhere the app's user can write, and the file survives the `defer` cleanup. The write happens
before the extractor's type check, so no valid document type is required, and the only gate is
`canAttachFiles`, which is true on every freshly started engine. Combined with A01 — the API is
reachable from the LAN with no credential — this is remote code execution on the next login, not
merely a filesystem nuisance.

**Three of the S1s are the same shape as defects this project has already shipped once**: a
guarantee stated in a comment that the code does not implement (A33's `generationTask`, A34's
`isUnreadable` contract, A36's "bounded" timeout). That is the A18 and A19 pattern, and it is why
the passes were asked to report what they read rather than only what they found.

### Findings from the models, prompts and research slice

| id | sev | file:line | what | status |
| --- | --- | --- | --- | --- |
| A67 | **S1** | `ResearchDirector.swift:328-333` | `.answered` is decided by keyword substring presence and then reported as a complete, undisputed investigation | DONE (`efddc6d`) |
| A68 | **S2** | `ResearchReport.swift:282-329` | The report synthesis prompt concatenates the untrusted transcript with its own rules, with no boundary | DONE (`f099d87`) |
| A69 | **S2** | `PromptBuilder.swift:251-276, :404-406, :55` | Peer-model and API-supplied text is promoted into another seat's system message unescaped | DONE (`83bf5f6`) |
| A70 | **S2** | `PromptBuilder.swift:59` | Research sessions get an entertainment persona in the shared opening brief | DONE (`2ab2157`) |
| A71 | **S2** | `ConflictState.swift:144, :370-371 vs ConflictReader.swift` | Position changes are counted as 'added nothing', so research sessions converge early | DONE (`88cbede`) |
| A72 | **S2** | `ResearchReport.swift:146-150, :157, :198-200` | A mostly-unlabelled report is still declared labelled and traceable | DONE (`4181af7`) |
| A73 | **S2** | `ResearchSession.swift:173-179` | The web-search ceiling is not reliably enforced and can also fire early | DONE (`c7e3079`) |
| A74 | **S3** | `ResearchDirector.swift:411` | The director picks a conflict by Dictionary iteration order, contradicting its own determinism contract | DONE (`489ef41`) |

**Counts are deliberately not written here.** They were, three times, and they were wrong or
stale each time — the last version of this line said 74 tasks and 9 DONE while the file beside it
said otherwise. A count in a growing document goes stale the moment anything lands, so the numbers
live in `ledger.json`, which is the machine-readable twin and the thing the tools read:
`jq` for a status board, and `AUDIT/phase-e.sh` for the acceptance run, which fails when any task
is left open that is not DONE or BLOCKED-with-owner. That is the same reason the wiki tracker and
the Phase D status cells are generated from it rather than maintained by hand.

The two S1s that are not about a crash are worth separating from the rest. **A67** and **A33/A34/A36**
are all the same failure: a guarantee the product states and the code does not implement. A67 is the
worst of them because the guarantee is the product's whole claim — a report that says "every part of
the question has been addressed and nothing remains in dispute" on the strength of substring
matches over `"%"`, `"cost"` and `"law"`.

### A75 and A76 — the browser-facing boundary, found by closing the last coverage gap

The line-depth wave declared exactly one coverage gap: `web/style.css` had been grepped, not read.
Reading it closed the gap and found it clean — no `url()`, no `@import`, no `expression()`, no
`javascript:`, no `behavior()`. What it exposed next door is the more interesting result.

`HTTPResponse.serialised` puts

```
Access-Control-Allow-Origin: *
Access-Control-Allow-Headers: Content-Type
Access-Control-Allow-Methods: GET, POST, OPTIONS
```

on **every** response, and `APIServer.handle` answers **every** preflight with `204`. The comment
above the header says it exists because "a browser reload during development sometimes hits the
port directly". The effect is that any web page the user visits can read
`http://localhost:7788/api/conversations` and receive every kept conversation, and can POST to
`/api/roster`, `/api/moderator`, `/api/seat` and `/api/conversations/new`, because the preflight
that would otherwise block a JSON write succeeds.

**This is independent of A01, and in one way worse.** A01 is about the LAN: it needs someone on the
same network. A75 needs no network position at all — only that the user visits a hostile page while
ChatBots is running. Before A29's fix the same path was a remote file-write primitive from any web
page, which would have been S0.

**Stated nuance**, because it changes what "fixed" has to mean: Chrome is rolling out Private
Network Access, which requires `Access-Control-Request-Private-Network` on the preflight and
`Access-Control-Allow-Private-Network` in the response. Neither is sent, so a current Chrome may
block a public-to-localhost request. Safari and Firefox do not implement PNA, so the attack works
there today. That is why this is graded S1 rather than S0, and why the fix must be a real origin
check rather than a reliance on the browser rollout.

A76 records the rest of the same boundary: no CSP, no `frame-ancestors`, no `nosniff`, no
`Referrer-Policy`, in the server or in the Caddyfile.

### A77 — the shipped app redistributes 14 libraries with no attribution

**S2** · compliance · found by a go-live readiness check on dependency licensing

Every dependency in the resolved graph is permissively licensed, so there is no copyleft
problem — but the licences are not all the same and none of them is reproduced:

| Licence | Packages |
| --- | --- |
| MIT | `mlx-swift-lm`, `mlx-swift`, `WebTransport`, `yyjson`, `EventSource`, and inside `Cmlx`: `fmt`, `json`, `mlx`, `mlx-c`, `metal-cpp` |
| Apache-2.0 | `swift-transformers`, `swift-huggingface`, `swift-crypto`, `swift-collections`, `swift-numerics`, `swift-syntax`, `swift-asn1`, `swift-argument-parser` |

`LICENSE` is the project's own MIT licence and nothing else. There is no third-party notices
file anywhere in the repository, and `tools/make-app.sh` copies no licence text into the bundle,
so a distributed `ChatBots.app` carries fourteen libraries' worth of code with no attribution.
MIT requires the copyright and permission notice to accompany copies; Apache-2.0 requires the
licence text and any `NOTICE` file to be retained.

This is not a security defect, and it is not a reason the code cannot run — it is a reason the
build cannot be *published* as it stands. The fix is mechanical: generate a notices file from the
resolved graph (`Package.resolved` pins exact revisions, so it is deterministic), include it as a
package resource so it reaches the bundle, and copy it into the `.app` beside the icon. The guard
that keeps it true belongs in the `generated-files` CI job that already fails a push when a
generated file has drifted — so a dependency added without its notice fails the push rather than
shipping.

### A78 — the bundle's copyright key carries a description

**S3** · compliance · found by the same go-live check as A77

`tools/make-app.sh` generates `NSHumanReadableCopyright` as `Local build — two MLX models in
conversation.` That key is the copyright line macOS shows in the Finder's Get Info panel, and the
value is a description of the app: it names no holder and no year, so a shipped build would show
no copyright at all, while `LICENSE` states `Copyright (c) 2026 André Borchert`.

The same single-source problem applies to two neighbours in the same heredoc:
`CFBundleIdentifier` is `local.chatbots.twollms` — right for a local build, wrong for
distribution, and it exists in exactly one place — and the version is two literals (`1.0`, `1`)
tied to no release or tag.

Recorded with A77 because they are one piece of work: the app cannot be published until the
libraries are attributed *and* the bundle says who made it and which version it is. The
`generated-files` CI job is the natural guard for both.

---

## A79 — Python bytecode was not ignored — **DONE**

**S3** · repository hygiene · found by looking at a lane's working tree rather than at a document

`.gitignore` had no Python rules at all. `tools/` holds five Python helpers, and the
`static-analysis` CI job that A04 added runs `python3 -m py_compile` over every one of them, so
both running a helper locally and every push leaves `__pycache__/` behind as untracked noise.

That matters slightly more here than it would elsewhere, for the same reason A19 and A28 exist: this
audit's checks depend on `git status` meaning something — `AUDIT/phase-e.sh` fails the acceptance run
when the tree is not clean, and `verify-done-commits.sh` reasons about what a commit contains. A tree
that is dirty for the wrong reason is one nobody reads. `__pycache__/` and `*.py[cod]` are now
ignored, with the reason written in the file; both patterns were checked with `git check-ignore`
against a real directory and a real `.pyc` rather than assumed.

### A80, A81, A82 — three defects found while fixing the tools, and deliberately not absorbed

The `tools/` lane reported these rather than folding them into the tasks it was given, which is the
right call: **A80** is the same defect A23 fixed — a capture whose content is empty still only
prints, so it is published on a green run — but A23's scope was the viewport mismatch, and widening
a task to swallow an adjacent finding is how a task's scope quietly changes. So it is recorded as
its own task.

| id | sev | finding |
| --- | --- | --- |
| A80 | S2 | `tools/capture-devices.py:284-285` — "no messages rendered" prints and does not affect the exit code, while the docstring promises non-zero on any failed capture |
| A81 | S3 | `tools/capture-devices.py:117-126` — the retry loop's `sleep 0.5` sits only in the `except` branch, so a reachable-but-not-ready health response spins with no delay, and the timeout counts iterations rather than wall-clock time |
| A82 | S3 | `tools/cdp.py:258` — `Emulation.setDeviceMetricsOverride` always sets `screenOrientation` to `portraitPrimary`, so the landscape captures that swap width and height report the wrong orientation to the page |

---

## A84 — a commit without a pathspec absorbs another lane's work — **DONE**

**S2** · process · found by the coordinator while committing something unrelated

Commit `f6dc8c2` is titled *"audit(A28): document the baseline directory so its captures cannot
mislead"* and contains four files:

```
AUDIT/baseline/README.md
tools/make-app.sh
tools/start-app.sh
tools/start.sh
```

The three shell scripts are the `tools/` lane's in-progress **A10** work, which that lane had
correctly staged by explicit path. The coordinator then staged its own `AUDIT/` file and ran
`git commit` **without a pathspec** — which commits the entire index, whatever else is in it. So
another lane's unfinished task landed inside a commit named after a different one.

**The fix is procedural and was demonstrated rather than assumed.** In a throwaway repository, with
files `a` and `b` both staged and modified, `git commit -- a` produced a commit containing only `a`
and left `b` staged and untouched. Commits now name their paths. The lanes' explicit-path staging
was already right; the failure was on the coordinator's side, in the one place it was not applying
the same rule.

**This is the second time.** A18's test edits rode inside the A19 repair commit. Two occurrences of
one failure mode is a process defect rather than bad luck, and the shape is identical both times:
staging was correct per task, and then a commit was issued that did not name what it was
committing. `verify-done-commits.sh` guards the *content* of a commit; nothing guarded its *scope*,
and the answer is a habit rather than a script — a commit should always name its paths.

The mixed commit stays in the record. This audit forbids rewriting history, so it is annotated
rather than repaired, and the `tools/` lane was told immediately not to re-commit those files.

---

## A87 — parallel Swift lanes share a module and cannot be isolated — **DONE**

**S2** · process · found by the fix phase stalling rather than by reasoning

Three Swift lanes were started on **disjoint files** (`ConversationEngine`/`ConversationStore`;
`DocumentImport`/`MLXEngine`; `Sources/ChatBotsApp/**`), each with its own `--scratch-path` under
`/tmp`, and A83 had just made the test-port allocator probe for a free port so concurrent test runs
could not collide. None of that was sufficient, and the lanes stalled: edits from 10:38–10:45, no
commit by 10:54, the app-layer lane having written **nothing at all** in half an hour, and the
machine at load 57–92 with 25 compiler processes for 8 cores.

**The reason is the module boundary, not the files.** `swift build` compiles
`Sources/ChatBotsCore` as *one module*, so an in-progress edit in any lane's file is visible to
every other lane's build. A fix that is half-applied — the ordinary state of a file between two
edits — does not type-check, so the other lanes fail for a reason that has nothing to do with their
own change. Separate scratch directories isolate build *artefacts*, and the port probe isolates test
*sockets*; nothing isolates the thing that actually conflicted, which is the source.

**The rule this produces**, written down so it is not rediscovered: parallelism is safe across
repositories, and across language boundaries within one repository, and within Swift it is safe
across *packages* — but not within one module. So the Swift lanes were serialised to one, the
stalled batches were re-run afterwards one at a time, and the non-Swift lanes stayed parallel
because `tools/` shares neither a module nor a compiler with `Sources/`.

This is the **fourth** defect this audit has found in its own process, after A19 (a DONE claim whose
commit carried nothing), A83 (a guard that skipped the case it targeted, and a test-port allocator
that collided) and A84 (a commit that absorbed another lane's staged files). The pattern is the same
in all four: **the audit was confident about its controls and had not checked its own mechanism** —
and each was found by looking at observed behaviour, a `git status`, a guard's output, a file mtime,
rather than by reasoning about the design. That is also how the substantive findings were found.

---

## A89 — the ledger is written non-atomically, and the acceptance run passed on a ledger it could not parse

**S2** · process · found because a lane reported seeing the file mid-write

Two faults, and the second is the serious one.

1. **The ledger was rewritten in place**, so a reader could observe a truncated file. A lane hit
   exactly that and reported *"invalid JSON when I last read it"* — a race, not corruption, since the
   file on disk was valid before and after. It now goes to a temporary file and is renamed over the
   original, so a concurrent reader sees either the old file or the new one.
2. **`AUDIT/phase-e.sh` section 11 passed on a ledger it could not read.** It piped `jq` into a file
   and counted lines; on unparseable JSON `jq` writes nothing, so `total` and `open_count` were both
   `0` and the gate printed `PASS — ledger: 0 tasks, none open, 0 blocked`. That is the one check
   that says whether the audit is finished, and **it went green on a file it could not parse at
   all.** The gate now parses first with `jq -e`, requires the count to be greater than zero, and
   fails with the parse error written to a log.

This is the same shape as A83's guard skipping the case it targeted and A28's counts taken from the
size of a captured file rather than from the findings inside it: **a control that reports success on
the broken input.**

### The pattern, stated once

This audit's own defects are now A19 (a DONE claim whose commit carried nothing), A83 (a guard that
skipped its own target, and a port allocator that collided), A84 (a commit that absorbed another
lane's files), A87 (parallel lanes sharing a module) and A89 (a gate that passed on unparseable
input). They are all the same failure: **the audit was confident about its controls and had not
checked its own mechanism.** Every one was found by looking at observed behaviour — a `git status`,
a guard's output, a file mtime, a lane's complaint — rather than by reasoning about the design, and
every fix has been to make the mechanism **fail loudly on the case it was silently tolerating.**

---

## A117 — the done-commit guard separated its fields with a delimiter bash consumes — **DONE**

**S2** · process · found by verifying the handover instead of trusting it

`AUDIT/verify-done-commits.sh` exited 0 and printed `backed 0 · skipped 109 · unbacked 0`. Every DONE
task was skipped as "names no source path", including A29 and A30, which plainly do name source
paths — so the skip was not a property of the tasks.

The rows were correct. `jq ... | join("\u0001")` emits U+0001, confirmed with `xxd`. The split was
not: `while IFS=$'\001' read -r id commit file_line unit` never split anything, and `$id` held the
whole row. Reproduced in isolation on macOS bash 3.2.57, the shell the verification host ships:
`IFS=$'\001'` over `a\001b\001c` yields `[abc][][]`, while IFS `:`, tab, U+0002, U+001C, U+001E and
U+001F all split correctly.

**U+0001 is bash's own internal `CTLESC` escape character and U+007F is `CTLNUL`**, so a literal one
cannot survive in a shell variable. The delimiter was consumed by the shell that was meant to read
it. This is A83 exactly inverted — that guard skipped the tasks it existed to catch, this one skipped
every task — and it was invisible for the same reason: **a skip is reported, not failed, and the exit
status was 0 either way.**

The consequence is the serious part. Phase C's rule is "`verify-done-commits.sh` must exit 0 before a
fix task is called DONE", and that rule was being satisfied by checking nothing. Phase E section
10/12 passes on this exit status, so the acceptance run would have printed the vacuous count as a
pass — A89's shape again, one gate further on.

The separator is now U+001F: not IFS whitespace, so an empty field stays an empty field (the
property A83 needed), and not one of bash's internal markers. The parse is checked rather than
trusted as well — a row whose first field is not a task id aborts with exit 2, and the rows read must
equal the DONE tasks in the ledger.

`backed 97 · skipped 12 · unbacked 0`, exit 0, which is the figure the handover claimed. Four
mutations, each required to fail: an empty `commit` → `FAIL`, exit 1; a commit touching none of the
named paths → `FAIL`, exit 1; a commit not in the repository → `FAIL`, exit 1; a row that is not a
task id → `FATAL`, exit 2.

---

## A118 — ledger.md is called the source of truth and stops at A89 — **DONE**

**S2** · audit documentation · found while looking for the ledger in order to add a finding

`HANDOVER.md:4` and `:19` call `ledger.md` "the source of truth", `:109` tells the next session to
read it first, and `plan.md:119` agrees. The file did not match: its Summary said "Tasks enumerated |
28" and "DONE | 9", its `## Open tasks` table listed A01–A05, and it carried 26 task headings against
116 tasks in `ledger.json`. A90–A116 appeared **nowhere** in it. A reader following the handover
would have concluded the audit enumerated 28 tasks and closed 9.

The cause is the one this project has already fixed twice for `web/` and `names/`: a hand-maintained
summary of generated facts drifts, silently, one wave at a time. So the status content is now
generated. `AUDIT/render-ledger.sh` rewrites the region between two markers in `ledger.md` from
`ledger.json`, and `--check` turns drift into a failure. The prose sections — this one included —
are outside the markers and are never touched.

Two smaller corrections went with it, because the old claim was wrong in both directions: the file
now states that **`ledger.json` is the authoritative enumeration** and is what every gate reads, and
the same claim was corrected in `HANDOVER.md` and `plan.md`. The renderer refuses to write anything
if the ledger will not parse, rather than emitting an empty status — A89's lesson applied to the tool
that renders the ledger about A89.

`--check` exits 0 in step and 1 on drift; wiring it into `phase-e.sh` section 12 and the CI
`generated-files` job means a status table that is edited by hand fails the gate rather than being
discovered later.

---

## A119 — the page posts a layout diagnostic to a route that has never existed

**S3** · defect · `web/app.js:1393`, `Sources/ChatBotsCore/APIServer.swift:231` · **START**

The page measures its own layout on every load and POSTs it to `/api/client-report`, inside a `try`
whose `catch` is deliberately empty — "a diagnostic that fails must not break the page".

The route has never existed. `grep -rn 'client-report'` finds only the two generated copies of the
page; `APIServer.translate`'s `default:` returns nil for it; and `git log -S 'client-report' --all --
Sources/ChatBotsCore/APIServer.swift` returns nothing, so the receiving end was never written rather
than removed. `ClientReport`, documented as "What the client measured about its own layout" and
carrying `overflowing` — "Selectors of elements wider than the viewport, worst first" — is referenced
nowhere else in `Sources/` or `Tests/`.

So the measurement is real work that is thrown away, and the failure is designed to be invisible.

---

## A120 — the engine the app spawns opens an HTTP port the app does not use

**S3** · defect · `EngineSupervisor.swift:212-220`, `ChatBotsCLI/main.swift:50, :754-770` · **START**

`EngineSupervisor` starts the engine with `--serve --transport webtransport --transport-port 7790`
and no `--port`, and its own comment says the app "does not use the engine's HTTP server, and asking
for it was actively harmful". But `--serve` builds `APIServer(port: options.port)` and calls
`server.start()` unconditionally, before the transport branch, and `options.port` defaults to 7788. A
bind failure is fatal to the child.

7788 is the port the documented website deployment publishes: `Caddyfile:27` is `http://:7788`, on
every interface, started by `tools/start.sh`. So in the configuration the README documents, opening
the desktop app while Caddy is running and nothing is answering on 7790 makes the spawned engine exit
on a collision that has nothing to do with the transport, and the app reports an engine that failed
to start.

That the collision is real is shown by the code's own workaround elsewhere: `TransportCheck` passes
`--port String(port - 1)` with the comment "A port that is not in use, so the HTTP listener cannot
collide with a real run".

---

## A121 — the installer accepts macOS 14 where the package and the bundle require macOS 26

**S2** · incomplete · `tools/install.sh:97-102` · **START**

The installer gates on `OS_MAJOR -lt 14` and proceeds on macOS 14 and 15. `Package.swift` requires
`.macOS(.v26)`, `make-app.sh` writes `LSMinimumSystemVersion 26.0`, and the README says "macOS 26 or
newer". On Sonoma the installer therefore downloads the checkpoint (~3 GB), installs a toolchain if
one is missing, and builds the app — and the app then cannot launch, because the bundle declares a
minimum the host does not meet.

The project already treats two of those three declarations as one fact: `checks.yml` fails the push
when `make-app.sh`'s version and `Package.swift`'s disagree. The installer's copy was the one left
unguarded, and it drifted. Its disk-space text is stale in the same place: "the models alone are
~6 GB" against a single ~3 GB download.

---

## A122 — TransportCheck declares a timeout it never uses, and never drains its child

**S3** · defect · `Sources/ChatBotsCore/TransportCheck.swift:99-101, :142-143` · **START**

`TransportCheck.run(in:port:timeout:)` declares `timeout: Duration = .seconds(30)`, and `grep -n
timeout` over the file finds that line and nothing else: the parameter is dead, so the check the
installer's smoke test runs has no deadline of its own. The same function creates both child pipes
and never reads either — no `readabilityHandler`, no `availableData`, no drain — so a child that
writes more than the pipe buffer holds blocks on the write and is waited on forever.

Both are shapes this audit has already recorded elsewhere: a timeout that cannot fire is A36, a
control presented as working that does nothing is A51, and a child that can block on an undrained
pipe is A36's family. `install.sh` wraps the invocation in a portable 180-second timeout, so the
installer is bounded from outside; `chatbots-cli --check-transport` run directly is not.

---

## Verified and not recorded as defects

Two candidate findings were checked against the code and the toolchain before being written down, and
both were wrong. They are recorded here so that they are not re-opened as if they were new.

* **The certificate's subject alternative names are not malformed.** `CertificateStore` prefixes every
  host but `localhost` with `IP:`, so `::1` is written as `IP:::1`, which reads like an invalid entry.
  It is not: `openssl` parses it as `IP:` + `::1` and normalises it to `IP Address:0:0:0:0:0:0:0:1`,
  which is the correct IPv6 loopback — demonstrated with `openssl req -addext
  subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1` and read back with `openssl x509 -ext`. The
  default host list is `localhost`, `127.0.0.1`, `::1` and no caller passes anything else, so the
  general shape (a DNS name would be labelled `IP:`) has no caller to affect.
* **`docs/webtransport-plan.md` describes an unimplemented design and is not a defect.** It records a
  two-stream event channel, fingerprint pinning and app tests that the implementation does not have,
  and cites a stale test count — but it says so itself, in its first paragraph: "this file is kept as
  the record of what was planned and why, so it describes the intent at the time rather than the
  current state. The test count below (372) is the figure when the plan was written, not today's."

---

## Phase E — the first acceptance run, and the five defects it found

**18 passed, 5 failed.** The run took a fresh clone of the pushed branch on `node1`, a host that did
not develop the fixes, and it is the first time the acceptance script was executed end to end. Every
one of the five failures was a defect in a **gate** or a **stale record**, not in the product — which
is what the run is for, and it is the same pattern as A19, A83, A84, A87, A89, A109, A116 and A117:
*the audit was confident about its controls and had not checked its own mechanism.*

| | |
| --- | --- |
| A123 | The build gate counted SwiftPM's dependency-cache notices (`skipping cache due to an error: The file "maintenance.lock" doesn't exist`) as compiler warnings. Not statements about this code, and not governed by warnings-as-errors. |
| A124 | The dependency gate ran `osv-scanner -r .` over the sanitizer scratch directories, so it reported 16 vulnerabilities from dependencies' own example projects. Scoped to `Package.resolved`: **no issues found**. |
| A125 | The style gates linted generated code (~2 300 of the 3 003 `swift-format` diagnostics were `WebAssets.swift` indentation), and the recorded waivers were **below the tree they governed** — `swiftlint` 222 against a measured 256 at `9eafa54`, so the gate could not have passed on the branch it was written for. |
| A126 | A99's own `console.info` passed a template literal, which semgrep reports as an unsafe format string. The audit's gates caught code the audit had just written. |
| A127 | Section 10 read `tail -2 \| head -1` of the guard's output and printed the blank line, so the acceptance statement asserted its most important gate with no count at all. |

What the first run **passed** is worth stating too, because it is the part that had to be true before
anything else could be believed: `swift test` 824 tests in 139 suites; AddressSanitizer clean;
ThreadSanitizer clean — the branch that A13 opened on a race and A14/A17 fixed; coverage
`Sources/` 77.15 % lines, up from 71.6 % at baseline; `gitleaks` over the full history 0 findings;
`shellcheck`, `ruff` and `pyright` clean; the ledger consistent, every DONE task backed by its own
commit, and the generated files — the web interface, the name lists and the ledger's own status
tables — all in step.

The lesson is recorded once and applies to all five: **a count is only as good as the object it is
taken from.** A28 found figures that were the line counts of captured files; A83 and A117 found
guards that skipped their own targets; A123 and A124 found gates reading SwiftPM's chatter and other
people's example projects; A125 found a waiver quoted from a state the tree had left behind. Each was
found by reading what the mechanism actually did rather than what it was written to do.
