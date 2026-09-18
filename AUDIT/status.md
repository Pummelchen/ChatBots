# Audit status — resume point

Read `AUDIT/ledger.json` first: it is the single source of truth. `AUDIT/ledger.md` is the
open-work tracker rendered from it, and it is the file to read for what is left. This note is
only the orientation a resumed run needs, so it does not repeat either.

## Where the run is

- **Phase A — complete and committed** (`fb3cfc3`): inventory and tier table, environment and
  language-standard proofs, baseline, ledger opened.
- **Phase B/C — drained except one S2.** All discovery passes have run (L0-L7 plus the facade
  sweep); every S0, S1 and S3 is closed. `AUDIT-0029` is the last open task.
- **Phase D — recorded as AUDIT-0104 and not yet run.** The tree is frozen; the sweep is the next step.
- **Phase E — recorded as AUDIT-0105, BLOCKED with the repository owner as owner.** It needs a second host (below).

## Ledger state at the last commit

`done: 99, open: 1, blocked: 5` — S0 0, S1 0, S2 2, S3 0. The one open task is Phase D
(AUDIT-0104); the five blocked are the four security decisions plus Phase E (AUDIT-0105).

The closure invariant holds: the non-terminal count fell at every milestone report, from 96 at
the start to 1 now.

## The one open task: AUDIT-0029, now only AUDIT-0099

Replace the recorded waivers in `tools/analysis-waivers.txt` with `--strict`. It was split on the
record — not narrowed — into:

- **AUDIT-0097** (DONE): `force_unwrapping` enabled in `.swiftlint.yml` and its 32 sites removed.
  The waivers were tightened with it, from 217/444 to 208/307.
- **AUDIT-0098** (DONE): `line_length` — all 88 lines wrapped.
- **AUDIT-0099** the only thing left. SwiftLint is down to 13 findings from 32 at the round's
  start: the CLI/probe and the HTTP/OpenAI/Engine groups are done. A final pass covers the rest —
  Conversation (`ConflictState.apply` 22, `ConflictReader`), Research (`ResearchReading.read` 17),
  Room (`SocialPersonas` 14), Transport (`TransportCheck.run` 18, `WebTransportClientReader` 18 and
  13, `WebTransportServerSession` 14) and App (`ChatController` 15, `APIEndpointsSheet`). Then
  AUDIT-0102 switches both gates to `--strict` and deletes the waiver counts.
- **AUDIT-0100** (DONE): the mechanical rule classes.
- **AUDIT-0101** (DONE): the swift-format sweep — 444 → 0.
- **AUDIT-0102** switch both gates to `--strict`, delete the two waiver counts, and delete the
  waiver file if nothing else needs it.

Reconfiguring a threshold to pass would be a §0 violation, so these are real edits or real
refactors, not a waiver bump.

## Awaiting an owner decision (4)

`AUDIT-0018`, `AUDIT-0058`, `AUDIT-0071` and `AUDIT-0077` — the LAN-trust model, the engine's
identity on 7790, DNS rebinding, and the default Caddy bind. Each carries its owner, the
situation and the options in `AUDIT/ledger.md` and in the JSON.

## Phase E is blocked on a second host

The brief requires the final verification on **one independent host**. Only `Node1.local` exists,
and a Swift 6.4 / macOS 26 Apple-Silicon host cannot be provisioned without asking; no VPS meets
the floor. **Owner: the repository owner.** Options: (a) provide a second Mac with Xcode 27 and
authorise a fresh-clone `tools/mac-checks.sh` there; (b) accept a signed waiver that Phase E is
verified on the primary host only, recorded in the ledger.

## Conventions in force

- Branch `audit/2026-09-18` only; no force-push, no history rewrite.
- `bash tools/mac-checks.sh` is the gate after every batch — **9 gates**, including eslint and
  prettier (`npm ci` first). Metrics must not regress: both style gates run `--strict` against zero (SwiftLint 0, swift-format 0);
no waiver caps remain. Previously:
  swift-format ≤ 2 (measured 0), no file over 500 lines.
- Every fix carries before/after evidence in `AUDIT/evidence-*.log`, and the closed record —
  what was found, what was changed, which commit — is in `AUDIT/ledger.json`.
- `python3 tools/embed-web.py` must be re-run whenever `web/` changes.
- Nothing is closed by narrowing scope; new findings get a new id immediately.
