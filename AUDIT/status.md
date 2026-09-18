# Audit status — resume point

Read `AUDIT/ledger.json` first: it is the single source of truth. This file is the short
orientation note so a resumed run does not restart discovery.

## Where the run is

- **Phase A — complete and committed** (`fb3cfc3`): inventory and tier table
  (`AUDIT/inventory.md`), environment and language-standard proofs (`AUDIT/environment.md`,
  `AUDIT/tool-coverage.md`), baseline (`AUDIT/baseline.md`), ledger opened.
- **Phase B/C — in progress.** All discovery passes have run (L0-L7 plus the facade sweep);
  the ledger holds every finding. Fixes land in severity order.
- **Phase D/E — not started.**

## Ledger state at the last commit

`done: 13, open: 83, blocked: 0` — S0 0, S1 0, S2 36, S3 47.

The closure invariant is being kept: each milestone report must show a strictly smaller
non-terminal count. It has gone 96 → 90 → 83.

### Closed so far

AUDIT-0001 (S0, /api/device overflow), AUDIT-0002 (S1, model-id path traversal),
AUDIT-0003 (S1, silent save loss), AUDIT-0049 (S1, models-probe SSRF/redirect),
AUDIT-0030 (Python rules), AUDIT-0096 (.gitignore collision), and batch 2:
AUDIT-0050/0051/0052/0054/0055/0046/0048.

## Next actions, in severity order

All S0/S1 are closed. Work the **S2** entries next; they are the ones with real impact.
The highest-value ones still open, roughly in order:

1. AUDIT-0043 — checkpoint-declared context window unvalidated; overflow trap.
2. AUDIT-0058 slowloris / AUDIT-0059 SSE backpressure / AUDIT-0060 DNS-rebinding
   same-origin bypass — the HTTP resource and authz cluster.
3. AUDIT-0012/0013 tool-call budget bypass; AUDIT-0014 fetch_page host validation;
   AUDIT-0015/0016 prompt-injection fencing.
4. AUDIT-0004 image pixel cap; AUDIT-0005 aggregate attachment bound.
5. AUDIT-0011 Tavily redirects; AUDIT-0010 secrets-file mode; AUDIT-0017 history file mode.
6. AUDIT-0029 — the SwiftLint/swift-format `--strict` standard. **This is the largest single
   item** (215 SwiftLint findings: 112 line_length, 22 cyclomatic_complexity, and 32
   force_unwrapping once the rule is enabled). It needs either a large mechanical sweep plus
   refactors, or a documented decision that a specific rule is wrong for this codebase —
   reconfiguring a threshold to make it pass is a §0 violation.
7. AUDIT-0031 — JavaScript has no formatter/linter toolchain at all.
8. AUDIT-0061/0062 and the tools/ shell findings.
9. The web/ and app/ S2 clusters (AUDIT-0070s, AUDIT-0074s).
10. Then the S3 sweep by rule class.

## Phase E is BLOCKED on a second host

The brief requires the final verification on **one independent host**. Only `Node1.local`
exists, and a Swift 6.4 / macOS 26 Apple-Silicon host cannot be provisioned without asking.
No VPS satisfies the Apple-Silicon + macOS 26 floor. **Owner: the repository owner.** What was
tried: enumeration of local hosts and the Docker/VPS option. Options for the owner: (a) provide
a second Mac with Xcode 27 and authorise running `tools/mac-checks.sh` on a fresh clone there;
(b) accept a signed waiver that Phase E is verified on the primary host only, recorded in the
ledger. Until then Phase E is BLOCKED-with-owner, not DONE.

## Conventions in force

- Branch `audit/2026-09-18` only; no force-push, no history rewrite.
- One commit per S0/S1 task; S2/S3 batch by class or by coherent group.
- Every S0/S1 fix carries before/after evidence in `AUDIT/evidence-*.log`.
- Nothing is closed by narrowing scope; new findings get a new id the moment they appear.
