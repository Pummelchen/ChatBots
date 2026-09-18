# Baseline — regression yardstick (primary host `Node1.local`)

One baseline, on the primary host. Recorded before any fix. Command of record:

```
bash tools/mac-checks.sh        # the 8 Mac gates, exit 0
```

## Mac gates (baseline)

| Gate | Baseline result |
| --- | --- |
| 1. file sizes | PASS — every tracked code file ≤ 500 lines |
| 2. build | PASS — `swift build --build-tests`, warnings-as-errors in `Package.swift` |
| 3. tests | PASS — **1048 tests in 195 suites** (1012 + 36), 0 failures, 0 skips |
| 4. coverage | TOTAL lines **52.12%** (9858/20588), functions 57.27%, regions 60.32%. No floor is enforced. |
| 5. swiftlint | **215 findings**, within the recorded waiver of 217 |
| 6. swift-format | **439 diagnostics**, within the recorded waiver of 444 |
| 7. web rules | PASS — deltas merge 34 cases, verdict rule 12 cases |
| 8. identity | PASS — `1.0` is stated once and agrees everywhere |

## Other language gates (baseline)

| Check | Command | Baseline |
| --- | --- | --- |
| Shell lint | `git ls-files -z '*.sh' \| xargs -0 shellcheck -S style` | clean |
| Python lint | `ruff check tools/` | clean (default rule set only — see AUDIT-0030) |
| Python format | `ruff format --check tools/` | clean |
| Python types | `pyright tools/` | 0 errors, 0 warnings |
| Python parse | `python3 -m py_compile tools/*.py` | clean |
| Secrets (full history) | `gitleaks git --log-opts=--all --redact --no-banner` | **534 commits scanned, no leaks found** |
| Dependencies | `osv-scanner scan source --lockfile Package.resolved` | 14 packages, **no issues** |

## Language standard actually in force

| Fact | Value | Evidence |
| --- | --- | --- |
| `SWIFT_VERSION` | Swift 6 language mode | `Package.swift`: `.swiftLanguageMode(.v6)` on every owned target |
| strict concurrency | complete | implied by Swift 6 mode; **proven** by the probe in `AUDIT/probes/` failing the build |
| warnings as errors | yes | `Package.swift`: `.treatAllWarnings(as: .error)` on every owned target |
| compiler | Apple Swift 6.4 (Xcode 27.0) | `swift --version`, `xcodebuild -version` — see `AUDIT/environment.md` |
| C standard | n/a | no C/ObjC/C++ source exists in the repository |
| SwiftLint / swift-format `--strict` | **not** in force | mac-checks compares counts against `tools/analysis-waivers.txt` — AUDIT-0029 |
| `force_unwrapping` SwiftLint rule | **not** enabled | no `opt_in_rules` in `.swiftlint.yml` — AUDIT-0029; 32 findings appear when it is turned on |

## swiftlint baseline by rule (215)

```
112 line_length          22 cyclomatic_complexity   15 closure_parameter_position
 14 optional_data_string_conversion                    12 trailing_comma
 11 identifier_name       9 function_body_length        4 statement_position
  3 large_tuple           3 function_parameter_count    3 for_where
  2 comment_spacing       1 vertical_whitespace         1 type_body_length
  1 redundant_void_return 1 redundant_sendable         1 prefer_type_checking
```

## No later state may be worse on any metric without a justified numbered task

This file is the comparison point for every TEST/AUDIT gate and for Phase E.
