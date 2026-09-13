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
| Tasks enumerated | 19 |
| DONE | 5 (A12, A13 — sanitizer baselines; A14, A17 — the two HTTPServer races; A19 — the commit that claimed them) |
| START (proven / reproduced, expected behaviour written) | 14 |
| PROGRESS | 0 |
| BLOCKED | 0 |

Phase B is **not finished**: L3, L5 and L7 have not been run, and the deeper §5 hunt continues.
Per §11, all findings are enumerated before any fix begins.

---

## Open tasks

| id | sev | unit | file:line | title | category | status | host | discovered-by |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| A01 | **S1** | deploy / `APIServer` | `Caddyfile:27`, `web/app.js` | The website binds every interface and the whole API is unauthenticated | unsafe | START | this Mac | L4 pass |
| A02 | S1 | tests | `Sources/ChatBotsCore/MLXEngine.swift` (19/863 lines), `TransportCheck.swift` (0/216) | The core inference path and the installer's own smoke test are effectively uncovered | test | START | this Mac | L6 pass (coverage) |
| A03 | S2 | build | `Package.swift`, `.github/workflows/checks.yml` | No warnings-as-errors gate, though the baseline is already 0 warnings | test | START | this Mac | L0 pass |
| A04 | S2 | CI | `.github/workflows/checks.yml` | CI runs no build, test, lint, type-check, scanner or coverage step | test | START | this Mac | L0 pass |
| A05 | S2 | concurrency | `Attachments.swift:269`, `HTTPServer.swift:233,251`, `MLXEngine.swift:791` | Four `@unchecked Sendable` declarations, none with a written justification | unsafe | START | this Mac | L2 pass |
| A06 | S2 | style | `Sources/**`, `Tests/**` | `swiftlint` 401 findings and `swift-format` 29 900 diagnostics with no repository config | style | START | this Mac | baseline |
| A07 | S2 | typing | `tools/*.py` (5 files) | Python is 3.14 but unannotated and unchecked: ruff 11, format 5, pyright 2 | style | START | this Mac | baseline |
| A08 | S2 | deps | `Package.swift:32` | `WebTransport` is pinned by range while the project has twice depended on an exact transport behaviour | deps | START | this Mac | L0 pass |
| A09 | S3 | tooling | `tools/cdp.py:42,44,180` | SAST: insecure-websocket and dynamic-urllib findings in the dev-only DevTools client | unsafe | START | this Mac | baseline (semgrep) |
| A10 | S3 | tooling | `tools/*.sh` (24 notes) | `shellcheck -S style` reports 24 notes, mostly SC2001 | style | START | this Mac | baseline |
| A11 | S3 | docs/ops | `README.md`, wiki | Neither the README nor the wiki states that running the website exposes the API to the LAN | docs | START | this Mac | L4 pass (same evidence as A01) |
| A12 | — | tests | `AUDIT/baseline/swift-test-asan.log` | AddressSanitizer over the whole suite: **clean** | test | DONE | this Mac | §1 tooling requirement |
| A13 | — | tests | `AUDIT/baseline/swift-test-tsan.log` | ThreadSanitizer over the whole suite: **one data race found** | test | DONE | this Mac | §1 tooling requirement |
| A14 | **S1** | `HTTPServer` | `HTTPServer.swift:356` write vs `:380` read | `isRunning`/`lastError` are written from a Network.framework callback and read from `waitUntilReady` with no synchronisation | unsafe | DONE | this Mac | A13 (ThreadSanitizer) |
| A17 | **S1** | `HTTPServer` | `HTTPServer.swift:555` append vs `:588-596` `finish()` | `streams` was appended on the main actor without the lock that every other access takes — a concurrent mutation of a Swift array | unsafe | DONE | this Mac | found while fixing A14 |
| A18 | **S1** | tests | `BuiltInKeyTests.swift:20`, `ImageUploadTests.swift:136`, `AttachmentTests.swift:308` | Three tests need the developer's private `models/` and `.secrets.env`, so a fresh clone cannot pass | test | START | node1 | early independent check on node1 |
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
* **A08 deps** — `WebTransport` is `from: "1.3.7"`, a range. The project has already had to raise a
  transport floor once because a behaviour it depended on changed. Expected: an exact pin, or a
  documented reason a range is safe here. Decision task, not a code change.
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

## A18 — the suite is not hermetic — **START**

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
