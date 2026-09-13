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
| Tasks enumerated | 13 |
| DONE | 1 (A12 — AddressSanitizer clean) |
| START (proven / reproduced, expected behaviour written) | 11 |
| PROGRESS | 1 (A13 — ThreadSanitizer in flight) |
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
| A13 | — | tests | `AUDIT/baseline/swift-test-tsan.log` | ThreadSanitizer over the whole suite: in flight | test | PROGRESS | this Mac | §1 tooling requirement |

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

## A13 — ThreadSanitizer over the whole suite — **PROGRESS**

**PROGRESS** · test · discovered by §1's tooling requirement

```bash
swift test --sanitize=thread --scratch-path ~/Library/Caches/ChatBots/audit-tsan
```

Running at the time of writing; `baseline/swift-test-tsan.log` will hold the result. The engine is
actor-isolated throughout in Swift 6 mode and the transport is explicitly serialised, so the
expectation is clean — but "expected" is not a result, and this project's own history includes a
data race found by the compiler that a human had not seen.

**Done when:** the run completes, the log is committed, and the result (clean, or findings) is
recorded here and in the plan's baseline table.
