# AUDIT — task ledger

Machine-readable twin: `ledger.json` (same ids; carries every field of §8's schema).
**This file wins on conflict with the wiki.**

Branch `audit/2026-09-13` from `main` @ `a6d6999`. Baseline and evidence: [`plan.md`](plan.md),
[`baseline/`](baseline). Fleet and toolchain: [`environment.md`](environment.md).
Scope and trust boundaries: [`inventory.md`](inventory.md).

Statuses: START → PROGRESS → TEST → AUDIT → DONE, plus BLOCKED. Gates are in `plan.md`; a status
does not advance without its artifact.

> **Session entry point.** Re-read this file and `environment.md` first, then resume from the
> highest-severity task that is not DONE or BLOCKED. Do not restart from scratch.

## Summary

| Metric | Count |
| --- | --- |
| Tasks enumerated | 28 |
| DONE | 9 (A05, A08 — concurrency and dependency pinning; A20 — the stored XSS; A12, A13 — sanitizer baselines; A14, A17 — the two HTTPServer races; A18 — hermetic suite; A19 — the commit that claimed A14/A17) |
| START (proven / reproduced, expected behaviour written) | 19 (A21-A28 added by the line-depth passes, plus the five slices' findings) |
| PROGRESS | 0 |
| BLOCKED | 0 |

Phase B's remaining depth is now being run as line-depth passes over every file (see
[Phase D](#phase-d--the-line-depth-passes) below), which produced A20-A28. Per §11, findings are
enumerated before they are fixed.

---

## Open tasks

| id | sev | unit | file:line | title | category | status | host | discovered-by |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| A01 | **S1** | deploy / `APIServer` | `Caddyfile:27`, `web/app.js` | The website binds every interface and the whole API is unauthenticated | unsafe | START | this Mac | L4 pass |
| A02 | S1 | tests | `Sources/ChatBotsCore/MLXEngine.swift` (19/863 lines), `TransportCheck.swift` (0/216) | The core inference path and the installer's own smoke test are effectively uncovered | test | START | this Mac | L6 pass (coverage) |
| A03 | S2 | build | `Package.swift`, `.github/workflows/checks.yml` | No warnings-as-errors gate, though the baseline is already 0 warnings | test | DONE (`8673488`) | this Mac | L0 pass |
| A04 | S2 | CI | `.github/workflows/checks.yml` | CI runs no build, test, lint, type-check, scanner or coverage step | test | DONE | this Mac | L0 pass |
| A05 | S2 | concurrency | `Attachments.swift:269`, `HTTPServer.swift:233,251`, `MLXEngine.swift:791` | Five `@unchecked Sendable` declarations, none with a written justification | unsafe | DONE | this Mac | L2 pass |
| A06 | S2 | style | `Sources/**`, `Tests/**` | `swiftlint` 401 findings and `swift-format` 29 900 diagnostics with no repository config | style | START | this Mac | baseline |
| A07 | S2 | typing | `tools/*.py` (5 files) | Python is 3.14 but unannotated and unchecked: ruff 11, format 5, pyright 2 | style | START | this Mac | baseline |
| A08 | S2 | deps | `Package.swift:32` | `WebTransport` is pinned by range while the project has twice depended on an exact transport behaviour | deps | DONE | this Mac | L0 pass |
| A09 | S3 | tooling | `tools/cdp.py:42,44,180` | SAST: insecure-websocket and dynamic-urllib findings in the dev-only DevTools client | unsafe | START | this Mac | baseline (semgrep) |
| A10 | S3 | tooling | `tools/*.sh` (24 notes) | `shellcheck -S style` reports 24 notes, mostly SC2001 | style | START | this Mac | baseline |
| A11 | S3 | docs/ops | `README.md`, wiki | Neither the README nor the wiki states that running the website exposes the API to the LAN | docs | START | this Mac | L4 pass (same evidence as A01) |
| A12 | — | tests | `AUDIT/baseline/swift-test-asan.log` | AddressSanitizer over the whole suite: **clean** | test | DONE | this Mac | §1 tooling requirement |
| A13 | — | tests | `AUDIT/baseline/swift-test-tsan.log` | ThreadSanitizer over the whole suite: **one data race found** | test | DONE | this Mac | §1 tooling requirement |
| A14 | **S1** | `HTTPServer` | `HTTPServer.swift:356` write vs `:380` read | `isRunning`/`lastError` are written from a Network.framework callback and read from `waitUntilReady` with no synchronisation | unsafe | DONE | this Mac | A13 (ThreadSanitizer) |
| A17 | **S1** | `HTTPServer` | `HTTPServer.swift:555` append vs `:588-596` `finish()` | `streams` was appended on the main actor without the lock that every other access takes — a concurrent mutation of a Swift array | unsafe | DONE | this Mac | found while fixing A14 |
| A18 | **S1** | tests | `BuiltInKeyTests.swift:20`, `ImageUploadTests.swift:136`, `AttachmentTests.swift:308` | Three tests need the developer's private `models/` and `.secrets.env`, so a fresh clone cannot pass | test | DONE | node1 | early independent check on node1 |
| A15 | **S1** | `EngineService` / `DocumentImport` | `DocumentImport.swift:160-168`, `EngineService.swift:325-357` | Attaching a document blocks the engine's `@MainActor` for the whole conversion, subprocess wait included | perf | START | this Mac | L5 pass |
| A16 | S3 | `ChatBotsCLI` | `Sources/ChatBotsCLI/main.swift:689` | `--serve` has no signal handling, so the listener is never shut down and nothing is flushed on exit | incomplete | START | this Mac | L7 pass |

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
| A29 | **S0** | `APIServer.swift:612 -> EngineService.swift:335` | The attachment filename is used verbatim as a filesystem path: unauthenticated arbitrary file write | START |
| A30 | **S1** | `HTTPServer.swift:184,191` | A negative Content-Length passes both guards and is used as a slice offset, trapping the process | START |
| A31 | **S1** | `HTTPServer.swift:571` | SSE connections are never reaped, so streams and connections grow for the life of the process | START |
| A32 | **S1** | `WebTransportServer.swift:219 and WebTransportClient.swift:278` | A frame over the protocol cap is swallowed by try?, permanently desyncing the session | START |
| A33 | **S1** | `ConversationEngine.swift:764` | Restarting a running conversation orphans the new turn loop, so Stop and Pause become no-ops | START |
| A34 | **S1** | `ConversationStore.swift:122` | ConversationStore.save destroys the records it deliberately refuses to read | START |
| A35 | **S1** | `ChatController.swift:428-452` | A turn ending is never observed, so isGenerating sticks on forever: stuck UI, duplicated answer, disabled controls | START |
| A36 | **S1** | `DocumentImport.swift:158-171` | The conversion timeout can never fire: the pipe reads block forever first, and the drain order can deadlock | START |
| A37 | **S2** | `HTTPServer.swift:519` | The HTTP listener has no read or idle deadline and no connection cap | START |
| A38 | **S2** | `WebTransportClient.swift:97-100` | A failed openBidirectionalStream leaks the session and leaves isConnected true | START |
| A39 | **S2** | `WebTransportClient.swift:184-190, :286` | Replies are matched by queue order, and removeFirst() assumes in-order completion | START |
| A40 | **S3** | `WebTransportServer.swift:128` | stop() leaves live WebTransport sessions serving and never closes them | START |
| A41 | **S2** | `ConversationEngine.swift:230` | An orphaned unbounded event stream retains every event, including a full prompt per turn, for the process lifetime | START |
| A42 | **S2** | `MLXEngine.swift:129` | MLXEngine.compact mutates a local spec that generate() never reads, so maxTokens and thinking-off are ignored | START |
| A43 | **S2** | `MLXEngine.swift:503` | The reasoning ceiling truncates the turn instead of forcing an answer, and unlimited thinking gets less headroom than high | START |
| A44 | **S2** | `ConversationEngine.swift:718` | Reopening a finished research conversation and pressing Start writes a second report with zero turns | START |
| A45 | **S2** | `ConversationEngine.swift:1040` | Auto-compaction is measured against a static window instead of the engine's learned one | START |
| A46 | **S2** | `ChatController.swift:890-902` | Attachment chips print '0 words' / 'Zero bytes' because the engine's summary and token count are discarded | START |
| A47 | **S2** | `ChatController.swift:1026-1033 + ChatBotsApp.swift:33-34` | Saved source material is silently discarded at launch and then erased from settings | START |
| A48 | **S2** | `ChatController.swift:675-687` | ChatController issues overlapping requests against a client whose protocol is documented as one-request-at-a-time, so replies cross | START |
| A49 | **S2** | `EngineSupervisor.swift:149-166 + ChatBotsApp.swift:120` | The wait-then-SIGKILL engine teardown is dead code, so an owned engine can outlive the app | START |
| A50 | **S3** | `EngineSupervisor.swift:129-131` | A startup timeout reports .idle, discarding the failure reason the app exists to show | START |
| A51 | **S3** | `Views/ControlBar.swift:266-279 + ChatController.swift:839-843` | 'Models > Load ...' is a no-op placeholder presented as a working control | START |
| A52 | **S2** | `Attachments.swift:160-176 + OpenAIResponsesEngine.swift:171-177, :215` | An accepted image with unrecognized magic bytes, notably HEIC, is silently never sent | START |
| A53 | **S2** | `ModelStore.swift:129-142` | A partial sharded download is reported as a complete checkpoint | START |
| A54 | **S2** | `OpenAIResponsesClient.swift:492-538` | A truncated SSE stream is accepted as a finished turn: the terminal event is never required | START |
| A55 | **S3** | `OpenAIResponsesClient.swift:165-184` | A CRLF .secrets.env yields a key that cannot authenticate, and the app does not report it missing | START |
| A56 | **S3** | `TavilyClient.swift:128-134` | The 'empty results' retry is decided before the blank-result filter runs | START |
| A57 | **S3** | `OpenAIResponsesEngine.swift:187, :99-157` | The engine re-probes /v1/models every turn and misreports an unparseable body as 'no model loaded' | START |
| A58 | **S3** | `DocumentImport.swift:68-82` | A PDF reports truncation one character early and the joined text exceeds the declared ceiling | START |
| A59 | **S2** | `ChatBotsProbe/main.swift:41, :68, :126` | chatbots-probe reports 'all cycles succeeded' and exits 0 when --cycles 0 probes nothing, and aborts on a negative count | START |
| A60 | **S2** | `Sources/ChatBotsCLI/main.swift:461-491` | --benchmark and --session-probe exit 0 when a seat fails to load, reporting success for a checkpoint that never loaded | START |
| A61 | **S2** | `Sources/ChatBotsCLI/main.swift:349, :468, :550, :557` | A legal single-seat roster crashes the flag paths that hard-index seat 2 | START |
| A62 | **S2** | `Sources/ChatBotsCLI/main.swift:133, :638` | An out-of-range --port traps the process, --port 0 announces an unusable URL, and an invalid --transport-port is silently swallowed | START |
| A63 | **S3** | `StreamPacer.swift:146-147, :161-163 + ChatController.swift:486` | StreamPacerPool.generationRates is written but never read, so the learned rate never seeds a new pacer | START |
| A64 | **S3** | `StreamPacer.swift:134-135` | StreamPacerPool.minimumRate is dead API and its comment contradicts the pacer's actual floor | START |
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
| A67 | **S1** | `ResearchDirector.swift:328-333` | `.answered` is decided by keyword substring presence and then reported as a complete, undisputed investigation | START |
| A68 | **S2** | `ResearchReport.swift:282-329` | The report synthesis prompt concatenates the untrusted transcript with its own rules, with no boundary | START |
| A69 | **S2** | `PromptBuilder.swift:251-276, :404-406, :55` | Peer-model and API-supplied text is promoted into another seat's system message unescaped | START |
| A70 | **S2** | `PromptBuilder.swift:59` | Research sessions get an entertainment persona in the shared opening brief | START |
| A71 | **S2** | `ConflictState.swift:144, :370-371 vs ConflictReader.swift` | Position changes are counted as 'added nothing', so research sessions converge early | START |
| A72 | **S2** | `ResearchReport.swift:146-150, :157, :198-200` | A mostly-unlabelled report is still declared labelled and traceable | START |
| A73 | **S2** | `ResearchSession.swift:173-179` | The web-search ceiling is not reliably enforced and can also fire early | START |
| A74 | **S3** | `ResearchDirector.swift:411` | The director picks a conflict by Dictionary iteration order, contradicting its own determinism contract | START |

**Counts after every pass: 74 tasks — 9 DONE, 65 open, 0 BLOCKED**, of which **1 is S0**, 11 are S1, 34 are S2 and 19 are S3 (A12-A19 carry no severity: they are
baselines and process findings). Counted from `ledger.json`, because the first version of this
line was written by hand and was wrong in three of the four figures.

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
