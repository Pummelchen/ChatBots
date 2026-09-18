# Audit status — resume point

Read `AUDIT/ledger.json` first: it is the single source of truth. This file is the short
orientation note so a resumed run does not restart discovery.

## Where the run is

- **Phase A — complete and committed** (`fb3cfc3`): inventory and tier table, environment
  and language-standard proofs, baseline, ledger opened.
- **Phase B/C — nearly drained.** All discovery passes have run (L0-L7 plus the facade
  sweep); every S0, S1 and all but one S2 are closed. The S3 sweep remains.
- **Phase D/E — not started.**

## Ledger state at the last commit

`done: 71, open: 22, blocked: 4` — S0 0, S1 0, S2 1, S3 21.

The closure invariant holds: non-terminal count has gone 96 → 90 → 83 → 76 → 71 → 66 →
62 → 59 → 58 → 56 → 54 → 51 → 50 → 49 → 48 → 43 → 40 → 36 → 33 → 31 → 25 → 22 across the
milestone reports.

## The one remaining S2

**AUDIT-0029 — SwiftLint/swift-format `--strict`, and `force_unwrapping`.** The gates are
enforced against recorded waiver counts in `tools/analysis-waivers.txt` (208/307, tightened from 217/444), and
`.swiftlint.yml` has no `opt_in_rules`, so `force_unwrapping` never fires. Closing it needs:

1. ~~Enable `force_unwrapping` and fix the 32 sites~~ — DONE as AUDIT-0097, which also
tightened the waivers from 217/444 to 211/413 (measured 209/411).
2. Then drive SwiftLint to zero so `--strict` can be turned on. Measured now: 113
   `line_length` (mostly prose string literals), 22 `cyclomatic_complexity`, 15
   `closure_parameter_position`, 14 `optional_data_string_conversion`, 11 `trailing_comma`,
   11 `identifier_name`, 9 `function_body_length`, and a tail of small classes.
   Reconfiguring a threshold to pass would be a §0 violation, so these are real edits or
   real refactors.
3. The same for swift-format's 439 diagnostics (`--strict` is what the brief names).

Because this is much larger than one task, split it into sub-tasks the moment work starts,
each with its own id, and note on AUDIT-0029 that its scope was split rather than narrowed.

## The S3 sweep (21)

All are style/formatting/test-quality. They are resolved as rule-class sweeps through the
formatter/linter, one commit per class, with no test and no cold re-read (§8). The
`tools/analysis-waivers.txt` counts are the tracker: each class swept reduces them toward
zero, and the waiver file is deleted when it reaches zero.

## BLOCKED-with-owner (4)

- AUDIT-0018 — `/api` has no authentication; deliberate LAN-trust design.
- AUDIT-0077 — Caddy binds every interface by default; same decision.
- AUDIT-0071 — DNS rebinding defeats the same-origin check; needs auth or a Host allow-list.
- AUDIT-0058 — the app adopts any process on 7790 and sends it Keychain keys.

Each carries the owner, the reason, what was tried and 2+ options in the ledger.

## Phase E is BLOCKED on a second host

The brief requires the final verification on **one independent host**. Only `Node1.local`
exists, and a Swift 6.4 / macOS 26 Apple-Silicon host cannot be provisioned without asking.
No VPS satisfies the Apple-Silicon + macOS 26 floor. **Owner: the repository owner.**
Options: (a) provide a second Mac with Xcode 27 and authorise a fresh-clone
`tools/mac-checks.sh` there; (b) accept a signed waiver that Phase E is verified on the
primary host only, recorded in the ledger.

## Conventions in force

- Branch `audit/2026-09-18` only; no force-push, no history rewrite.
- One commit per S0/S1 task; S2/S3 batch by class or coherent group (batches 10-18 done:
  endpoint rebuild, reader generation, SSE line cap, JS toolchain, force_unwrapping, HTTP
  reasons and header CR/LF, shell traps, CLI exit codes, /api/seat validation and ordering,
  the event feed's high-water mark, CLI flag refusal, the Tavily answer/retry-cost/body cap,
  the runtime-directory docs, the vision markers, the desktop profiles, the attachment reads,
  and three tool-script bounds). The remaining S3 classes are the transport (0034-0045), the
  SwiftUI app (0063-0068), the remaining tools (0079, 0082), and the web front end (0091).
- Every fix carries before/after evidence in `AUDIT/evidence-*.log`.
- `bash tools/mac-checks.sh` is the gate after every batch — now **9 gates**, including
  eslint and prettier (`npm ci` first). Metrics must not regress: SwiftLint ≤ 217
  (now 215), swift-format ≤ 444 (now 439), no file over 500 lines.
- `python3 tools/embed-web.py` must be re-run whenever `web/` changes.
- Nothing is closed by narrowing scope; new findings get a new id immediately.
