# AUDIT — handover: where this stands and what to do next

**The 2026-09-13 audit is complete and landed. The 2026-09-15 re-audit is not.** Read the current
state first, below; everything under *the 2026-09-13 audit, as it landed* is the history of how the
previous audit got where it did, kept because the reasoning is the useful part. **`ledger.json`
carries the authoritative enumeration and status — it is what every gate reads** — and `ledger.md`
renders its status tables from it (`AUDIT/render-ledger.sh --check`) while carrying the prose record
of each fix. The earlier claim that `ledger.md` "is the source of truth and wins on any conflict"
was wrong: it enumerated 28 of the then-116 tasks and stopped at A89, which is recorded as A118.

## Where it stands — the 2026-09-15 re-audit

| | |
| --- | --- |
| Branch | `audit/2026-09-15`, cut from `main@02ddd4e`, for the Swift 6.4 / Xcode 27 / macOS 27 re-audit. **Deliberately unmerged**: by decision, `main` is untouched until Phase E is green and the branch goes back by pull request. `main` has since moved on its own (to `349fefe`), so the branch and `main` are **not** the same commit and must not be described as though they were |
| Tasks | **No count is written here on purpose.** The authoritative counts are the generated table at the top of [`ledger.md`](ledger.md), which `AUDIT/render-ledger.sh --check` keeps in step with `ledger.json` and Phase E re-checks. A hand-copied count going stale is exactly what A118 and A211 record |
| Severity | Every S0 is fixed — A136 (cross-origin drive-by on the HTTP API) and A137 (a non-atomic index write that could lose a conversation). The S1s are the current work |
| Toolchain | Swift 6.4, Xcode 27.0, macOS 27.0, SDK 27.0, uniform across the four nodes. The Metal toolchain component is installed on `node1` only (A133) |
| Phases | A ✅ (this toolchain) · B ✅ · C in progress · D continuous · **E not started** |
| Entry point | `ledger.md`, then [`environment.md`](environment.md), then resume from the highest-severity task that is not DONE or BLOCKED. Do not restart |

## The 2026-09-13 audit, as it landed — history

Everything from here down describes **that** audit, not the current one. Its "0 open" and its green
Phase E are statements about its own 127 tasks. The sections that follow to the end of this file are
that audit's history; the one exception is *Environment facts the next session needs*, which still
describes the fleet.

### Where the 2026-09-13 audit stood, in one table

| | |
| --- | --- |
| Branch | `audit/2026-09-13`, cut from `main@a6d6999`. **Landed on `main` as a fast-forward**, and kept **in step with it** afterwards: not deleted, not frozen, pointing at the same commit as `main`, so there is one state to reason about rather than two that drift. Its own history — the 218 commits with their measured messages — is `main`'s history |
| Tasks | **127 enumerated: 127 DONE, 0 open, 0 BLOCKED** |
| Severity | Every S0 and every S1 is fixed. The last five (A123–A127) were defects in the Phase E gates, found by running them |
| Tests | **824 tests in 139 suites**, green, 0 compiler warnings (`Package.swift` sets `.treatAllWarnings(as: .error)`, so no build command can bypass it) |
| Coverage | `Sources/` 71.6 % lines at baseline, **77.15 %** at acceptance |
| Phases | A ✅ · B ✅ (two waves) · C ✅ · D continuous (12 findings after Phase C) · **E ✅ green** |
| Deliverable | The branch plus `AUDIT/`, fast-forwarded into `main`. Squashing was rejected on purpose: it would delete the per-task commits that `verify-done-commits.sh` resolves each DONE task against, so the audit's own gate would fail on `main` |

Full detail: `ledger.json` (the authoritative enumeration and status, what the gates read) ·
`ledger.md` (the prose record, its status tables generated from the JSON) · `plan.md` (phases,
baselines with their methods, gates, and the re-recorded style waivers) · `inventory.md` (scope) ·
`environment.md` (hosts, toolchain, contention) · `baseline/README.md` (which baseline numbers were
wrong and why) · `baseline/phaseE/` (the acceptance run's own logs and summary).

### What was left when that audit landed

**Nothing in that audit.** What remained was a decision and two stated residuals:

1. ~~**Merge `audit/2026-09-13` into `main`, or review it first.**~~ **Done** — the branch was
   strictly ahead of `main` (0 behind, fast-forwardable) and was fast-forwarded into it. A squash was
   rejected because it would delete the per-task commits `verify-done-commits.sh` resolves each DONE
   task against; the branch is kept, so the audit's own record is intact.
2. **`--share-base` is only set by `tools/start.sh`.** An engine the desktop app spawns without that
   script keeps the loopback base, which is right for the Mac it runs on and not for a phone (A99).
3. **The style waivers are a measured residual, not a budget** — `swiftlint` 255 and authored
   `swift-format` 744. A change that raises either has to edit `plan.md` and say why.


## What was done, in one page

**Phase A/B.** Inventory, environment record, baseline, then seven read-only line-depth passes over
every file in `Sources/`, all of `tools/` and the whole `web/` front end. The first wave of passes
had recorded L1 and L3 as "run" without taking them to line depth; the second wave covered
everything and produced **46 findings on its own, including the audit's only S0**. The lesson is
recorded rather than implied: *a pass recorded as run is not a pass taken to depth.*

**Phase C.** 108 tasks fixed, one commit each, in severity order. Three findings are worth knowing
without reading the ledger:

- **A29 (S0)** — `POST /api/attachments` used the request's `filename` verbatim as a path, so a
  crafted name wrote attacker-controlled bytes anywhere the app's user could write; with A01 (the
  API unauthenticated on the LAN) that was remote code execution at next login. Fixed and **proved
  by mutation**: with the guards disabled, 7 assertions fail including the canary proving the write
  escaped the staging directory and survived the `defer`.
- **A75 (S1)** — CORS was `Access-Control-Allow-Origin: *` and every preflight was answered, so
  **any website the user visited** could read every kept conversation and drive the engine. Removed
  rather than narrowed, after verifying no cross-origin case exists, and deliberately not relying on
  Chrome's Private Network Access rollout.
- **A67 (S1)** — the research report claimed *"every part of the question has been addressed and
  nothing remains in dispute"* on substring matches over `"%"`, `"cost"` and `"law"`. Coverage now
  requires the **room's engagement**. The honest outcome is that the claim is harder to earn and
  sessions run longer.

**The pattern that recurred most**, and the single most useful thing to carry forward: a comment,
doc or test asserting a property the code does not have. A "bounded" timeout that could never fire
(A36); `compact`'s "summarising is not the place for deliberation" while the override went nowhere
(A42); an `isUnreadable` contract the next save destroyed (A34); "a completed stream is the only
thing that counts as success" (A54); "unlimited adds no ceiling to the cap" pinned by a test (A90);
stored attachments carrying text they never carried (A111). **Six findings had a test asserting the
defect**, which is how they survived — so the working rule has been: a test that encodes a bug is a
reason to change the test, and the replacement must assert something stronger.

**The audit found seven defects in its own process**, all recorded rather than quietly fixed, and
the pattern is identical in every one: *it was confident about its controls and had not checked its
own mechanism.*

| | |
| --- | --- |
| A19 | A commit titled *"the two HTTPServer races"* contained no source change — the code was still in the working tree. Now guarded by `verify-done-commits.sh` |
| A83 | That guard read its fields with `IFS=$'\t'`; a tab is IFS whitespace, so an empty `commit` shifted every field and the task was **skipped** — it skipped exactly the case it existed to catch. Also: the test-port allocator collided across runs |
| A84 | A commit without a pathspec absorbed another lane's staged files (the git index is shared, and `git add` + `git commit` is not atomic) |
| A87 | Parallel Swift lanes cannot be isolated by scratch path or port: `swift build` compiles one module, so a lane's half-written file fails every other lane's build |
| A89 | The acceptance run's most important gate **passed on a ledger it could not parse** — `jq` writes nothing on invalid JSON, and zero open tasks looked like success |
| A109 | Dropbox renamed `.git/index` to a "conflicted copy" **three times**, making git report all 226 tracked files as deleted |
| A28 | Three baseline counts were wrong, all from reading the size of captured output instead of the findings inside it |

## What is open — the 7 tasks, and the two waves they were planned into

**Wave 8 (Swift, one lane at a time — see A87):**
- **A113 (S3)** — `ChatBotsProbe/main.swift:38-39, :55-56`: `--hold` silently ignores negatives and
  non-numeric values, and `--port` silently falls back to 7790. The two defects A59 and A62 just
  fixed in the CLI's own flags.
- **A114 (S3)** — `ChatBotsCLI/main.swift:76, :84, :117, :170-172`: five more flags silently keep
  their defaults or are ignored (`--turns`, `--max-tokens`, `--compact-threshold`,
  `--context-window`, `--compact-keep`, and `--transport` outside `--serve`).
- **A115 (S2, new)** — `MLXEngine.swift:231, :239, :261` vs `ChatModels.swift:794-796`:
  `setThinking`/`setDisplayName`/`setPersona` are synchronous while the `LLMEngine` requirement is
  `async`, so a call on the **concrete** type resolves to the protocol extension's async no-op and
  does nothing. Demonstrated: `await concrete.setThinking(.high)` left `thinking == .off` while the
  existential call worked. Latent only because every shipped call site uses `any LLMEngine` — **one
  type annotation away from live**, and a "control that does nothing" in the A51/A92 class.
- **A102 + A108 (S2, test infrastructure)** — two sources of full-suite flakiness, both confirmed to
  reproduce with the newest suites excluded: `AuditEngineStateTestsEventStream.swift:94`
  intermittently reports 172 or 7 against an expected 256 (a *timing-dependent expectation about a
  bounded stream* — A41's `.bufferingNewest(256)` territory, so the test is arguably wrong rather
  than the code), and the WebTransport suite crashed once inside Apple's framework
  (`Network/Connection.swift:5833: Fatal error: Neither nw nor nwGroup is initialized`).
  **Serialising the WebTransport suites is the suggested next step, not retrying.**

**Wave 9 (non-Swift, can run in parallel with anything):**
- **A77 (S2)** — the app ships ~14 third-party libraries (MIT and Apache-2.0) with **no attribution**:
  no notices file in the repo, none copied into the bundle. Fix: generate a `THIRD-PARTY-NOTICES`
  file from the resolved graph, include it as a package resource, copy it into the `.app` in
  `make-app.sh`, and guard it in the `generated-files` CI job. **Touches `Package.swift`, so run it
  when no Swift lane is active** (a manifest change forces a rebuild).
- **A99 (S2)** — kept-conversation share links **404 in the documented deployment**: Caddy proxies
  only `/api/*` while the engine serves `/s/<id>`, measured as `curl -sI …/s/any-id` → 404. A
  `handle /s/*` reverse_proxy fixes the path, but the generated `shareBase` still points at engine
  port 7789, which a phone cannot reach — so a link that resolves would still not work from the
  device the feature exists for.

## What to do next, in order — done, and what it took

These were the instructions this session was handed. They are kept because how they were carried out
is the useful part.

1. **Read `AUDIT/ledger.json` first.** Done — and reading it is what surfaced A118: the page the
   previous handover called the source of truth enumerated 28 of 116 tasks and stopped at A89.
2. **Run `AUDIT/verify-done-commits.sh`** — it must exit 0 before anything is called DONE. Done, and
   it did not exit 0 in any meaningful sense: it reported `backed 0 · skipped 109 · unbacked 0`. Its
   field separator was U+0001, which bash consumes as its own `CTLESC` marker, so it skipped every
   task and passed. That is A117, and fixing it first is what made the rest of the statuses mean
   anything.
3. **Fix Wave 8 serially (one Swift lane at a time — A87) and Wave 9 in parallel.** Done. One task =
   one commit with an explicit pathspec; every new test was shown to fail first; no check was
   weakened. The before/after for the argument and transport fixes was measured on the built
   binaries built from the previous commit in the same build directory, which is how
   `--transport webtransprot --serve` was caught serving HTTP and `--port abc` was caught reporting
   a connection failure.
4. **Then Phase E.** Run twice, and the first run failed five sections. All five were defects in the
   gates rather than the product (A123–A127), which is the whole reason the run is scripted and
   independent. Fixed, then repeated from a **new** fresh clone.
5. **Phase E must run on `node1`, from a fresh clone, and be cleaned up afterwards.** Done:
   `~/chatbots-audit` was removed and re-cloned for the final run, and the toolchain the run needed
   (`caddy` for A99's routing proof) is recorded in `environment.md`.
6. **Then sync the wiki tracker**, whose tables are generated from `ledger.json`. Done — "Open —
   none", 127 tasks, and a changelog entry for this session.
7. **The goal is complete when the ledger has no task that is not DONE or BLOCKED-with-owner, and
   `phase-e.sh` exits 0 on the fresh clone.** Both hold: **128/128 DONE, 0 BLOCKED**, and
   `AUDIT/baseline/phaseE/summary.txt` from the final run is the acceptance statement — **23 passed,
   0 failed**, on commit `90e9f7b6`, from a fresh clone on `node1`.

## Environment facts the next session needs

- **Everything is in Dropbox, and Dropbox mutates what it syncs.** Two incidents, both from the
  same omission — the `com.dropbox.ignored` attribute was believed rather than checked:
  - **`.git` (A109)**: Dropbox renamed `.git/index` to a "conflicted copy" three times, making git
    report all 226 tracked files as deleted. If it recurs: **`rm -f .git/index && git reset --mixed
    HEAD`** — *not* a hard reset, which discards the working tree, and *not* `git add -A`, which
    stages hundreds of phantom deletions. `.git` is now ignored and verified.
  - **`.build` (A116)**: 5 334 conflicted copies inside the build directory plus a module cache
    compiled at a checkout path that no longer existed (`~/Downloads/ChatBots`), so `swift test`
    **exited 1 with no test summary at all**, failing in the dependency build. Fix: `rm -rf .build`
    and let SwiftPM rebuild (5.1 GB), then `xattr -w com.dropbox.ignored 1 .build`. The branch was
    never at fault — the same commit passes on a clean build directory.
  - `.build`, `dist` and `captures` are now Dropbox-ignored and **verified set on this disk**. If a
    build fails in a dependency with a foreign path or a "used twice" filename error, suspect this
    before suspecting the code.
- **One Swift lane at a time** (A87). Non-Swift work (`tools/`, docs, the Caddyfile) runs in parallel
  safely. Give each Swift lane its own `--scratch-path /tmp/…` and remove it when the lane is idle.
- **The development Mac is 8 cores and was heavily loaded** (load 57–92, an unrelated `NVMAIServer`
  from another project, `fileproviderd` watching the Dropbox tree). This is why **no ledger
  conclusion rests on a duration**, and why anything timing-sensitive must be asserted against a
  fake clock rather than measured — A36 and A81's fixes are built that way deliberately.
- **`main` stayed untouched for the whole audit.** Every fix is on the branch and the acceptance run
  names the branch's commit. It was landed on `main` as a fast-forward once the audit was complete —
  the owner's instruction, and the safe direction for a repository whose only supported branch is
  `main`: until then the S0 and the sixteen S1s were invisible to anyone who cloned it.
- **This is a public repository.** Never print, log or commit a secret; `gitleaks` runs with
  `--redact` and only rule id, file and line are ever read out of its report.

## What a reviewer should be most sceptical of

Not the fixes — those are committed and each carries its own evidence. Be sceptical of **the
claims**:

- **`swiftlint` 222 and `swift-format` 3 003 are waived, in writing, in `plan.md`.** They are real
  debt, itemised by rule in the two config files, and the acceptance run fails if either count
  rises. `shellcheck` is at **4** and semgrep's three findings in `tools/cdp.py` are waived with
  reasons. Everything else is clean.
- **Several fixes state a coverage gap rather than claiming coverage** — the app layer (a UI effect
  the test target cannot import), MLX paths needing weights, and the CLI (an executable the test
  target cannot import). Those gaps are enumerated in each task's `evidence_after`; they are honest
  bounds, not omissions.
- **The residuals were recorded rather than smoothed**: A95's answered claim is still keyword-based
  (coverage now needs two seats, but the matching is still lexical), A47's fallback cannot re-upload
  because the engine holds the bytes, and A99's share links are broken in the shipped configuration.
