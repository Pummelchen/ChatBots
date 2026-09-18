# Audit environment record

Recorded 2026-09-18. Every tool below is the single pinned toolchain for the repository;
there is no tool matrix across hosts.

## Primary host (Apple platform)

| Fact | Value |
| --- | --- |
| Host | `Node1.local` (the only host available; see Phase E note below) |
| OS | macOS 27.0 (build 26A428) |
| Arch | arm64 (Apple Silicon) |
| CPU / RAM | 8 cores / 8 GB |
| Xcode | 27.0 (build 27A266a) — satisfies the Swift 6.4 requirement |
| Swift | Apple Swift 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1) |
| SwiftPM | tools-version 6.4 |

The brief requires Xcode 27 / Swift 6.4 for this project. Both are present, so the Swift
work is **not** BLOCKED on toolchain grounds.

### Concurrency limits

8 GB RAM with an MLX/SwiftPM build. Per §1b: at most one heavy job at a time. The baseline
and every subsequent `swift build`/`swift test`/sanitizer run are serialized deliberately.

## Toolchain

| Language | Formatter | Linter | Dep/CVE scanner | Type checker | SAST | Sanitizer |
| --- | --- | --- | --- | --- | --- | --- |
| Swift | swift-format 603.0.0 | SwiftLint 0.65.1 | osv-scanner 2.6.0 | swiftc 6.4 (Swift 6 language mode) | semgrep 1.176.0 | ThreadSanitizer via `swift test --sanitize=thread` |
| Python (`tools/`) | ruff format 0.16.7 | ruff check 0.16.7 | pip-audit (only if a requirements/lock file exists — none does) | (dropped per brief for Python) | semgrep 1.176.0 | n/a |
| Shell (`tools/`, `*.sh`) | (see JS/shell note) | shellcheck 0.11.0 (`-S style`) | n/a | bash -n | semgrep 1.176.0 | n/a |
| JavaScript (`web/`) | prettier 3.9.8 | eslint 10.10.0 | no manifest dependencies / no third-party packages | n/a | semgrep 1.176.0 | n/a |
| C | — | — | — | — | — | — |

Install method for every tool: Homebrew on the primary host, except the three release
binaries CI fetches (`shellcheck`, `gitleaks`, `osv-scanner`) which CI installs from
`tools/fetch-analysis-tools.sh` with a pinned SHA-256.

### Exact versions

```
swift-driver 1.168.6  Apple Swift 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)
Xcode 27.0 (27A266a)
swiftlint 0.65.1
swift-format 603.0.0
ruff 0.16.7
pyright 1.1.414
semgrep 1.176.0
gitleaks 8.30.1
osv-scanner 2.6.0        # local Homebrew; tools/toolchain-versions.txt pins the CI binary at 2.5.1
shellcheck 0.11.0
node v26.8.2
eslint 10.10.0           # from package-lock.json via `npm ci`
prettier 3.9.8           # from package-lock.json via `npm ci`
globals 17.12.0          # eslint's browser/node global tables, same lockfile
python3 3.14.7
jq 1.8.2
bash 5.3.20(1)
git 2.55.0
```

### C

**No C, Objective-C, C++ or Cython source exists in this repository** (`git ls-files` finds
no `.c/.h/.m/.mm/.cpp/.hpp`). The C99 standard, its warning flags, ASan/UBSan and the
"every native-memory module is Tier A" rule therefore have no targets here. This is recorded,
not skipped: the native-interop seams that *do* exist are Swift→libc (POSIX) and
Swift→WebTransport, and they are audited as Swift Tier A below.

### Secret scanning

`gitleaks git --log-opts=--all --redact` over the full history is the immutable-history scan.
Result recorded in `AUDIT/baseline.md`.

## Independent verification host (Phase E)

The brief requires the final Phase E verification on **one independent host**. Only one
host exists in this environment (`Node1.local`). A macOS/Swift 6.4 host cannot be
provisioned without asking (and no VPS satisfies the macOS 26 + Apple Silicon floor), so
Phase E is recorded as BLOCKED on an owner until a second macOS 26 / Xcode 27 host is
provided. See the ledger entry for the Phase E blocker.

## What is installed where

Everything above is installed on the primary host (`Node1.local`) only. No remote host was
provisioned; nothing was installed on any other machine.
