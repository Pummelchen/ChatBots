# AUDIT — handover: where this stands and what to do next

**Session paused 2026-09-13** to move to another computer. All work is committed and pushed. This
file is the entry point for whoever continues; `ledger.md` is still the source of truth and wins
on any conflict with this page.

## Where it stands, in one table

| | |
| --- | --- |
| Branch | `audit/2026-09-13`, cut from `main@a6d6999`. **`main` has never been committed to** — verified repeatedly, and `origin/main` is still `a6d6999` |
| Tasks | **116 enumerated: 109 DONE, 7 open, 0 BLOCKED** |
| Severity | Every S0 and every S1 is **fixed**. The 7 open tasks are 5 × S2 (A77, A99, A102, A108, A115) and 2 × S3 (A113, A114) |
| Tests | **815 tests in 136 suites**, green, 0 warnings (the product targets build warning-free under `.treatAllWarnings(as: .error)`) |
| Coverage | `Sources/` 71.6 % lines at baseline; A02 took `MLXEngine` 15.3 % → 38.3 %, added `TurnLoop.swift` at 98.4 %, and `TransportCheck` 0 % → 22.8 % |
| Phases | A ✅ · B ✅ (two waves) · C **in progress** · D continuous · **E not started** |
| Nothing is pushed by the fix lanes; the coordinator has pushed every wave | |

Full detail: `ledger.md` (prose, wins on conflict) · `ledger.json` (machine-readable twin, what the
tools read) · `plan.md` (phases, baselines with their methods, gates) · `inventory.md` (scope) ·
`environment.md` (hosts, toolchain, contention) · `baseline/README.md` (which baseline numbers were
wrong and why).

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

## What to do next, in order

1. **Read `AUDIT/ledger.md` first**, then this page. The ledger carries each task's evidence and the
   `notes` field carries what the fixer learned that the title does not.
2. **Run `AUDIT/verify-done-commits.sh`** — it must exit 0 before anything is called DONE. It backs
   each DONE task against its own commit and *skips* the ones that name no source path (A06, A12,
   A13, A79 …) rather than passing them silently.
3. **Fix Wave 8 serially** (one Swift lane at a time — A87) **and Wave 9 in parallel**. Same rules:
   one task = one commit with an **explicit pathspec** (`git commit -F - -- <paths>`), never a bare
   `git commit`; never weaken a check; new tests must be shown to fail without the fix.
4. **Then Phase E**, which is scripted: **`AUDIT/phase-e.sh`** performs twelve checks and writes its
   logs and `summary.txt` into `AUDIT/baseline/phaseE/`. It exits non-zero if any gate fails, so a
   green exit *is* the acceptance statement. It resolves its own root, assumes no warm `.build`, no
   `models/`, no `.secrets.env`, never echoes a secret, and is bash-3.2-clean.
5. **Phase E must run on `node1`** (a Mac that did **not** develop the fixes), from a fresh clone of
   the pushed branch — per §1b. Access is `ssh node1@node1.local`, key auth. Previous runs used
   `~/chatbots-audit/`; **clean up everything written there afterwards** and record it in
   `environment.md` (the last run removed 2.5 GB and left no residue).
6. **Then sync the wiki tracker** (`ChatBots.wiki/Audit-tracker.md`, its own repository on `master`)
   whose tables are generated from `ledger.json` — do not hand-edit them.
7. **The goal is complete when the ledger has no task that is not DONE or BLOCKED-with-owner, and
   `phase-e.sh` exits 0 on the fresh clone.**

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
- **`main` must stay untouched.** The audit's deliverable is the branch plus `AUDIT/`.
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
