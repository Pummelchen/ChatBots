# AUDIT — plan and phase status

Companion files: [`environment.md`](environment.md) (fleet/toolchain), [`inventory.md`](inventory.md)
(scope, §2), [`ledger.md`](ledger.md) + `ledger.json` (tasks), [`baseline/`](baseline) (raw evidence).

Branch `audit/2026-09-13` from `main` @ `a6d6999`. `main` is untouched and nothing is force-pushed.

> **Scope.** This project only, for the reason recorded at the top of `inventory.md`: the
> workspace is a set of sibling repositories, not a monorepo, and `Converter` (Phase A) and
> `MCPSearch` (Phase B, session still active) are owned by other audit sessions.

## Phase A — inventory, baseline, environment ✅ complete

| Deliverable | Where |
| --- | --- |
| Scope inventory, dependency graph, trust boundaries, blast radius | `inventory.md` |
| Fleet + toolchain, install method, reproducibility | `environment.md` |
| Baseline: build, tests, coverage, lint, analyzers, scanners | `baseline/` |

### Baseline numbers — the regression yardstick

Nothing later may be worse on any of these without an explicit, numbered, justified task.

| Metric | Baseline @ `a6d6999` | Evidence |
| --- | --- | --- |
| Debug build | **success, 0 compiler warnings, 0 errors** | `baseline/swift-build-debug.log` |
| Release build | **success, 0 warnings, 0 errors** | `baseline/swift-build-release.log` |
| Tests | **555 tests, 77 suites, 0 failures** | `baseline/swift-test.log` |
| Coverage `Sources/` | **71.6 % lines · 70.0 % functions · 66.1 % regions** | `baseline/coverage-sources.txt` |
| Coverage, core inference path | `MLXEngine.swift` **2.2 %** (19/863), `TransportCheck.swift` **0 %**, `OpenAIResponsesEngine` 11.0 %, `WebTools` 11.4 %, `TavilyClient` 16.5 %, `APIServer` 60.2 % | same |
| `swiftlint` | 401 findings, no repository config | `baseline/swiftlint.json` |
| `swift-format lint` | 29 900 diagnostics, no configuration | `baseline/swift-format-lint.txt` |
| `ruff check` / `ruff format --check` | 11 errors / 5 files would be reformatted | `baseline/ruff-*.txt` |
| `pyright` | 2 errors (5 scripts, no strict config) | `baseline/pyright.json` |
| `shellcheck -S style` | 24 style notes, 0 warnings/errors | `baseline/shellcheck.txt` |
| Secret scan, **full history** (`gitleaks --log-opts=--all`) | **0 findings** | `baseline/gitleaks.json` (values never echoed) |
| Dependency CVE (`osv-scanner`) | **no issues found** | `baseline/osv-scanner.txt` |
| SAST (`semgrep --config auto`) | 3 findings, all in `tools/cdp.py` | `baseline/semgrep.json` |
| §5 placeholder sweep | **0 markers** (TODO/FIXME/HACK/XXX/WIP/STUB) | `inventory.md` §2.3 note |
| AddressSanitizer, full suite | **clean** — 555 tests, exit 0, no sanitizer report | `baseline/swift-test-asan.log` |
| ThreadSanitizer, full suite | **1 data race** — `HTTPServer.swift:356` write vs `:380` read (A14); suite still passed | `baseline/swift-test-tsan.log` |

Three baseline results are worth stating plainly because they are *good* and should not
regress: **no secret in the full history**, **no known CVE in the dependency set**, and
**no placeholder marker anywhere in tracked source**.

## Phase B — audit passes (in progress)

| Pass | Scope | Status |
| --- | --- | --- |
| L0 repository | pins, lockfile, CI config, `.gitignore`, committed artifacts, history leaks, licensing | mostly done — findings A09, A10, and the clean gitleaks/osv results |
| L1 architecture | boundaries, layering, duplication, contracts, error strategy, config | in progress |
| L2 module | public API, invariants, resource lifecycle, concurrency, cancellation, timeouts, retries, backpressure | in progress — A08 opened |
| L3 line | logic, off-by-one, wrong branch, truncation, unchecked returns, dead params | not started |
| L4 security | injection, SSRF, TOCTOU, temp files, authn/authz, secrets, untrusted model output, prompt injection | in progress — A01, A07 opened; XSS and secrets verified clean |
| L5 performance | hot paths, repeated I/O, unbounded memory, blocking on async paths | not started |
| L6 tests | coverage gaps, assertions that assert nothing, flakiness, failure paths | in progress — A06 opened |
| L7 ops | logging, health checks, shutdown, config validation, runbook accuracy, rollback | not started |
| §5 placeholders | markers, stub returns, always-true validators, canned data, sleeps, localhost defaults | sweep clean; deeper hunt continues |

**Phase B is not finished.** The findings so far are enumerated in the ledger; the remaining
passes will be appended before any fix begins, as §11 requires.

## Phase C — fix → test → audit

Not started. Work order: S0, then S1, then S2, then S3. One task = one commit,
`audit(<id>): <title>`, on `audit/2026-09-13`.

## Phase D — new findings

Continuous; every new finding gets a ledger id the moment it is found.

## Phase E — final verification

Not started. Requires a fresh clone on a Mac that did **not** develop the fix, clean build with
zero warnings, full suite green, coverage report, scanners clean or waived in writing, zero
placeholders, no non-BLOCKED open task, and the wiki tracker synced.

## Git operations performed, with rollback (§0)

| Command | Purpose | Rollback |
| --- | --- | --- |
| `git switch -c audit/2026-09-13` (from `main` @ `a6d6999`) | create the audit branch | `git switch main && git branch -D audit/2026-09-13` — but the branch is never deleted, per §0; if abandoned it is simply left unmerged |

No force-push, no history rewrite, no branch or tag deletion, no `reset`. `main` has not been
committed to since the branch was created.
