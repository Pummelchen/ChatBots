#!/usr/bin/env bash
# The gates that can only run on this Mac, in one command.
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
#   tools/mac-checks.sh
#
#   1. sizes      tools/check-file-sizes.sh          no tracked code file over 500 lines
#   2. build      swift build --build-tests          products and tests, warnings are errors
#   3. tests      swift test --enable-code-coverage  the full suite
#   4. coverage   llvm-cov over Sources/             the profile that run produced
#   5. swiftlint  swiftlint lint Sources Tests
#   6. format     swift-format lint --recursive --strict Sources Tests
#   7. web        the two Node checks for web/deltas.js and web/votes.js
#   8. identity   VERSION, and every mirror of it that can be checked without building
#
# Warnings-as-errors is not a flag this script adds: it lives in `Package.swift`
# (`treatAllWarnings(as: .error)`), so `swift build`, `swift test` and Xcode all get it and
# no invocation can bypass it.
#
# Every gate runs even when an earlier one fails, and the summary at the end names each one;
# the exit status is non-zero if any gate failed. Nothing here is suppressed, downgraded or
# made advisory — a finding is a finding. Gates 5 and 6 report the pre-configuration
# recorded waivers in `tools/analysis-waivers.txt` rather than against zero.
# Gate 4 reports a number rather than enforcing a floor: no coverage floor is set anywhere.
# Gate 1 runs first because it is the cheapest and the one a large file can be caught by
# before a build has to happen.
#
# Full output for each gate is kept in `.build/mac-checks/` (ignored with the rest of
# `.build`). `jq` is used to count the swiftlint findings; it is part of the recorded
# toolchain (`docs/toolchain.md`).
#
# usage: tools/mac-checks.sh
# exit:  0 when every gate passed, 1 when a gate failed, 2 when a tool is missing.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 2

for tool in swift swiftlint swift-format xcrun jq node; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'missing required tool: %s (see docs/toolchain.md)\n' "$tool" >&2
        exit 2
    fi
done

# The commit this run measured. `tools/make-release.sh --gates-log` requires this line, so a
# gate log produced on some other commit cannot be reused as evidence for this one.
head_sha="$(git rev-parse HEAD 2>/dev/null || true)"
printf 'mac-checks commit: %s\n' "${head_sha:-unknown}"

logs=".build/mac-checks"
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

printf '\n=== 1/7  file sizes: tracked code ===\n'
if bash tools/check-file-sizes.sh > "$logs/file-sizes.log" 2>&1; then
    pass "$(tail -1 "$logs/file-sizes.log" | sed 's/^PASS  //')"
else
    printf '      %s\n' "$(head -1 "$logs/file-sizes.log")"
    tail -n +2 "$logs/file-sizes.log" | sed 's/^/      /'
    fail "file sizes: a tracked code file is over 500 lines"
fi

printf '\n=== 2/7  build: products and tests, warnings are errors ===\n'
if swift build --build-tests > "$logs/build.log" 2>&1; then
    pass "build: swift build --build-tests"
else
    printf '      last 20 lines of %s:\n' "$logs/build.log"
    tail -n 20 "$logs/build.log" | sed 's/^/      /'
    fail "build: swift build --build-tests"
fi

printf '\n=== 3/7  tests: the full suite ===\n'
if swift test --enable-code-coverage > "$logs/test.log" 2>&1; then
    # Summed across test bundles: `swift test` runs one process per test target and each prints its
    # own "Test run with" line, so taking the last one reported a single target's count.
    test_summary="$(grep -E 'Test run with' "$logs/test.log" \
        | sed -E 's/.*with ([0-9]+) tests? in ([0-9]+) suites.*/\1 \2/' \
        | awk '{t += $1; s += $2} END {printf "%d tests in %d suites", t, s}')"
    printf '      %s\n' "${test_summary:-swift test passed}"
    pass "tests: ${test_summary:-swift test passed}"
else
    printf '      last 20 lines of %s:\n' "$logs/test.log"
    tail -n 20 "$logs/test.log" | sed 's/^/      /'
    fail "tests: swift test --enable-code-coverage"
fi

printf '\n=== 4/7  coverage: Sources/ ===\n'
bin_path="$(swift build --show-bin-path 2>/dev/null)"
profile="$bin_path/codecov/default.profdata"
    # One test bundle per test target, named after the target. The single bundle this used to name was
    # `ChatBotsPackageTests.xctest`, which Xcode 27 renamed to `ChatBotsCoreTests.xctest`, and a
    # second target was added — so the name is discovered rather than written down, and the next
    # rename or target is not a silent failure (both were fixed by this).
    test_bundles=()
    for bundle in "$bin_path"/*.xctest; do
        bundle_executable="$bundle/Contents/MacOS/$(basename "$bundle" .xctest)"
        [ -x "$bundle_executable" ] && test_bundles+=("$bundle_executable")
    done
if [ -f "$profile" ] && [ "${#test_bundles[@]}" -gt 0 ] \
    && xcrun llvm-cov report "${test_bundles[@]}" \
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
        printf '      no coverage profile at %s, or no test bundle under %s (did the test gate run?)\n' "$profile" "$bin_path"
    fi
    fail "coverage: llvm-cov report over Sources/"
fi

printf '\n=== 5/7  swiftlint: Sources, Tests ===\n'
# The configs were added with their residual recorded, so this gate is "no worse than the
# recorded number" rather than "zero" — which is the only form of it that can pass
# without hiding findings. The waivers live in tools/analysis-waivers.txt so that raising one is a deliberate,
# reviewable edit. Both numbers below are read from the tool's own report.
waiver_for() {
    # No `\b`: BSD sed, which is what macOS ships, does not support word boundaries, and with
    # one in the pattern this silently matched nothing and the gate reported "no waiver
    # recorded" for a waiver that was there.
    sed -n "s/.*$1 waiver: \([0-9][0-9]*\).*/\1/p" tools/analysis-waivers.txt | head -1
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
            fail "swiftlint: $findings finding(s) and no waiver recorded in tools/analysis-waivers.txt"
        elif [ "$findings" -le "$allowed" ]; then
            pass "swiftlint: $findings finding(s), within the recorded waiver of $allowed"
        else
            fail "swiftlint: $findings finding(s) exceeds the recorded waiver of $allowed"
        fi
        ;;
esac

printf '\n=== 6/7  swift-format lint: Sources, Tests ===\n'
# Authored Swift only: the generated `WebAssets.swift` and `NameLists.swift` carry thousands
# of diagnostics of their own, which makes the count a function of `web/` and `names/` rather than
# of this repository's code. swiftlint excludes the same two in `.swiftlint.yml`.
find Sources Tests -name '*.swift' ! -name 'WebAssets.swift' ! -name 'NameLists.swift' -print0 \
    | xargs -0 swift-format lint > "$logs/swift-format.txt" 2>&1
# Counted from the diagnostic lines, NOT with `wc -l` on the output. This gate reported `wc -l`
# first, which is exactly the mistake this gate once made: a 3,003-diagnostic run produces about 30,000
# lines, so the number it printed was the size of the file rather than the size of the problem.
diagnostics="$(grep -cE 'warning:|error:' "$logs/swift-format.txt" || true)"
allowed="$(waiver_for swift-format)"
if [ -z "$allowed" ]; then
    fail "swift-format: $diagnostics diagnostic(s) and no waiver recorded in tools/analysis-waivers.txt"
elif [ "$diagnostics" -le "$allowed" ]; then
    pass "swift-format: $diagnostics diagnostic(s), within the recorded waiver of $allowed"
else
    fail "swift-format: $diagnostics diagnostic(s) exceeds the recorded waiver of $allowed"
fi

printf '\n=== 7/7  web: the rules the page runs ===\n'
# The page's streaming reply is drawn from `state.snapshot.live`, and the merge that fills it from the
# engine's `delta` events is pure JavaScript in `web/deltas.js`. It used to live inline in `app.js` and
# there was no way to run it, which is how the page came to listen for nothing but whole-turn
# snapshots. This runs it in Node, with no browser and no network.
if node tools/check-web-deltas.js > "$logs/web-deltas.log" 2>&1; then
    pass "web: deltas merge ($(grep -c '  ok ' "$logs/web-deltas.log") cases)"
else
    printf '      last 20 lines of %s:\n' "$logs/web-deltas.log"
    tail -n 20 "$logs/web-deltas.log" | sed 's/^/      /'
    fail "web: deltas merge"
fi

# The audience's verdict rule, for the same reason and in the same shape: a turn is drawn once and
# its buttons are re-marked in place, so the click handler used to work from the verdict captured when the
# row was built. `web/votes.js` holds the rule; this runs it in Node and checks the page's use of it.
if node tools/check-web-votes.js > "$logs/web-votes.log" 2>&1; then
    pass "web: the verdict rule ($(grep -c '  ok ' "$logs/web-votes.log") cases)"
else
    printf '      last 20 lines of %s:\n' "$logs/web-votes.log"
    tail -n 20 "$logs/web-votes.log" | sed 's/^/      /'
    fail "web: the verdict rule"
fi

printf '\n=== 8/8  identity: the version and its mirrors ===\n'
# `VERSION` at the repository root is the one authoritative value (RELEASE.md §1.3). A mirror
# that disagrees is a release defect, so it fails here rather than at release time; the built
# bundle's own copy is checked by `tools/make-release.sh`, which is the only place a built
# bundle exists.
if bash tools/check-identity.sh > "$logs/identity.txt" 2>&1; then
    pass "$(tail -1 "$logs/identity.txt" | sed 's/^PASS  //')"
else
    tail -n 5 "$logs/identity.txt" | sed 's/^/      /'
    fail "identity: VERSION and its mirrors disagree"
fi

printf '\n=== summary ===\n'
cat "$summary"
if [ "$failures" -eq 0 ]; then
    printf '\nAll 8 Mac-only gates passed.\n'
    exit 0
fi
printf '\n%d of 8 Mac-only gates failed. Full output in %s/.\n' "$failures" "$logs"
exit 1
