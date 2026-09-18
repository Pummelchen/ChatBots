# Audit status — resume point

Read `AUDIT/ledger.json` first: it is the single source of truth. This file is the short
orientation note so a resumed run does not restart discovery.

## Where the run is

- **Phase A — complete and committed** (`fb3cfc3`): inventory and tier table,
  environment and language-standard proofs, baseline, ledger opened.
- **Phase B/C — in progress.** All discovery passes have run (L0-L7 plus the facade
  sweep); the ledger holds every finding. Fixes land in severity order.
- **Phase D/E — not started.**

## Ledger state at the last commit

`done: 38, open: 58, blocked: 0` — S0 0, S1 0, S2 11, S3 47.

The closure invariant holds: non-terminal count has gone 96 → 90 → 83 → 76 → 71 → 66 →
62 → 59 → 58 across the milestone reports.

### Closed

S0/S1: AUDIT-0001 (device-resolver overflow), AUDIT-0002 (model-id traversal),
AUDIT-0003 (silent save loss), AUDIT-0049 (models-probe SSRF).

S2: AUDIT-0004 (image pixel cap), 0005 (attachment total bound), 0006 (transcript
forgery), 0007/0008 (store recovery), 0009 (models dir), 0010 (.secrets mode),
0011 (Tavily redirects), 0012 (search budget), 0013 (tool-call cap), 0014 (fetch_page
SSRF), 0015 (tool-result fencing), 0016 (synthesis fence), 0017 (history mode),
0030 (Python rules), 0043 (context window overflow), 0049, 0050 (link-local spellings),
0051 (trace off), 0052 (trace URL), 0054 (compat host), 0055 (base URL query),
0056 (unreadable SSE), 0059 (refusal), 0060 (cancellation),
0061 (main-thread read), 0062 (launcher), 0078 (release gate), 0088 (follow),
0089 (topic order), 0090 (Cmd+Enter), 0096 (.gitignore).

## Next actions, in severity order

All S0/S1 are closed. The **eleven remaining S2** entries:

1. **AUDIT-0029** — SwiftLint/swift-format `--strict` and `force_unwrapping`. The largest
   single item (215 SwiftLint findings: 112 line_length, 22 cyclomatic_complexity, 32
   force_unwrapping once enabled). Needs a real sweep/refactor; reconfiguring a threshold
   to pass is a §0 violation.
2. **AUDIT-0031** — JavaScript has no committed formatter or linter and no pinned toolchain.
3. **AUDIT-0069** — slowloris: the idle deadline is re-armed by any chunk, no total-request
   deadline.
4. **AUDIT-0070** — SSE has no backpressure and no idle deadline.
5. **AUDIT-0071** — the same-origin check trusts Origin against Host, so DNS rebinding
   defeats it.
6. **AUDIT-0053** — SSE line buffering is unbounded before the 600-character cap.
7. **AUDIT-0033** — the transport client cancels but never awaits the old reader, which can
   poison the new session.
8. **AUDIT-0057** — a seat baseURL/apiKey change is reported but never reaches the live
   client (facade).
9. **AUDIT-0058** — the app adopts any process answering on 7790 and hands it Keychain keys.
10. **AUDIT-0077** and **AUDIT-0018** — the shipped default publishes the unauthenticated
    site/API on every interface, and `/api/*` has no authn. Both are documented as
    deliberate; they need an explicit owner sign-off or a design change, so they will most
    likely become BLOCKED(owner) with the options written down.

Then the S3 sweep by rule class (47 entries).

## Phase E is BLOCKED on a second host

The brief requires the final verification on **one independent host**. Only `Node1.local`
exists, and a Swift 6.4 / macOS 26 Apple-Silicon host cannot be provisioned without asking.
No VPS satisfies the Apple-Silicon + macOS 26 floor. **Owner: the repository owner.**
Options: (a) provide a second Mac with Xcode 27 and authorise a fresh-clone
`tools/mac-checks.sh` there; (b) accept a signed waiver that Phase E is verified on the
primary host only, recorded in the ledger. Until then Phase E is BLOCKED-with-owner.

## Conventions in force

- Branch `audit/2026-09-18` only; no force-push, no history rewrite.
- One commit per S0/S1 task; S2/S3 batch by class or coherent group.
- Every fix carries before/after evidence in `AUDIT/evidence-*.log`.
- `bash tools/mac-checks.sh` is the gate after every batch; SwiftLint must stay ≤ 217
  (currently 215) and swift-format ≤ 444 (currently 439).
- `python3 tools/embed-web.py` must be re-run whenever `web/` changes.
- Nothing is closed by narrowing scope; new findings get a new id immediately.
