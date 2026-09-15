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

for tool in swift swiftlint swift-format xcrun jq node; do
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

printf '\n=== 1/6  build: products and tests, warnings are errors ===\n'
if swift build --build-tests > "$logs/build.log" 2>&1; then
    pass "build: swift build --build-tests"
else
    printf '      last 20 lines of %s:\n' "$logs/build.log"
    tail -n 20 "$logs/build.log" | sed 's/^/      /'
    fail "build: swift build --build-tests"
fi

printf '\n=== 2/6  tests: the full suite ===\n'
if swift test --enable-code-coverage > "$logs/test.log" 2>&1; then
    test_summary="$(grep -E 'Test run with' "$logs/test.log" | tail -1)"
    printf '      %s\n' "${test_summary:-swift test passed}"
    pass "tests: ${test_summary:-swift test passed}"
else
    printf '      last 20 lines of %s:\n' "$logs/test.log"
    tail -n 20 "$logs/test.log" | sed 's/^/      /'
    fail "tests: swift test --enable-code-coverage"
fi

printf '\n=== 3/6  coverage: Sources/ ===\n'
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

printf '\n=== 4/6  swiftlint: Sources, Tests ===\n'
# A06 added the configs and recorded what their residual is, so this gate is "no worse than the
# number this audit recorded" rather than "zero" — which is the only form of it that can pass
# without hiding findings. The waivers live in AUDIT/plan.md so that raising one is a deliberate,
# reviewable edit. Both numbers below are read from the tool's own report.
waiver_for() {
    # No `\b`: BSD sed, which is what macOS ships, does not support word boundaries, and with
    # one in the pattern this silently matched nothing and the gate reported "no waiver
    # recorded" for a waiver that was there.
    sed -n "s/.*$1 waiver: \([0-9][0-9]*\).*/\1/p" AUDIT/plan.md | head -1
}

swiftlint lint --quiet --reporter json Sources Tests > "$logs/swiftlint.json" 2>"$logs/swiftlint.err"
findings="$(jq 'length' "$logs/swiftlint.json" 2>/dev/null)"
allowed="$(waiver_for swiftlint)"
case "${findings:-}" in
    ''|*[!0-9]*)
        fail "swiftlint: could not read a count from the JSON reporter"
        ;;
    *)
        if [ -z "$allowed" ]; then
            fail "swiftlint: $findings finding(s) and no waiver recorded in AUDIT/plan.md"
        elif [ "$findings" -le "$allowed" ]; then
            pass "swiftlint: $findings finding(s), within the recorded waiver of $allowed"
        else
            fail "swiftlint: $findings finding(s) exceeds the recorded waiver of $allowed"
        fi
        ;;
esac

printf '\n=== 5/6  swift-format lint: Sources, Tests ===\n'
# Authored Swift only: the generated `WebAssets.swift` and `NameLists.swift` carry thousands
# of diagnostics of their own, which makes the count a function of `web/` and `names/` rather than
# of this repository's code (A125). swiftlint excludes the same two in `.swiftlint.yml`.
find Sources Tests -name '*.swift' ! -name 'WebAssets.swift' ! -name 'NameLists.swift' -print0 \
    | xargs -0 swift-format lint > "$logs/swift-format.txt" 2>&1
# Counted from the diagnostic lines, NOT with `wc -l` on the output. This gate reported `wc -l`
# first, which is exactly the mistake A28 records: a 3,003-diagnostic run produces about 30,000
# lines, so the number it printed was the size of the file rather than the size of the problem.
diagnostics="$(grep -cE 'warning:|error:' "$logs/swift-format.txt" || true)"
allowed="$(waiver_for swift-format)"
if [ -z "$allowed" ]; then
    fail "swift-format: $diagnostics diagnostic(s) and no waiver recorded in AUDIT/plan.md"
elif [ "$diagnostics" -le "$allowed" ]; then
    pass "swift-format: $diagnostics diagnostic(s), within the recorded waiver of $allowed"
else
    fail "swift-format: $diagnostics diagnostic(s) exceeds the recorded waiver of $allowed"
fi

printf '\n=== 6/6  web: the merge that turns per-token events into live text ===\n'
# The page's streaming reply is drawn from `state.snapshot.live`, and the merge that fills it from the
# engine's `delta` events is pure JavaScript in `web/deltas.js`. It used to live inline in `app.js` and
# there was no way to run it, which is how the page came to listen for nothing but whole-turn
# snapshots (A165). This runs it in Node, with no browser and no network.
if node tools/check-web-deltas.js > "$logs/web-deltas.log" 2>&1; then
    pass "web: deltas merge ($(grep -c '  ok ' "$logs/web-deltas.log") cases)"
else
    printf '      last 20 lines of %s:\n' "$logs/web-deltas.log"
    tail -n 20 "$logs/web-deltas.log" | sed 's/^/      /'
    fail "web: deltas merge"
fi

printf '\n=== summary ===\n'
cat "$summary"
if [ "$failures" -eq 0 ]; then
    printf '\nAll 6 Mac-only gates passed.\n'
    exit 0
fi
printf '\n%d of 6 Mac-only gates failed. Full output in %s/.\n' "$failures" "$logs"
exit 1
