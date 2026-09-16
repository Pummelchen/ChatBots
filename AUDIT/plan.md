# AUDIT — plan and phase status

Companion files: [`environment.md`](environment.md) (fleet/toolchain), [`inventory.md`](inventory.md)
(scope, §2), [`ledger.md`](ledger.md) + `ledger.json` (tasks), [`baseline/`](baseline) (raw evidence).

Branch `audit/2026-09-15`, cut from `main` @ `02ddd4e`, for the Swift 6.4 / Xcode 27 / macOS 27
re-audit. `main` is deliberately untouched until Phase E is green; the branch then goes back by pull
request. The previous `audit/2026-09-13` audit was landed on `main` as a fast-forward and is history;
`main` has moved on since (`349fefe`), so the two are not the same commit. Nothing is force-pushed.

> **Scope.** This project only, for the reason recorded at the top of `inventory.md`: the
> workspace is a set of sibling repositories, not a monorepo, and `Converter` (Phase A) and
> `MCPSearch` (Phase B, session still active) are owned by other audit sessions.

> **Reading the phase sections below.** They are the 2026-09-13 audit's own plan and status, kept as
> the record of how that audit ran. The 2026-09-15 re-audit re-ran Phase A and Phase B against the
> Swift 6.4 toolchain and those results are appended to [`environment.md`](environment.md) and
> [`inventory.md`](inventory.md); it is **in Phase C**, and its Phase E has not been run. Where the
> two disagree about counts, `ledger.json` decides and nothing hand-written here does.

## Phase A — inventory, baseline, environment ✅ complete

| Deliverable | Where |
| --- | --- |
| Scope inventory, dependency graph, trust boundaries, blast radius | `inventory.md` |
| Fleet + toolchain, install method, reproducibility | `environment.md` |
| Baseline: build, tests, coverage, lint, analyzers, scanners | `baseline/` |

### Baseline numbers — the regression yardstick

Nothing later may be worse on any of these without an explicit, numbered, justified task.

**Every figure now carries the method that produced it** (A28). Three of them were wrong, and the
reason was always the same: the number was taken from the *size of a captured output file* rather
than from the findings inside it. That is recorded rather than quietly fixed, because the errors
ran in both directions — the test-warning count was understated, the shellcheck count overstated,
and a review was signed off "clean" while counting two of twelve — so a reader cannot assume the
error is conservative.

| Metric | Value | How counted | Evidence |
| --- | --- | --- | --- |
| Debug build (products) | **0 compiler warnings, 0 errors** | `swift build`, grep for `warning:`/`error:` | `baseline/swift-build-debug.log` |
| Release build (products) | **0 warnings, 0 errors** | `swift build -c release`, same grep | `baseline/swift-build-release.log` |
| Test target warnings | **8 unique sites** (was recorded as 5) | `swift build --build-tests 2>&1 \| grep -i warning`, after deleting the test target's object dir. The original grep truncated multi-line diagnostics | `baseline/test-warnings.txt` is **wrong**; corrected to 8 and fixed by A03 | 
| Tests | **555 → 557** in 77 suites | the runner's own `Test run with …` line | `baseline/swift-test.log`; 557 after A18 added two hermetic tests; 558 after A20 added the XSS guard |
| Coverage `Sources/` | **71.6 % lines · 70.0 % functions · 66.1 % regions** | `llvm-cov report` over `Sources/` | `baseline/coverage-sources.txt` |
| Coverage, core inference path | `MLXEngine.swift` **2.2 %** (19/863), `TransportCheck.swift` **0 %**, `OpenAIResponsesEngine` 11.0 %, `WebTools` 11.4 %, `TavilyClient` 16.5 %, `APIServer` 60.2 % | same report, per file | same |
| `swiftlint` | **401** findings before A06, **222** after its config | count of the JSON reporter's array. A06's `.swiftlint.yml` excludes `.build`, so an unscoped `swiftlint lint` now reports the same 222 instead of ~37 000 from dependency code — the exclusion is load-bearing and is why the two commands agree | `baseline/swiftlint.json` |
| `swift-format lint` | **not reproducible as recorded** (was 29 900); **3 003** after A06's config | 29 904 was the line count of the captured file (A28). Now counted from `warning:`/`error:` lines | `baseline/swift-format-lint.txt` |
| `ruff check` / `ruff format --check` | **11 errors / 5 files would be reformatted** | `ruff check`'s own summary line; `ruff format --check`'s file list | `baseline/ruff-*.txt` — reproduces exactly |
| `pyright` | **2 errors** | `pyright`'s own `N errors, M warnings` line | `baseline/pyright.json` — reproduces exactly |
| `shellcheck -S style` | **4 findings** at the baseline: 2 × SC2001 (`make-app.sh`), SC2034 (`start-app.sh`), SC2015 (`start.sh`) — **0 now**, over every tracked script | `grep -cE 'SC[0-9]{4} \((style\|info\|warning\|error\)):'` — one per finding. This number was wrong **twice**: 24 was the captured file's **line count**, and 7 was `grep -oE 'SC[0-9]{4}'`, which also matches the three `shellcheck.net/wiki/SCnnnn` help URLs printed under the findings | `baseline/shellcheck.txt` is 24 lines containing 4 findings; A10 fixed the four, A192 widened the glob from `tools/*.sh` to `git ls-files '*.sh'` (18 scripts) |
| Force unwraps in `Sources/` | **12 `!` sites** (a review recorded "two … not a task") | `grep -nE '[A-Za-z0-9_)\]]!\s*($\|[^=])' Sources/`; 10 force unwraps + 3 implicitly-unwrapped declarations, minus overlap. None can currently trap; fixed by A28 | see A28 in `ledger.md` |
| `try?` sites in `Sources/` | **72 across 23 files** | `grep -rno 'try?' Sources` — reproduces exactly | `baseline/` |
| Secret scan, **full history** (`gitleaks --log-opts=--all`) | **0 findings** | `gitleaks` JSON report, read as a count only; values never echoed | `baseline/gitleaks.json` |
| Dependency CVE (`osv-scanner`) | **no issues found** | the tool's own summary | `baseline/osv-scanner.txt` |
| SAST (`semgrep --config auto`) | **3 findings**, all in `tools/cdp.py` | `jq '.results \| length'` | `baseline/semgrep.json` — reproduces exactly |
| SAST, what `auto` resolved | a **1074-rule policy**, of which **461 ran** for this tree's languages, over 101 targets | semgrep's own scan summary, which the gate no longer suppresses with `--quiet` | `baseline/swift64/a192-semgrep-rules.log` — A192: the rule set is fetched from the registry at scan time, so no pin covers it; the gate now records what it resolved |
| §5 placeholder sweep | **0 markers** (TODO/FIXME/HACK/XXX/WIP/STUB) | `git grep -cE` over tracked source; re-run in Phase C, still 0 | `inventory.md` §2.3 note |
| Forbidden constructs (§0) | **0** — no `try!`, no `as!`, no `-Wno-` in `Sources/` or `Tests/` | `git grep -nE 'try!\|as!\|-Wno-'` | re-run in Phase C |
| AddressSanitizer, full suite | **clean** — exit 0, no sanitizer report | `swift test --sanitize=address` | `baseline/swift-test-asan.log` |
| ThreadSanitizer, full suite | **before the fix: 1 data race** (`HTTPServer`, A14 + A17); **after: clean, exit 0** | `swift test --sanitize=thread` | `baseline/swift-test-tsan.log`, `-after.log` |


Three baseline results are worth stating plainly because they are *good* and should not
regress: **no secret in the full history**, **no known CVE in the dependency set**, and
**no placeholder marker anywhere in tracked source**.

**Recorded waivers.** Two style gates cannot reach zero without either reformatting the whole tree
or hiding findings, so their residual is waived at a stated number rather than quietly tolerated.
The lines below are the single source for those numbers — `AUDIT/phase-e.sh` reads them, and fails
if either count is above its waiver, so raising one is a deliberate edit rather than a silent
drift. A06 explains what the residual is, by rule, in `.swiftlint.yml` and `.swift-format`.

```
swiftlint waiver: 255
swift-format waiver: 744
```

**Both numbers were re-measured when Phase E was first run (A125), and both had been wrong:**

* **`swift-format` was measuring generated code.** The recorded 3 003 included ~2 300 indentation
  diagnostics from `Sources/ChatBotsCore/WebAssets.swift`, which embeds `web/` at column 0 — so the
  figure was a function of the web interface rather than of this repository's code, and editing a
  line of `web/app.js` moved the waiver. The gate now lints authored Swift only, the same two
  generated files that `.swiftlint.yml` already excludes, which makes the honest number **744**.
  Measured at the handover head `9eafa54` and after this session's work, it is **744 both times**:
  the changes added none.
* **`swiftlint` 222 was stale.** The tree at `9eafa54` already measured **256** — later audit waves
  added findings without re-measuring the waiver — so the gate could not have passed on the branch
  it governs. It is now **255**, one below that, because A114's flag validation added findings and
  replacing ten duplicated error messages with one `reject()` helper removed more than it added.

Neither number is a target to grow into: they are the measured residual, and a change that raises
either one has to edit these lines and say why.

**Semgrep waivers.** A09's findings in `tools/cdp.py` are waived in writing - three findings
across two rules: `insecure-websocket` fires twice (at `:108` and `:110`) and `dynamic-urllib`
once. The lines below are what `AUDIT/phase-e.sh` matches on. They are matched by rule id **and** path, not by
count, because a count cannot tell a justified finding from a new one: fixing one and introducing
another would leave the total unchanged.

```
semgrep waiver: javascript.lang.security.detect-insecure-websocket.detect-insecure-websocket tools/cdp.py
semgrep waiver: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected tools/cdp.py
```

Both are correct for a client that drives a headless Chrome on loopback and nothing else, and
after A09 the code **enforces** what the scanner cannot see: `require_loopback_host` refuses any
endpoint that is not `127.0.0.1`, `localhost` or `::1` before a socket is opened, the URL scheme
is pinned to `http` and built only from validated values, and the reply is read with a bound. The
findings stay visible — there is no `nosemgrep` — and each site carries a comment saying what the
rule cannot know.

`shellcheck -S style` (4 findings at the baseline, all fixed by A10), `ruff check`,
`ruff format --check` and `pyright` are **not** waived: those are clean targets or owned by a named
task. A192 widened the shell lint from `tools/*.sh` to every tracked `*.sh`, which brings the
audit's own scripts and the probe scripts under `AUDIT/` into the gate; the run is 0 findings over
18 scripts (`baseline/swift64/a192-shellcheck-scope.log`). The Python gates (parse, `ruff`,
`pyright`) stay scoped to `tools/*.py`, which is all the Python this repository ships: the two probe
scripts under `AUDIT/baseline/` are research artifacts, they are **not** clean under those gates,
and that is stated here rather than left to be inferred from the glob.

**One gate input is not pinned, and is not claimed to be.** `semgrep --config auto` fetches its
rule set from the Semgrep registry when it runs, so the version pin on the *binary* (1.176.0) says
nothing about the rules: on 2026-09-15 the registry served a 1074-rule policy
(`sha256 d246b001…`, 2 423 491 bytes) of which semgrep ran 461 for this tree's languages. A192
therefore removed `--quiet` from both semgrep invocations — the scan's own summary (rules run,
targets scanned, and the one skipped target, the 1.5 MB app PNG) is now in the job log and in
`phase-e.sh`'s line — and recorded the figures here. Pinning the policy was considered and
rejected: the registry serves no versioned reference to `auto`, and vendoring the resolved file
would freeze the rule set *and* require a gitleaks exclusion, because that file embeds the
registry's own example credentials (two findings, values never echoed,
`baseline/swift64/a192-semgrep-rules.log`).

## Phase B — audit passes (in progress)

| Pass | Scope | Status |
| --- | --- | --- |
| L0 repository | pins, lockfile, CI config, `.gitignore`, committed artifacts, history leaks, licensing | ✅ A08, A09, A10; gitleaks and osv clean |
| L1 architecture | boundaries, layering, duplication, contracts, error strategy, config | ✅ second wave — A05, A22, A26, A41, A63; doc-comment contracts checked against behaviour throughout |
| L2 module | public API, invariants, resource lifecycle, concurrency, cancellation, timeouts, retries, backpressure | ✅ A05, A08, A14, A17, A31, A32, A37-A40 |
| L3 line | logic, off-by-one, wrong branch, truncation, unchecked returns, dead params | ✅ second wave — A21, A23-A25, A28, A42-A45, A52-A62, A64-A66, A73, A74 |
| L4 security | injection, SSRF, TOCTOU, temp files, authn/authz, secrets, untrusted model output, prompt injection | ✅ A01, A11, A20, **A29 (S0)**, A68, A69; SSRF confined to the one allow-listed host, TLS validation intact, no credential in history |
| L5 performance | hot paths, repeated I/O, unbounded memory, blocking on async paths | ✅ A15, A36, A41, A45, A57, A73 |
| L6 tests | coverage gaps, assertions that assert nothing, flakiness, failure paths | ✅ A02, A06, A18, A59-A62 — and two tests found to encode the wrong rule (A53, A67) |
| L7 ops | logging, health checks, shutdown, config validation, runbook accuracy, rollback | ✅ A16, A26, A30, A40, A49-A51, A65 |
| §5 placeholders | markers, stub returns, always-true validators, canned data, sleeps, localhost defaults | ✅ 0 markers; the hunt found A51 (a no-op control presented as working) and A23 (a check that cannot fail) |

**Phase B is complete.** It took two waves. The first recorded L1 and L3 as run without taking them
to line depth, and closed the §5 hunt on a single sweep. The second wave covered **every file in
`Sources/`** (except the generated `WebAssets.swift`, which has its own byte-for-byte drift test),
**all 12 files in `tools/`** and the whole `web/` front end, in seven read-only passes that each
report what they examined and found sound as well as what they found wrong. Findings A20-A74.

The honest lesson is in that gap: **a pass recorded as "run" is not a pass taken to depth**, and
here the difference was 46 findings — including the audit's only S0. The table above previously
said L3, L5 and L7 were "not started" while the commits that ran them were already on the branch,
and marked L1, L2, L4 and L6 "in progress". The table was the stale artifact, not the work.

> **Session paused 2026-09-13 — start with [`HANDOVER.md`](HANDOVER.md).** It carries the
> current counts, what was done, the seven open tasks and the two waves they were planned into, the
> exact next steps (fix → Phase E on `node1` → wiki), and the environment facts a fresh session
> needs. **`ledger.json` is the source of truth** — every gate reads it — and `ledger.md` renders its
> status tables from it with `AUDIT/render-ledger.sh`, which `--check`s the two against each other in
> Phase E. The prose in `ledger.md` is the record of each fix; on status, the JSON wins (A118).

## Phase C — fix → test → audit

The 2026-09-13 audit ran this phase to completion: 127 of 127 tasks DONE, 0 open, 0 blocked. The
2026-09-15 re-audit is **in** this phase — for its live counts read the generated table in
[`ledger.md`](ledger.md), which is rendered from `ledger.json`, not any number written here. Work
order: S0, then S1, then S2, then S3. One task = one commit,
`audit(<id>): <title>`, on `audit/2026-09-15`.

A DONE status is a claim about the tree, so it is checked against the tree and not against the
ledger: **`AUDIT/verify-done-commits.sh` must exit 0** before a fix task is called DONE. It takes
each DONE task's own recorded source paths and fails unless that task's commit touches one of
them — the check A19 was opened to add, after `948ea29` recorded A14 and A17 as DONE while the
fix was still uncommitted. A DONE task naming no source path (a sanitizer baseline, a decision, a
document) is reported as *skipped*, not as *passed*, so the gate cannot be satisfied by naming
nothing.

That guard was itself wrong when this session began: it separated its fields with U+0001, which is
bash's own `CTLESC` marker, so it skipped all 109 DONE tasks and exited 0 — A117, and the reason the
number above is quoted from a run on the verification host rather than from the ledger.

## Phase D — new findings

Continuous; every new finding gets a ledger id the moment it is found. It did not stop when Phase C
finished: the first Phase E run produced five more (A123–A127), and the handover check produced six
before that (A117–A122). Both batches are DONE and recorded rather than absorbed.

## Phase E — final verification

**Complete, and green.** Scripted as `AUDIT/phase-e.sh` (see below), run on a Mac that did not
develop the fixes — `node1` — from a fresh clone of the pushed branch. It requires a clean build with
zero compiler warnings, the full suite green, ASan and TSan clean, a coverage report, scanners clean
or waived in writing, zero placeholders, no non-BLOCKED open task, `AUDIT/verify-done-commits.sh`
exit 0, and the generated files in step.

The first run **failed five of the twelve sections** and every failure was a defect in a gate or a
stale record rather than in the product: A123 (the build gate counted SwiftPM's cache notices as
compiler warnings), A124 (the dependency scan walked the sanitizer scratch checkouts and reported
third-party example projects), A125 (the style gates linted generated code, and the recorded waivers
were below the tree they governed), A126 (a semgrep finding in A99's own new code), A127 (the
acceptance statement read the blank line above the guard's summary). All five were fixed in
`9fa23a7`, and a sixth was found in the next green run's own summary — the error count had the same
defect the warning count was just fixed for (A128, `c14db8a`). The run was then repeated from a new
clone of the final head.

### Acceptance

| | |
| --- | --- |
| Commit tested | `73eac3bd9a4a2cdfa9867b3ad786392c3ff9d392` (`main`) |
| Host | `node1`, a Mac that did not develop the fixes, from a fresh clone of the pushed repository |
| Result | **23 passed, 0 failed** — `AUDIT/baseline/phaseE/summary.txt` |
| Evidence | `AUDIT/baseline/phaseE/` — the run's own logs, the identity of what was tested, and the summary. The instrumented build trees are `.gitignore`d; the logs are committed. |

The run was made on `main`, after the branch was landed on it, and it is the acceptance statement for
what ships. Two earlier runs against `audit/2026-09-13` were green as well (`90e9f7b6`, 23/0); this
one supersedes them because it names the branch the code is on, and because the acceptance script was
corrected in between to accept it (A132).

The figures it produced: 824 tests in 139 suites; 0 compiler errors and 0 compiler warnings; ASan and
TSan clean; coverage `Sources/` 77.08 % lines, 80.49 % functions; `gitleaks` 0 findings over the full
history; `osv-scanner` no issues; `semgrep` 3 findings, all covered by a written waiver; `shellcheck`,
`ruff` and `pyright` clean; `swiftlint` 255 and authored `swift-format` 744, both exactly at their
recorded waivers; `verify-done-commits.sh` backed 116 · skipped 14 · unbacked 0; the ledger at 130
tasks with none open; and the generated files — the web interface, the name lists and the ledger's own
status tables — all in step.

The script reads every figure it reports from the tool that produced it, and that distinction is the
whole reason it exists: every number in this audit that was wrong was wrong because it was derived by
hand from formatted output — A19 recorded a task DONE whose commit contained no source change, and A28
found three counts that were the line counts of captured files rather than finding counts. Each check
here reads its figure from the tool's own report, and the ones that can only *report* a number
rather than enforce a floor say so.

It is written to run on the fresh clone itself: it resolves the repository root, assumes no warm
`.build`, no `models/`, and no `.secrets.env`, never echoes a secret (`gitleaks --redact`, and
only rule ids, files and lines are read out of its report), and is bash-3.2-clean because that is
what macOS ships and what the verification host will use.

It exits non-zero if any gate fails, so a green exit is the acceptance statement. The gate that
matters most for this audit's own integrity is `verify-done-commits.sh`: it is what stops a task
being marked DONE without a commit that backs it.

## Git operations performed, with rollback (§0)

| Command | Purpose | Rollback |
| --- | --- | --- |
| `git switch -c audit/2026-09-13` (from `main` @ `a6d6999`) | create the audit branch | `git switch main && git branch -D audit/2026-09-13` — but the branch is never deleted, per §0; if abandoned it is simply left unmerged |
| `git push origin main:audit/2026-09-13` after each push to `main` | keep the branch in step with `main` rather than frozen at the landing | none needed — it is a fast-forward, so there is no history to lose; to stop, simply stop pushing it |
| `git merge --ff-only audit/2026-09-13` on `main`, then push | land the audited code on the repository's only supported branch | `git push --force-with-lease origin a6d6999:main` — a force-push, which §0 otherwise forbids, and which is safe here only because `main` had not moved since the branch was cut. The branch is left in place either way, so nothing is lost. |

No force-push, no history rewrite, no branch or tag deletion, no `reset`. Until the landing above,
`main` had not been committed to since the branch was created — which is what made the fast-forward
possible and why it was chosen over a squash: a squash would delete the per-task commits that
`verify-done-commits.sh` checks, so the audit's own gate would fail on `main`.

After the landing the branch is **kept in step with `main`** rather than frozen at the landing commit.
Two branches holding the same tree at different commits is one state too many: a reader has to work out
which is newer, and a fix pushed to one silently misses the other. The audit's value is its *history*,
which `main` now carries; the branch name remains a convenient pointer to it.
