# The runs before the one at the top level

The top level of this directory is the acceptance run: a fresh clone of the branch head on `node2`,
every section of `AUDIT/phase-e.sh` green. Two earlier runs are kept here because each one stopped
for a reason worth recording rather than overwriting.

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
verified the merge of `main` into the branch. The acceptance was then run a third time because the
ledger gained one more task (A218) while the acceptance record was being written — the ledger is part
of what Phase E checks — so the top level, not this directory, is the statement for the head.
