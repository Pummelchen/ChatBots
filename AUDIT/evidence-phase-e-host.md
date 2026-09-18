# Phase E — the independent host

The brief requires the final `tools/mac-checks.sh` run to happen on one host independent of the
machine the work was done on. This is that host's record, taken from the host itself before the gate
ran. It is deliberately not a claim about the primary host.

| what | value |
| --- | --- |
| host | `MacBook-AB.local` (reached as `macbook-ab`) |
| user | `andreborchert` |
| macOS | 27.0, build 26A428 |
| arch | `arm64` (Apple Silicon) |
| Xcode | 27.0, build 27A266a |
| Swift | 6.4 (`swiftlang-6.4.0.34.1`, target `arm64-apple-macosx27.0.0`) |
| swiftlint | 0.65.1 |
| swift-format | 603.0.0 |
| Node.js | v26.8.2 |
| free space | 116 GiB on `/System/Volumes/Data` |

Every tool the gate requires was present (`swift`, `swiftlint`, `swift-format`, `node`, `npm`, `jq`,
`xcrun`, `git`, `python3`), and the three versioned tools are **the same versions the primary host
measured** — swiftlint 0.65.1, swift-format 603.0.0, Node v26.8.2 — so the gate's inputs match and
the comparison is about the machine, not about a different toolchain.

## How the tree got there

A fresh clone, not a copy of the working directory: the branch was written to a git bundle
(`git bundle create audit/2026-09-18`, 7.8 MB), the bundle was copied to the host, and the host
cloned it. The clone reported:

```
HEAD:    367760e4237095dceb374a032d1cec7052277fb3
branch:  audit/2026-09-18
dirty:   0 files
tracked: 469 files
VERSION: 1.0
```

The commit hash is the same one the primary host ran. `npm ci` then installed the JavaScript
toolchain from the committed lockfile, because the gate fails rather than skips when it is missing.

## Result

`bash tools/mac-checks.sh` exited **0** with all nine gates passing — including
`swiftlint: no findings under --strict` and `swift-format: no diagnostics under --strict`, and the
same `1086 tests in 197 suites` the primary host reported. The raw log is
`AUDIT/evidence-phase-e-macbook-ab.log`, and its first line is the commit it measured.

One honest difference: gate 4 (`llvm-cov report`) printed a much lower coverage total on this host
(6.45% against 53%). The gate reports a number and enforces no floor — nothing in this repository
sets one — so it passes either way, but the two figures are not comparable: the remote run measured a
different object set, and this log does not claim otherwise.

## Cleanup

The clone (`/tmp/chatbots-phase-e`), the bundle and the gate log were removed from the host after the
log was copied back. Nothing outside `/tmp` was written.

## Re-run at the final commit

The tree changed after the first run — `SECURITY.md`, the audit records, and the AUDIT-0058 session
token — so the gate was run again rather than leaving the earlier pass as the last word. Same method,
same host:

```
cloned HEAD: aa7a942bcc125f3cdecea1f057bb93b291bbbd16   (git rev-parse HEAD, local, matched)
npm ci: ok
...
PASS  file sizes: every code file is within 500 lines
PASS  build: swift build --build-tests
PASS  tests: 1102 tests in 201 suites
PASS  swiftlint: no findings under --strict
PASS  swift-format: no diagnostics under --strict
PASS  web: deltas merge (34 cases)
PASS  web: the verdict rule (12 cases)
PASS  eslint: web/ and the web check scripts
PASS  prettier: web/ and the web check scripts
PASS  identity: 1.0 is stated once and agrees everywhere
All 9 Mac-only gates passed.  GATE_EXIT=0
```

`1102 tests in 201 suites` is the same count the primary host reports for this commit, so the session
token and its 16 new tests behave identically on the second machine. The raw log is
`AUDIT/evidence-phase-e-final-macbook-ab.log`. The clone, the bundle and the logs were removed from
the host again, and the credential file was removed locally.
