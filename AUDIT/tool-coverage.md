# Tool-coverage and language-standard proofs

Required by §1 before any human check is delegated to a tool, and for each language
standard. A tool that stays silent does not cover the check. Scratch probes live in
`AUDIT/probes/` and are committed.

## Language-standard proofs

### Swift — Swift 6 language mode, complete strict concurrency, warnings as errors

**Probe:** `AUDIT/probes/strict-concurrency-probe.swift` — a non-Sendable value captured
across a Task/actor boundary.

**How it was run** (a SwiftPM target carrying exactly the settings `Package.swift` uses):

```
// Package.swift of the scratch probe package
swiftSettings: [.swiftLanguageMode(.v6), .treatAllWarnings(as: .error)]

swift build
```

**Result (build FAILS, which is the standard being in force):**

```
error: sending 'item' risks causing data races [#RegionIsolation::SendingRisksDataRace]
.../Probe.swift:14:15: error: sending 'item' risks causing data races
error: Build failed
```

The first version of the probe (a `Task { item.value += 1 }` with the value not used
afterwards) **compiled clean**: Swift 6 region-based isolation legitimately permits
sending a disconnected non-Sendable value. The committed probe uses a `Task.detached`
that sends the value to a `@MainActor` function, which region isolation cannot discharge.
Recorded so the difference is not mistaken for a hole in the standard.

`SWIFT_STRICT_CONCURRENCY` is not a separate SwiftPM setting: the Swift 6 language mode
implies complete concurrency checking, and the proof above is that the mode is in force.

### Swift — force-unwrap must fail SwiftLint `--strict`

**Status: proof pending the AUDIT-0029 fix.** `.swiftlint.yml` has no `opt_in_rules`, so
`force_unwrapping` is not enabled today and SwiftLint is silent on a force unwrap.
Measured with a scratch config that enables it: **32 findings** in the authored
`Sources`/`Tests`. The rule will be enabled and the site fixed under AUDIT-0029, and this
section will carry the failing output once it is.

### C — strict C99

**Not applicable.** `git ls-files` finds no `.c`, `.h`, `.m`, `.mm`, `.cpp` or `.hpp`
file in the repository. The C99 standard, its warning flags, ASan/UBSan and the
"native-memory modules are Tier A" rule have no targets. The native-interop seams that do
exist are Swift→POSIX and Swift→WebTransport, audited as Swift Tier A.

### Python — Ruff must reject the named pitfalls

**Probe:** `AUDIT/probes/bare-except-probe.py` (bare `except:` swallowing a failure).

```
$ ruff check AUDIT/probes/bare-except-probe.py
E722 Do not use bare `except`
S110 `try`-`except`-`pass` detected, consider logging the exception
Found 2 errors.
```

Bare `except:` (**E722**) is covered by Ruff's default rule set. The remaining pitfalls
the brief names map as follows, and the ones with a rule are enabled under AUDIT-0030:

| Pitfall | Rule that catches it | Covered today? |
| --- | --- | --- |
| bare `except:` / `except Exception: pass` | E722, S110 | yes (proof above) |
| mutable default argument `def f(x=[])` | B006 | no — enabled under AUDIT-0030 |
| `assert` used for validation | S101 | no — enabled under AUDIT-0030 |
| pytest style / tests that assert nothing | PT | no — enabled under AUDIT-0030 |
| `datetime.now()`/`utcnow()` without a timezone | DTZ | no — enabled under AUDIT-0030 |
| `open()` without `encoding=` | PLW1514 | no — enabled under AUDIT-0030 |
| `is` compared against an int/string | F632 | yes (flake8 F, default) |
| `subprocess` without `check=True` | **no rule exists** | kept as a human check (below) |
| `time.sleep()` used to synchronize | **no rule exists** | kept as a human check (below) |
| hardcoded paths / cwd dependence | **no rule exists** | kept as a human check (below) |
| test order dependence / shared module state | **no rule exists** | kept as a human check (below) |

### Shell — shellcheck

`git ls-files -z '*.sh' | xargs -0 shellcheck -S style` is clean at baseline and is part
of CI. No separate proof is needed: the check is scoped by `-S style` and the baseline run
above is its output. A no-op script with an unquoted variable was used to confirm the gate
can fail (see `AUDIT/probes/shellcheck-probe.sh` and below).

## Checks a tool does not cover (kept as human checks)

These were delegated to nothing because no configured tool catches them; they are audited
by reading, not by a scanner:

- `subprocess` without `check=True` — grep-audited across `tools/**/*.py`.
- `time.sleep()` as synchronization — grep-audited across `tools/**/*.py`.
- tests that assert nothing / test order dependence — read in the Tier A test files.
- hardcoded paths and cwd dependence — read in `tools/*.sh` and `tools/*.py`.

## Tool-coverage per language

| Language | Formatter | Linter | Dep/CVE | Type checker | SAST | Memory/sanitizer |
| --- | --- | --- | --- | --- | --- | --- |
| Swift | swift-format 603.0.0 (config committed) | SwiftLint 0.65.1 (config committed) | osv-scanner 2.6.0 | swiftc 6.4 (proven in force) | semgrep 1.176.0 | `swift test --sanitize=thread` |
| Python | ruff format 0.16.7 | ruff check 0.16.7 | pip-audit — **no requirements/lock file exists**, so nothing to scan | dropped per brief | semgrep 1.176.0 | n/a |
| Shell | (none installed) | shellcheck 0.11.0 | n/a | `bash -n` | semgrep 1.176.0 | n/a |
| JavaScript | pending AUDIT-0031 | pending AUDIT-0031 | no manifest / no dependencies | n/a | semgrep 1.176.0 | n/a |
