# The audit, and where its record is

The September 2026 pre-production audit is **closed**. Every finding it raised is either fixed or
accepted by the owner, and there is no open work here — open work lives in exactly one place, the
[Project Tracker](https://github.com/Pummelchen/ChatBots/wiki/Project-Tracker), per
[`docs/task-table-standard.md`](../docs/task-table-standard.md).

This file used to be a resume point for a run in progress, with a rendered open-work table beside it
in `AUDIT/ledger.md`. Both are gone: the tracker is the wiki page now, and a second table in the
repository contradicted the standard. What is left in this directory is the **record**, not a
backlog:

- **`AUDIT/ledger.json`** — the single source of truth. 107 findings, each with the defect as it was
  found (`evidence_before`), what was done (`fix_summary`), what now proves it (`evidence_after`),
  the closing commit, and for the accepted ones the owner's decision. Read this first.
- **`AUDIT/evidence-*.log`** and **`AUDIT/evidence-*-host.md`** — the raw output behind those claims:
  per-batch gate runs, the Phase D convergence sweep, the session token watched working against a
  live engine, and the independent-host verification.
- **`AUDIT/tool-coverage.md`** — the proof that each configured check is in force, probe by probe.
- **`AUDIT/probes/`** — the deliberately-broken inputs those proofs use.

## How it ended

Four phases, all closed. The findings were drained in severity order S0→S1→S2→S3; the convergence
sweep then re-ran every scanner CI runs and found two gates already red, which are fixed; and the
final gate run was repeated on an independent host at the same commit with the same 1102 tests.

Four findings were **accepted rather than fixed** by the owner on 2026-09-18 — the unauthenticated
`/api` surface reachable from the LAN, the every-interface plaintext default, the DNS-rebinding gap
in the same-origin check, and the limits of the session token added for the fourth. They are stated
for users in `SECURITY.md`, in the 1.1 release notes and in the wiki's
[Accepted limits](https://github.com/Pummelchen/ChatBots/wiki/Accepted-Limits); the options that were
declined are recorded in [`CHANGELOG.md`](../CHANGELOG.md) rather than here, because history does not
live in the tracker.
