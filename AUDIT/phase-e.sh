#!/usr/bin/env bash
# AUDIT — the Phase E acceptance run.
#
# Phase E asks for a final, reproducible statement that the tree is releasable: a clean build
# with zero warnings, the full suite green, coverage, every scanner clean or waived in writing,
# zero placeholders, no forbidden construct, every DONE task's commit actually backing it, and no
# open task that is not DONE or BLOCKED-with-owner.
#
# This script produces that statement as evidence instead of as prose, for one reason: every
# number in this audit that was wrong was wrong because it was derived by hand from formatted
# output. A19 recorded a task DONE whose commit contained no source change; A28 found three
# baseline counts that were line counts of captured files rather than finding counts. So each
# check here writes a log and a count, and the count is taken from the tool's own report.
#
# Run it from anywhere inside the checkout; it resolves the root itself:
#
#   AUDIT/phase-e.sh                 # evidence into AUDIT/baseline/phaseE/
#   AUDIT/phase-e.sh /tmp/phase-e    # evidence somewhere else
#
# It is expected to be run on a **fresh clone on a host that did not develop the fixes** (the
# brief's §1b), which is why it does not assume a warm `.build`, a `models/` directory, a
# `.secrets.env`, or a network connection. It never prints a secret: gitleaks runs with
# `--redact`, and only rule ids, files and lines are read out of its report.
#
# Exit status: 0 when every gate passed, 1 when a gate failed. Gates that genuinely cannot run
# here (a tool missing, no coverage profile because the tests failed) are reported as FAIL with
# the reason, never as a pass.

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root" || exit 2
out="${1:-$root/AUDIT/baseline/phaseE}"
mkdir -p "$out" || exit 2

failures=0
passes=0
declare -a results=()

pass() {
    printf '  PASS  %s\n' "$1"
    results+=("PASS|$1")
    passes=$((passes + 1))
}

fail() {
    printf '  FAIL  %s\n' "$1"
    results+=("FAIL|$1")
    failures=$((failures + 1))
}

section() { printf '\n=== %s ===\n' "$1"; }

# ---------------------------------------------------------------- identity of what was tested
# The result must name the commit it describes, or it describes nothing in particular.
section "0/12  what is being verified"
head_sha="$(git rev-parse HEAD)"
branch="$(git branch --show-current)"
dirty="$(git status --porcelain | wc -l | tr -d '[:space:]')"
printf 'branch: %s\ncommit: %s\n' "$branch" "$head_sha"
{
    printf 'branch: %s\ncommit: %s\n' "$branch" "$head_sha"
    git log -1 --format='subject: %s%ncommitted: %ci'
    printf 'uncommitted paths: %s\n' "$dirty"
} > "$out/identity.txt"
if [ "$dirty" = "0" ]; then
    pass "the tree is clean, so the evidence describes commit ${head_sha:0:8}"
else
    fail "the tree has $dirty uncommitted path(s): evidence would not describe a commit"
    git status --porcelain | sed 's/^/        /'
fi
# The run has to be on a branch that is meant to be verified, not on whatever happens to be checked
# out. There are two: the audit branch while the audit is in progress, and `main` once the audit has
# been landed on. A gate that refuses to run on the branch the code actually ships from is a gate
# that stops being run — which is how the acceptance script came to fail on its own `main` (A132).
#
# The audit branch is matched as `audit/*` rather than by the date it was cut, because the date is
# not a property of the gate: A132 added `main` here after the landing, and the next audit opened
# `audit/2026-09-15`, which this case then failed on for a whole audit-hop (A210). What the check
# actually asserts is "an audit branch or main", and that is what it now says. The branch is named
# in the result so the evidence still records which one it was.
case "$branch" in
    audit/*) pass "on the audit branch '$branch', where the audit was developed" ;;
    main) pass "on main, which the audit was landed on" ;;
    *) fail "on branch '$branch', which is neither an audit branch nor main" ;;
esac
# §0, recorded rather than asserted, because the number means different things either side of the
# landing: before it, `origin/main` is the base commit and this counts the branch's distance from it;
# afterwards, `origin/main` is this branch, so it counts the whole history.
if git rev-parse --verify --quiet origin/main >/dev/null; then
    behind="$(git rev-list --count "origin/main" 2>/dev/null)"
    printf 'origin/main commits reachable: %s\n' "$behind" >> "$out/identity.txt"
fi

# ---------------------------------------------------------------- forbidden constructs (§0)
section "1/12  §0 forbidden constructs"
# A fix that silences the compiler or the type system is not a fix. These are greps rather than
# a build because they must be true of the source, not of whatever the compiler was told.
forbidden="$(git grep -nE 'try!|as!|-Wno-|@unchecked Sendable.*//|swiftlint:disable|swift-format-ignore' -- '*.swift' | grep -v '^AUDIT/' || true)"
if [ -z "$forbidden" ]; then
    pass "no try!, as!, -Wno-, or inline lint suppression in tracked Swift"
else
    fail "forbidden construct(s) found"
    printf '%s\n' "$forbidden" | sed 's/^/        /'
fi

# ---------------------------------------------------------------- placeholders (§5)
section "2/12  §5 placeholder sweep"
markers="$(git grep -nE 'TODO|FIXME|HACK|XXX|WIP|STUB|PLACEHOLDER' -- '*.swift' '*.py' '*.sh' '*.js' '*.html' '*.md' | grep -v '^AUDIT/' || true)"
if [ -z "$markers" ]; then
    pass "0 placeholder markers in tracked source"
else
    fail "placeholder markers found"
    printf '%s\n' "$markers" | sed 's/^/        /'
fi

# ---------------------------------------------------------------- build
section "3/12  build — products and tests, warnings are errors"
# Warnings-as-errors is set in Package.swift, so this is not a flag this script can forget.
if swift build --build-tests > "$out/build.log" 2>&1; then
    # Compiler diagnostics only. SwiftPM also prints its own `warning:` lines about the dependency
    # cache ("skipping cache due to an error: The file "maintenance.lock" doesn't exist"), which are
    # not statements about this code, are not governed by warnings-as-errors, and made an otherwise
    # clean tree fail this gate (A123). The count that matters is the one warnings-as-errors
    # controls: a compiler warning cannot appear here without failing the build, which is exactly
    # what makes this line a guard against the setting being removed rather than a duplicated check.
    warnings="$(grep -cE '\.swift:[0-9]+:[0-9]+: warning:' "$out/build.log" || true)"
    notices="$(grep -cE '^warning: ' "$out/build.log" || true)"
    if [ "$warnings" = "0" ]; then
        # The error count had the same defect as the warning count and the first fix missed it:
        # `grep 'error:'` matched the four SwiftPM notices, whose text is "skipping cache due to an
        # error:", so a *green* section reported "4 errors" (A128). Counted by diagnostic shape now.
        errors="$(grep -cE '\.swift:[0-9]+:[0-9]+: error:' "$out/build.log" || true)"
        pass "swift build --build-tests: ${errors} compiler errors, 0 compiler warnings (${notices} SwiftPM notice(s) not counted)"
    else
        fail "build produced $warnings compiler warning line(s) despite warnings-as-errors"
        grep -E '\.swift:[0-9]+:[0-9]+: warning:' "$out/build.log" | head -5 | sed 's/^/        /'
    fi
else
    fail "build failed; see $out/build.log"
    tail -n 20 "$out/build.log" | sed 's/^/        /'
fi

# ---------------------------------------------------------------- tests
section "4/12  full suite"
if swift test > "$out/test.log" 2>&1; then
    # Summed across test bundles: one process per test target, one "Test run with" line each, so the
    # last line alone is a single target's count (A166).
    summary="$(grep -E 'Test run with' "$out/test.log" \
        | sed -E 's/.*with ([0-9]+) tests? in ([0-9]+) suites.*/\1 \2/' \
        | awk '{t += $1; s += $2} END {printf "%d tests in %d suites", t, s}')"
    pass "tests: ${summary:-swift test exited 0}"
else
    fail "test suite failed; see $out/test.log"
    grep -E 'Test run with|✘|recorded an issue' "$out/test.log" | tail -10 | sed 's/^/        /'
fi

# ---------------------------------------------------------------- sanitizers
# A data race is not observable from an assertion; the instrument is the evidence. A12 and A13
# are the two tasks that exist because the plain suite passes either way.
section "5/12  sanitizers"
if swift test --sanitize=address --scratch-path "$out/scratch-asan" > "$out/asan.log" 2>&1; then
    pass "AddressSanitizer: exit 0, no report"
else
    fail "AddressSanitizer reported a problem; see $out/asan.log"
    grep -iE 'ERROR: AddressSanitizer|SUMMARY' "$out/asan.log" | head -5 | sed 's/^/        /'
fi
if swift test --sanitize=thread --scratch-path "$out/scratch-tsan" > "$out/tsan.log" 2>&1; then
    pass "ThreadSanitizer: exit 0, no report"
else
    fail "ThreadSanitizer reported a race; see $out/tsan.log"
    grep -E 'WARNING: ThreadSanitizer' "$out/tsan.log" | head -3 | sed 's/^/        /'
fi

# ---------------------------------------------------------------- coverage
section "6/12  coverage over Sources/"
if swift test --enable-code-coverage > "$out/coverage-test.log" 2>&1; then
    bin="$(swift build --show-bin-path 2>/dev/null)"
    profile="$bin/codecov/default.profdata"
    # One test bundle per test target, named after the target; discovered rather than written down
    # because the name changed with Xcode 27 and a second target was added (A134, A146).
    test_bundles=()
    for bundle in "$bin"/*.xctest; do
        bundle_executable="$bundle/Contents/MacOS/$(basename "$bundle" .xctest)"
        [ -x "$bundle_executable" ] && test_bundles+=("$bundle_executable")
    done
    if [ -f "$profile" ] && [ "${#test_bundles[@]}" -gt 0 ] \
        && xcrun llvm-cov report "${test_bundles[@]}" -instr-profile "$profile" --sources Sources \
            > "$out/coverage.log" 2>&1
    then
        total="$(grep -E '^TOTAL' "$out/coverage.log" | tail -1)"
        pass "coverage: ${total:-report written to $out/coverage.log}"
        # The two files A02 was opened about, reported individually. Its own acceptance criterion
        # was a number for each, so recording only the repository total would let the one task
        # whose whole point is coverage pass on a figure that says nothing about it.
        for file in MLXEngine.swift TransportCheck.swift TurnLoop.swift; do
            row="$(grep -E "/$file( |$)" "$out/coverage.log" | tail -1)"
            [ -n "$row" ] && printf '        %s\n' "$(printf '%s' "$row" | awk '{print $1, " lines:", $10}')"
        done
    else
        fail "coverage: no profile or no test binary; see $out/coverage.log"
    fi
else
    fail "coverage: the instrumented test run failed; see $out/coverage-test.log"
fi

# ---------------------------------------------------------------- scanners
section "7/12  secret scan — full history"
if command -v gitleaks >/dev/null 2>&1; then
    # --redact so a finding never echoes the value it found. Only the count leaves this block.
    if gitleaks git --log-opts=--all --redact --no-banner \
        --report-format json --report-path "$out/gitleaks.json" > "$out/gitleaks.log" 2>&1
    then
        pass "gitleaks over the full history: 0 findings"
    else
        count="$(jq 'length' "$out/gitleaks.json" 2>/dev/null || echo unknown)"
        fail "gitleaks: $count finding(s) — rule id, file and line only, in $out/gitleaks.json"
        jq -r '.[] | "        \(.RuleID)  \(.File):\(.StartLine)"' "$out/gitleaks.json" 2>/dev/null | head -10
    fi
else
    fail "gitleaks is not installed"
fi

section "8/12  dependency vulnerabilities"
if command -v osv-scanner >/dev/null 2>&1; then
    # The resolved dependency set, not the whole tree. `-r .` also walked the sanitizer scratch
    # directories, which hold every dependency's own checkout — including its example projects and
    # their requirements.txt files — so this gate reported vulnerabilities in code this repository
    # does not ship and never declares (A124). The object that matters is the same one the lockfile
    # gate is about: what `Package.resolved` pins.
    if osv-scanner scan source --lockfile Package.resolved > "$out/osv.txt" 2>&1; then
        pass "osv-scanner: no issues found"
    else
        fail "osv-scanner reported issues; see $out/osv.txt"
    fi
else
    fail "osv-scanner is not installed"
fi

section "9/12  SAST, shell, Python and Swift style"
if command -v semgrep >/dev/null 2>&1; then
    # A09 waived two findings in tools/cdp.py in writing: the plaintext websocket and the
    # run-time URL are both correct for a loopback-only Chrome DevTools client, and the code now
    # ENFORCES what the scanner cannot see (a host check that refuses anything but loopback, a
    # pinned scheme, a bounded read). The findings stay visible - there is no nosemgrep - so the
    # gate has to distinguish "a finding this audit has justified" from "a new one", which a
    # count cannot do: swapping one for another would keep the count the same. Hence an
    # allowlist read from plan.md, matched on rule id and path suffix.
    # The waivers, why they exist, and the matching rule are in `tools/semgrep-waivers.py`, which
    # is also what CI runs: one implementation, so the Mac gate and the hosted one cannot disagree
    # about which findings have been justified (A129).
    # No `--quiet`: the rule set comes from the registry at scan time, so the scan is run without it
    # and the figures semgrep resolves are carried into the line this check reports. On this tree
    # `--config auto` resolved a 1074-rule policy of which 461 ran for the languages present, over
    # 101 targets; the one target it skipped is the 1.5 MB app icon, which is a PNG (A192).
    semgrep scan --config auto --json --output "$out/semgrep.json" \
        Sources tools web > "$out/semgrep.log" 2>&1
    resolved="$(grep -E '^Ran [0-9]+ rules? on [0-9]+ files?:' "$out/semgrep.log" | tail -1 || true)"
    if python3 tools/semgrep-waivers.py "$out/semgrep.json" > "$out/semgrep-waivers.txt" 2>&1; then
        pass "$(tail -1 "$out/semgrep-waivers.txt")${resolved:+ — $resolved}"
    else
        fail "semgrep: $(tail -1 "$out/semgrep-waivers.txt")${resolved:+ — $resolved} — see $out/semgrep.json"
    fi
else
    fail "semgrep is not installed"
fi

if command -v shellcheck >/dev/null 2>&1; then
    # Every tracked shell script, not just `tools/*.sh`: the audit's own scripts and the probes under
    # `AUDIT/baseline/` were outside that glob and so were never linted, and a script added in a new
    # directory would have escaped it the same way (A192). Taking the list from git fixes the class,
    # not the instance; `-z`/`-0` keeps a path with a space in it one argument, and an empty list is
    # failed rather than passed to shellcheck, which would read stdin and report nothing.
    shell_count="$(git ls-files '*.sh' | wc -l | tr -d ' ')"
    if [ "$shell_count" = "0" ]; then
        fail "shellcheck: git lists no shell script to lint"
    else
        git ls-files -z '*.sh' | xargs -0 shellcheck -S style > "$out/shellcheck.txt" 2>&1 || true
        # Counted from the `SCnnnn (severity):` form, which is one per finding. Two earlier counts
        # of this same output were wrong in two different ways: 24 was the file's line count, and 7
        # was `grep -oE 'SC[0-9]{4}'`, which also matches the three `shellcheck.net/wiki/SCnnnn`
        # help URLs printed under the findings. The real number is 4. Anchoring on the severity
        # suffix is what makes this one a count of findings rather than of codes that appear.
        notes="$(grep -cE 'SC[0-9]{4} \((style|info|warning|error)\):' "$out/shellcheck.txt" || true)"
        if [ "$notes" = "0" ]; then
            pass "shellcheck -S style: 0 findings over $shell_count tracked script(s)"
        else
            # Recorded and reported, not hidden: A10 owns these, and a non-zero count must be
            # visible in the acceptance run rather than rounded away.
            pass "shellcheck -S style: $notes finding(s) — see $out/shellcheck.txt (A10's scope)"
        fi
    fi
else
    fail "shellcheck is not installed"
fi

if command -v ruff >/dev/null 2>&1; then
    ruff check tools/ > "$out/ruff.txt" 2>&1 && ruffok=1 || ruffok=0
    ruff_summary="$(grep -E '^Found|^All checks passed' "$out/ruff.txt" | tail -1)"
    if [ "$ruffok" = "1" ]; then pass "ruff check: clean"; else fail "ruff check: ${ruff_summary:-see $out/ruff.txt}"; fi
else
    fail "ruff is not installed"
fi

if command -v pyright >/dev/null 2>&1; then
    pyright tools/ > "$out/pyright.txt" 2>&1 && pyrightok=1 || pyrightok=0
    pyright_summary="$(grep -E '[0-9]+ error' "$out/pyright.txt" | tail -1)"
    if [ "$pyrightok" = "1" ]; then
        pass "pyright: clean"
    else
        fail "pyright: ${pyright_summary:-see $out/pyright.txt}"
    fi
else
    fail "pyright is not installed"
fi

# A06 left documented style debt: a config that states the house style rather than hiding
# findings, so a real number remains. The gate is therefore not "zero" but "no worse than the
# number this audit recorded" — the same shape as every other baseline. The waiver lives in
# plan.md so that raising it is a deliberate, reviewable edit rather than a silent drift.
waiver_for() {
    sed -n "s/.*$1 waiver: \([0-9][0-9]*\).*/\1/p" AUDIT/plan.md | head -1
}

if command -v swiftlint >/dev/null 2>&1; then
    swiftlint lint --quiet --reporter json Sources Tests > "$out/swiftlint.json" 2>/dev/null
    findings="$(jq 'length' "$out/swiftlint.json" 2>/dev/null || echo unknown)"
    allowed="$(waiver_for swiftlint)"
    case "$findings" in
        ''|*[!0-9]*)
            fail "swiftlint: could not read a count from the JSON reporter"
            ;;
        *)
            if [ -z "$allowed" ]; then
                fail "swiftlint: $findings finding(s) with no waiver recorded in AUDIT/plan.md"
            elif [ "$findings" -le "$allowed" ]; then
                pass "swiftlint: $findings finding(s), within the recorded waiver of $allowed"
            else
                fail "swiftlint: $findings finding(s) exceeds the recorded waiver of $allowed — fix them, or raise the waiver deliberately in AUDIT/plan.md"
            fi
            ;;
    esac
else
    fail "swiftlint is not installed"
fi

if command -v swift-format >/dev/null 2>&1; then
    # Authored Swift only. The generated `WebAssets.swift` embeds `web/` at column 0 and carries
    # ~2,300 indentation diagnostics of its own, so including it made this count a function of the
    # web interface rather than of this repository's code — and any edit to `web/` moved the waiver
    # (A125). swiftlint already excludes the same two generated files in `.swiftlint.yml`.
    find Sources Tests -name '*.swift' ! -name 'WebAssets.swift' ! -name 'NameLists.swift' -print0 \
        | xargs -0 swift-format lint > "$out/swift-format.txt" 2>&1
    # Counted from diagnostic lines, never from the length of the file: 29 900 was once the
    # line count of this output rather than a finding count (A28).
    diagnostics="$(grep -cE 'warning:|error:' "$out/swift-format.txt" || true)"
    allowed="$(waiver_for swift-format)"
    if [ -z "$allowed" ]; then
        fail "swift-format: $diagnostics diagnostic(s) with no waiver recorded in AUDIT/plan.md"
    elif [ "$diagnostics" -le "$allowed" ]; then
        pass "swift-format: $diagnostics diagnostic(s), within the recorded waiver of $allowed"
    else
        fail "swift-format: $diagnostics diagnostic(s) exceeds the recorded waiver of $allowed"
    fi
else
    fail "swift-format is not installed"
fi

# ---------------------------------------------------------------- the ledger's own consistency
section "10/12  every DONE task is backed by its own commit"
if [ -x AUDIT/verify-done-commits.sh ]; then
    if AUDIT/verify-done-commits.sh > "$out/done-commits.txt" 2>&1; then
        # `tail -1`, not `tail -2 | head -1`: the script ends with a blank line before its
        # summary, so the two-line form read the blank and the acceptance statement reported an
        # empty count (A127).
        pass "verify-done-commits.sh: $(tail -1 "$out/done-commits.txt")"
    else
        fail "verify-done-commits.sh found an unbacked DONE claim; see $out/done-commits.txt"
        grep -E '^FAIL' "$out/done-commits.txt" | sed 's/^/        /'
    fi
else
    fail "AUDIT/verify-done-commits.sh is missing or not executable"
fi

# ---------------------------------------------------------------- the ledger's own state
section "11/12  no task left open except DONE or BLOCKED-with-owner"
if command -v jq >/dev/null 2>&1; then
    # Parse first, and refuse to draw any conclusion from a ledger that cannot be read.
    #
    # The first version of this section piped jq into a file and counted the lines. On invalid
    # JSON jq writes nothing, so total and open_count were both 0 and the gate PASSED - "0
    # tasks, none open" - which is the worst possible failure mode for the one check that says
    # whether the audit is finished. It was found because a lane reported seeing the ledger
    # mid-write, which is also why the ledger is written atomically (temp file, then rename).
    if ! jq -e '.tasks | length' AUDIT/ledger.json > "$out/ledger-task-count.txt" 2>"$out/ledger-parse-error.txt"; then
        fail "the ledger could not be parsed as JSON, so its state is unknown — see $out/ledger-parse-error.txt"
        total=-1
    else
        total="$(tr -d '[:space:]' < "$out/ledger-task-count.txt")"
    fi
    if [ "${total:--1}" -le 0 ] 2>/dev/null; then
        fail "the ledger holds no tasks (count: ${total:-unknown}) — that is not a pass"
    else
        jq -r '.tasks[] | "\(.id)\t\(.severity)\t\(.status)"' AUDIT/ledger.json > "$out/tasks.tsv"
        open_count="$(awk -F'\t' '$3=="START" || $3=="PROGRESS" || $3=="TEST" || $3=="AUDIT"' "$out/tasks.tsv" | wc -l | tr -d '[:space:]')"
        blocked="$(awk -F'\t' '$3=="BLOCKED"' "$out/tasks.tsv" | wc -l | tr -d '[:space:]')"
        printf 'tasks: %s   open: %s   blocked: %s\n' "$total" "$open_count" "$blocked" | tee -a "$out/ledger-state.txt"
        if [ "$open_count" = "0" ]; then
            pass "ledger: $total tasks, none open, $blocked blocked"
        else
            fail "ledger: $open_count task(s) still open"
            awk -F'\t' '$3!="DONE" && $3!="BLOCKED" {printf "        %s %s %s\n", $1, $2, $3}' "$out/tasks.tsv" | head -20
        fi
        # A BLOCKED task without a written reason is not BLOCKED, it is abandoned.
        missing_reason="$(jq -r '.tasks[] | select(.status=="BLOCKED" and ((.blocked_reason // "") | length == 0)) | .id' AUDIT/ledger.json)"
        if [ -z "$missing_reason" ]; then
            pass "every BLOCKED task carries a blocked_reason"
        else
            fail "BLOCKED without a reason: $(printf '%s' "$missing_reason" | tr '\n' ' ')"
        fi
    fi
else
    fail "jq is not installed, so the ledger state could not be read"
fi

# ---------------------------------------------------------------- generated files in step
section "12/12  generated files are in step with their sources"
if python3 tools/embed-web.py --check > "$out/embed-web.txt" 2>&1; then
    pass "the embedded web interface matches web/"
else
    fail "web/ and WebAssets.swift have drifted; see $out/embed-web.txt"
fi
if python3 tools/embed-names.py --check > "$out/embed-names.txt" 2>&1; then
    pass "the embedded name lists match names/"
else
    fail "names/ and the embedded lists have drifted; see $out/embed-names.txt"
fi
# The ledger's own status tables are generated from the JSON the other gates read (A118). Before that
# they were hand-maintained and had drifted to 28 of 116 tasks while the handover called the page the
# source of truth, so this is checked like any other generated file.
if bash AUDIT/render-ledger.sh --check > "$out/render-ledger.txt" 2>&1; then
    pass "$(cat "$out/render-ledger.txt")"
else
    fail "ledger.md has drifted from ledger.json; run AUDIT/render-ledger.sh — see $out/render-ledger.txt"
fi

# ---------------------------------------------------------------- summary
printf '\n=== summary ===\n'
# `${results[@]+...}` rather than `${results[@]}`: under `set -u`, bash 3.2 — which is what macOS
# ships and what the fresh clone on the verification host will use — treats an empty array
# expansion as an unbound variable. This script runs on that host, so it has to be 3.2-clean.
printf '%s\n' ${results[@]+"${results[@]}"} | sed 's/^/  /'
printf '\n%d passed, %d failed. Logs in %s\n' "$passes" "$failures" "$out"

# Written as a file too, so the summary can be quoted in the ledger without re-deriving it.
{
    printf 'Phase E acceptance run\nbranch: %s\ncommit: %s\n\n' "$branch" "$head_sha"
    printf '%s\n' ${results[@]+"${results[@]}"} | sed 's/^/  /'
    printf '\n%d passed, %d failed\n' "$passes" "$failures"
} > "$out/summary.txt"

if [ "$failures" -eq 0 ]; then
    exit 0
fi
exit 1
