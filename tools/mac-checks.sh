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
#   5. swiftlint  swiftlint lint --strict Sources Tests   zero findings
#   6. format     swift-format lint --strict Sources Tests zero diagnostics
#   7. web        the two Node checks for web/deltas.js and web/votes.js
#   8. jstools    eslint and prettier over web/ and the web check scripts (`npm ci` first)
#   9. identity   VERSION, and every mirror of it that can be checked without building
#
# Warnings-as-errors is not a flag this script adds: it lives in `Package.swift`
# (`treatAllWarnings(as: .error)`), so `swift build`, `swift test` and Xcode all get it and
# no invocation can bypass it.
#
# Every gate runs even when an earlier one fails, and the summary at the end names each one;
# the exit status is non-zero if any gate failed. Nothing here is suppressed, downgraded or
# made advisory — a finding is a finding. Gates 5 and 6 run `--strict`, so a warning fails the
# gate the way an error does, and both are judged against zero: the audit drove the residual the
# waivers used to cover to nothing, and a cap that is no longer needed is a cap that would let the
# debt come back unnoticed. `tools/analysis-waivers.txt` still carries the semgrep findings the
# project accepts; it no longer carries a count for either style gate.
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

printf '\n=== 1/9  file sizes: tracked code ===\n'
if bash tools/check-file-sizes.sh > "$logs/file-sizes.log" 2>&1; then
    pass "$(tail -1 "$logs/file-sizes.log" | sed 's/^PASS  //')"
else
    printf '      %s\n' "$(head -1 "$logs/file-sizes.log")"
    tail -n +2 "$logs/file-sizes.log" | sed 's/^/      /'
    fail "file sizes: a tracked code file is over 500 lines"
fi

printf '\n=== 2/9  build: products and tests, warnings are errors ===\n'
if swift build --build-tests > "$logs/build.log" 2>&1; then
    pass "build: swift build --build-tests"
else
    printf '      last 20 lines of %s:\n' "$logs/build.log"
    tail -n 20 "$logs/build.log" | sed 's/^/      /'
    fail "build: swift build --build-tests"
fi

printf '\n=== 3/9  tests: the full suite ===\n'
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

printf '\n=== 4/9  coverage: Sources/ ===\n'
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

printf '\n=== 5/9  swiftlint: Sources, Tests (strict) ===\n'
# Zero findings, not "no worse than a recorded number": the configs' residual was paid down, so a
# finding here is new debt. `--strict` is what makes a warning fail, and the exit status is checked
# alongside the count so a run that reports nothing because it linted nothing cannot pass as clean.
swiftlint lint --strict --quiet --reporter json Sources Tests > "$logs/swiftlint.json" 2>"$logs/swiftlint.err"
lint_status=$?
findings="$(jq 'length' "$logs/swiftlint.json" 2>/dev/null)"
case "${findings:-}" in
    ''|*[!0-9]*)
        fail "swiftlint: could not read a count from the JSON reporter"
        ;;
    0)
        if [ "$lint_status" -ne 0 ]; then
            tail -n 20 "$logs/swiftlint.err" | sed 's/^/      /'
            fail "swiftlint: --strict exited $lint_status with an empty report, so it did not lint"
        else
            pass "swiftlint: no findings under --strict"
        fi
        ;;
    *)
        fail "swiftlint: $findings finding(s) under --strict"
        ;;
esac

printf '\n=== 6/9  swift-format lint: Sources, Tests (strict) ===\n'
# Authored Swift only: the generated `WebAssets.swift` and `NameLists.swift` carry thousands
# of diagnostics of their own, which makes the count a function of `web/` and `names/` rather than
# of this repository's code. swiftlint excludes the same two in `.swiftlint.yml`.
#
# The diagnostic count comes from the diagnostic lines, NOT `wc -l` on the output: a 3,003-diagnostic
# run produces about 30,000 lines, so that would print the size of the file rather than the size of
# the problem. The exit status is checked too — `--strict` makes any diagnostic a failure, so a
# non-zero status with no diagnostic line means the tool never linted anything.
swift_files="$(find Sources Tests -name '*.swift' ! -name 'WebAssets.swift' ! -name 'NameLists.swift')"
find Sources Tests -name '*.swift' ! -name 'WebAssets.swift' ! -name 'NameLists.swift' -print0 \
    | xargs -0 swift-format lint --strict > "$logs/swift-format.txt" 2>&1
format_status=$?
diagnostics="$(grep -cE 'warning:|error:' "$logs/swift-format.txt" || true)"
if [ -z "$swift_files" ]; then
    fail "swift-format: no Swift file was found to lint"
elif [ "$diagnostics" -ne 0 ]; then
    tail -n 20 "$logs/swift-format.txt" | sed 's/^/      /'
    fail "swift-format: $diagnostics diagnostic(s) under --strict"
elif [ "$format_status" -ne 0 ]; then
    tail -n 20 "$logs/swift-format.txt" | sed 's/^/      /'
    fail "swift-format: exited $format_status without reporting a diagnostic, so it did not lint"
else
    pass "swift-format: no diagnostics under --strict"
fi

printf '\n=== 7/9  web: the rules the page runs ===\n'
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

# The JavaScript toolchain. Prettier owns formatting and ESLint the defects a reader misses. The
# binaries come from `npm ci` against the committed lockfile; a missing install is a failure
# rather than a skip, because a gate that silently does nothing is not a gate.
printf '\n=== 8/9  web toolchain: eslint and prettier ===\n'
if [ ! -x node_modules/.bin/eslint ] || [ ! -x node_modules/.bin/prettier ]; then
    printf '      the JavaScript toolchain is not installed: run npm ci in the repository root\n'
    fail "web toolchain: npm ci has not been run"
else
    if node_modules/.bin/eslint web tools/check-web-deltas.js tools/check-web-votes.js \
        > "$logs/eslint.log" 2>&1; then
        pass "eslint: web/ and the web check scripts"
    else
        tail -n 20 "$logs/eslint.log" | sed 's/^/      /'
        fail "eslint: web/ and the web check scripts"
    fi
    if node_modules/.bin/prettier --check web/*.js tools/check-web-deltas.js tools/check-web-votes.js \
        > "$logs/prettier.log" 2>&1; then
        pass "prettier: web/ and the web check scripts"
    else
        tail -n 20 "$logs/prettier.log" | sed 's/^/      /'
        fail "prettier: web/ and the web check scripts"
    fi
fi

printf '\n=== 9/9  identity: the version and its mirrors ===\n'
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
    printf '\nAll 9 Mac-only gates passed.\n'
    exit 0
fi
printf '\n%d of 9 Mac-only gates failed. Full output in %s/.\n' "$failures" "$logs"
exit 1
