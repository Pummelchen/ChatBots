# AUDIT/baseline — the raw Phase A captures

These are the **raw outputs** of the Phase A baseline run at `main@a6d6999`, kept as evidence
rather than as a summary. Nothing here has been edited. Where a number in these files disagrees
with `AUDIT/plan.md`, **`plan.md` is right and this directory is the historical record** — see
A28 in `ledger.md` for why.

## Read this before quoting a number out of one of these files

A28 found that three of the figures derived from this directory were wrong, and that the cause was
the same each time: **the number was taken from the size of the captured output rather than from the
findings inside it.** The errors ran in both directions, so a reader cannot assume they were
conservative.

| Derived number | Was | Is | Why it was wrong |
| --- | --- | --- | --- |
| shellcheck findings | 24 | **4** | 24 is this directory's `shellcheck.txt` **line count**. A first correction to 7 was also wrong: `grep -oE 'SC[0-9]{4}'` counts the `shellcheck.net/wiki/SCnnnn` help URLs printed under the findings. The current count anchors on the `SCnnnn (severity):` form. |
| swift-format diagnostics | 29 900 | **3 003** after A06's config; not reproducible before it | 29 904 is the **line count** of `swift-format-lint.txt`, which is 2.8 MB. |
| test-target warning sites | 5 | **8** | `test-warnings.txt` is not merely miscounted, it is **lossy**: the capturing grep cut multi-line diagnostics, so the file has 5 lines for 8 warning sites and cannot be re-derived from itself. |
| force unwraps in `Sources/` | "two … not a task" | **12** `!` sites | A review counted them by hand and signed off clean. Not a baseline file at all — recorded here because it is the same failure and it was the most misleading of the four, since it read as reassurance. |
| `swiftlint` findings | 401 | 222 after A06's config | The count was right but the scope was never written down: an **unscoped** `swiftlint lint` also walks `.build/checkouts` and reports ~37 000. A06's config excludes `.build`, so the two now agree. |

The figures that reproduce exactly, and can be quoted straight from these files: **`ruff check`
11**, **`pyright` 2**, **`semgrep` 3**, **`gitleaks` 0**, **`try?` 72 across 23 files**, and the
whole-suite sanitizer results.

## What each file is

| File | What it holds |
| --- | --- |
| `swift-build-debug.log`, `swift-build-release.log` | product builds, 0 warnings and 0 errors each |
| `swift-test.log` | 555 tests in 77 suites passing |
| `swift-test-asan.log`, `swift-test-tsan.log`, `swift-test-tsan-after.log` | the sanitizer pair behind A12/A13/A14: AddressSanitizer clean; ThreadSanitizer reported a race before the fix and none after, while the plain suite passed both times |
| `coverage-sources.txt` | `llvm-cov` over `Sources/`: 71.6 % lines, 70.0 % functions |
| `swiftlint.json`, `swift-format-lint.txt` | the style baselines, superseded by A06's configs and the waivers in `plan.md` |
| `shellcheck.txt`, `ruff-check.txt`, `ruff-format.txt`, `pyright.json` | the linter and type-checker captures |
| `gitleaks.json`, `gitleaks.txt` | the full-history secret scan: **0 findings**. The JSON is read as a count only; no value from it is ever echoed. |
| `osv-scanner.txt` | dependency vulnerabilities: none found |
| `semgrep.json` | 3 SAST findings, all in `tools/cdp.py` (A09) |
| `test-warnings.txt` | **lossy** — see the table above |
| `run.log` | the installer/start script's own log from the baseline run |

## Repo weight, stated plainly

`swift-format-lint.txt` is 2.8 MB and about 70 % of this directory, and the number it was used to
derive was wrong. It is kept because it is the capture the baseline claim rests on and deleting
evidence to save space would be the wrong trade; A06's configs now make it reproducible at any
time, and `AUDIT/phase-e.sh` regenerates fresh logs into `baseline/phaseE/` rather than editing
these.
