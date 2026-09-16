# The runs before the one at the top level

The top level of this directory is the acceptance run: a fresh clone of the branch head on `node2`,
every section of `AUDIT/phase-e.sh` green. The runs below are kept because each one is part of the
record — one stopped for a reason worth naming, and three were superseded when the ledger changed.

## `1-pyright-missing/` — 22 passed, 1 failed

The first run, from a fresh clone of the merge commit `686bf70`. Everything passed except

```
FAIL|pyright is not installed
```

which is the verification host rather than the tree: `node2` had never had `pyright`. It was installed
at the version the audit records (`npm install --global pyright@1.1.414`, which reports
`pyright 1.1.414`) and the acceptance was run again.

## `2-merge-commit-686bf70/` — 23 passed, 0 failed

The run after that install, from a new clone of the same commit. Green, and it is the run that
verified the merge of `main` into the branch.

## `3-commit-e5ce7851/` — 23 passed, 0 failed

Green on the head that carried the first acceptance record, at 218 tasks. It was superseded, not
overturned: the ledger then gained its last task (A219, the two instruction documents `main` had added
mid-audit), and the ledger is part of what Phase E checks — sections 10 and 11 count tasks, check every
DONE task against a commit, and require none open. So the acceptance was run again on the head that
contains it, and the top level is that run.

## `4-commit-7ed87f55/` — 23 passed, 0 failed

Green at 219 tasks, the head that carried the acceptance for the audit's landing (pull request #10).
It was superseded the same way as the one before it: A220 — the ship-decision guard's failure message
and the boundary in `RELEASE.md` §1.3 — changed the ledger again, so the acceptance was run once more
for the head that the follow-up pull request merges.
