# Audit status — resume point

Read `AUDIT/ledger.json` first: it is the single source of truth. `AUDIT/ledger.md` is the
open-work tracker rendered from it, and it is the file to read for what is left. This note is
only the orientation a resumed run needs, so it does not repeat either.

## Where the run is

- **Phase A — complete and committed** (`fb3cfc3`): inventory and tier table, environment and
  language-standard proofs, baseline, ledger opened.
- **Phase B/C — drained except one S2.** All discovery passes have run (L0-L7 plus the facade
  sweep); every S0, S1 and S3 is closed. `AUDIT-0029` is the last open task.
- **Phase D/E — not started.** Phase E needs a second host (below).

## Ledger state at the last commit

`done: 92, open: 1, blocked: 4` — S0 0, S1 0, S2 1, S3 0.

The closure invariant holds: the non-terminal count fell at every milestone report, from 96 at
the start to 1 now.

## The one open task: AUDIT-0029

Replace the recorded waivers in `tools/analysis-waivers.txt` with `--strict`. It was split on the
record — not narrowed — into:

- **AUDIT-0097** (DONE): `force_unwrapping` enabled in `.swiftlint.yml` and its 32 sites removed.
  The waivers were tightened with it, from 217/444 to 208/307.
- **AUDIT-0098** `line_length` — 113 findings, mostly prose string literals.
- **AUDIT-0099** the complexity refactors — 22 `cyclomatic_complexity`, 9 `function_body_length`.
- **AUDIT-0100** the remaining rule classes — `closure_parameter_position`,
  `optional_data_string_conversion`, `trailing_comma`, `identifier_name`, and a small tail.
- **AUDIT-0101** the swift-format residual — 306 diagnostics today, down from 444.
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
  prettier (`npm ci` first). Metrics must not regress: SwiftLint ≤ 208 (measured 206),
  swift-format ≤ 307 (measured 306), no file over 500 lines.
- Every fix carries before/after evidence in `AUDIT/evidence-*.log`, and the closed record —
  what was found, what was changed, which commit — is in `AUDIT/ledger.json`.
- `python3 tools/embed-web.py` must be re-run whenever `web/` changes.
- Nothing is closed by narrowing scope; new findings get a new id immediately.
