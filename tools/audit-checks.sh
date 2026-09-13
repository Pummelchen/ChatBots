#!/usr/bin/env bash
# AUDIT — the gates that can only run on this Mac, in one command.
#
# The push-time workflow (`.github/workflows/checks.yml`) runs the checks a hosted Linux
# runner can honestly run: the generated files are in step, the shell and Python parse, and
# the shell linter, ruff, pyright, gitleaks, semgrep and osv-scanner all run. The Swift gates
# cannot run there: this package needs macOS 26 and Apple-silicon MLX, and no hosted runner
# image is either. A Swift job on `ubuntu-latest` would be red for a reason that has nothing
# to do with the code.
#
# So those gates live here, in the one command to run before pushing:
#
#   tools/audit-checks.sh
#
#   1. build      swift build --build-tests          products and tests, warnings are errors
#   2. tests      swift test --enable-code-coverage  the full suite
#   3. coverage   llvm-cov over Sources/             the profile that run produced
#   4. swiftlint  swiftlint lint Sources Tests
#   5. format     swift-format lint --recursive --strict Sources Tests
#
# Warnings-as-errors is not a flag this script adds: it lives in `Package.swift`
# (`treatAllWarnings(as: .error)`), so `swift build`, `swift test` and Xcode all get it and
# no invocation can bypass it.
#
# Every gate runs even when an earlier one fails, and the summary at the end names each one;
# the exit status is non-zero if any gate failed. Nothing here is suppressed, downgraded or
# made advisory — a finding is a finding. Gates 4 and 5 report the pre-configuration
# baselines recorded in `AUDIT/plan.md` until a repository config exists for each tool.
# Gate 3 reports a number rather than enforcing a floor: no coverage floor is set anywhere.
#
# Full output for each gate is kept in `.build/audit-checks/` (ignored with the rest of
# `.build`). `jq` is used to count the swiftlint findings; it is part of the recorded
# toolchain (`AUDIT/environment.md`).
#
# usage: tools/audit-checks.sh
# exit:  0 when every gate passed, 1 when a gate failed, 2 when a tool is missing.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 2

for tool in swift swiftlint swift-format xcrun jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'missing required tool: %s (see AUDIT/environment.md)\n' "$tool" >&2
        exit 2
    fi
done

logs=".build/audit-checks"
mkdir -p "$logs"
summary="$logs/summary.txt"
: > "$summary"

failures=0

pass() {
    printf 'PASS  %s\n' "$1"
    printf 'PASS  %s\n' "$1" >> "$summary"
}

fail() {
    printf 'FAIL  %s\n' "$1"
    printf 'FAIL  %s\n' "$1" >> "$summary"
    failures=$((failures + 1))
}

printf '\n=== 1/5  build: products and tests, warnings are errors ===\n'
if swift build --build-tests > "$logs/build.log" 2>&1; then
    pass "build: swift build --build-tests"
else
    printf '      last 20 lines of %s:\n' "$logs/build.log"
    tail -n 20 "$logs/build.log" | sed 's/^/      /'
    fail "build: swift build --build-tests"
fi

printf '\n=== 2/5  tests: the full suite ===\n'
if swift test --enable-code-coverage > "$logs/test.log" 2>&1; then
    test_summary="$(grep -E 'Test run with' "$logs/test.log" | tail -1)"
    printf '      %s\n' "${test_summary:-swift test passed}"
    pass "tests: ${test_summary:-swift test passed}"
else
    printf '      last 20 lines of %s:\n' "$logs/test.log"
    tail -n 20 "$logs/test.log" | sed 's/^/      /'
    fail "tests: swift test --enable-code-coverage"
fi

printf '\n=== 3/5  coverage: Sources/ ===\n'
bin_path="$(swift build --show-bin-path 2>/dev/null)"
profile="$bin_path/codecov/default.profdata"
test_binary="$bin_path/ChatBotsPackageTests.xctest/Contents/MacOS/ChatBotsPackageTests"
if [ -f "$profile" ] && [ -f "$test_binary" ] \
    && xcrun llvm-cov report "$test_binary" \
        -instr-profile "$profile" \
        --sources Sources > "$logs/coverage.log" 2>&1
then
    coverage_total="$(grep -E '^TOTAL' "$logs/coverage.log" | tail -1)"
    printf '      %s\n' "${coverage_total:-report written to $logs/coverage.log}"
    pass "coverage: ${coverage_total:-llvm-cov report written}"
else
    if [ -f "$logs/coverage.log" ]; then
        printf '      last 20 lines of %s:\n' "$logs/coverage.log"
        tail -n 20 "$logs/coverage.log" | sed 's/^/      /'
    else
        printf '      no coverage profile at %s (did the test gate produce one?)\n' "$profile"
    fi
    fail "coverage: llvm-cov report over Sources/"
fi

printf '\n=== 4/5  swiftlint: Sources, Tests ===\n'
if swiftlint lint --reporter json Sources Tests > "$logs/swiftlint.json" 2>"$logs/swiftlint.err"; then
    pass "swiftlint: 0 findings"
else
    findings="$(jq 'length' "$logs/swiftlint.json" 2>/dev/null)"
    fail "swiftlint: ${findings:-unknown} finding(s), see $logs/swiftlint.json"
fi

printf '\n=== 5/5  swift-format lint: Sources, Tests ===\n'
if swift-format lint --recursive --strict Sources Tests > "$logs/swift-format.txt" 2>&1; then
    pass "swift-format lint: 0 diagnostics"
else
    diagnostics="$(wc -l < "$logs/swift-format.txt" | tr -d '[:space:]')"
    fail "swift-format lint: ${diagnostics} diagnostic line(s), see $logs/swift-format.txt"
fi

printf '\n=== summary ===\n'
cat "$summary"
if [ "$failures" -eq 0 ]; then
    printf '\nAll 5 Mac-only gates passed.\n'
    exit 0
fi
printf '\n%d of 5 Mac-only gates failed. Full output in %s/.\n' "$failures" "$logs"
exit 1
