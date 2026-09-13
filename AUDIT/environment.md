# AUDIT — environment and toolchain record

Everything needed to reproduce this audit on another machine. §1 requires the exact name,
version, install method and host for every tool, and §1b requires every host touched to be
listed so the fleet can be returned to a known state.

## Hosts

| Host | Class | Spec | Role in this audit | Installed by this audit |
| --- | --- | --- | --- | --- |
| `MacBook-AB.local` (`Mac15,3`) | Mac, arm64 | macOS 26.6.2 (25G83), 24 GB | Development, all Swift/Apple work, baseline | **nothing** — every tool was already present (see provenance) |
| `node1`–`node4` | Mac Mini M2, arm64 | 8 GB each, Xcode + Docker | Phase E only: fresh-clone verification on a machine that did not develop the fix | **`node1` used and cleaned** — see "Hosts touched" below |
| Intel VPS (Debian 13) | Linux x86_64 | — | **not provisioned.** §1b requires asking first; no Linux/x86 work has been identified in this repository | not touched |

Per §1b: Swift/Xcode builds and Apple-platform tests stay on the Mac; at most one heavy job
runs at a time; Docker and a build never run concurrently on the same host. This repository is
Swift plus a static web front end and Python/shell tooling, so no Linux work is currently
justified — if that changes, the VPS is requested first and recorded here.

## Toolchain

Provenance is `brew list --versions …` unless stated. Nothing was installed for this audit;
each was already on the machine from the Converter/MCPSearch audits, which is why the versions
below are recorded rather than chosen.

| Tool | Version | Method | Used for |
| --- | --- | --- | --- |
| Swift | 6.3.3 (swiftlang-6.3.3.1.3, clang-2100.1.1.101) | Xcode 26.6 (17F113) | build, tests, strict concurrency |
| SDK | macOS 26.5 | Xcode 26.6 | target platform (package requires `.macOS(.v26)`) |
| `swift-format` | 603.0.0 | brew | formatter + `lint` |
| `swiftlint` | 0.65.1 | brew | linter |
| `llvm-cov` | Xcode 21.0.0 toolchain, Homebrew LLVM **23.1.1** | Xcode / brew `llvm` | coverage |
| `gitleaks` | 8.30.1 | brew | secret scan, **full history** (`--log-opts=--all`) |
| `osv-scanner` | 2.5.1 | brew | dependency/CVE scan |
| `semgrep` | 1.176.0 | brew | SAST |
| `ruff` | 0.16.7 | brew | Python lint + format check |
| `pyright` | 1.1.414 | brew | Python type check |
| `shellcheck` | 0.11.0 | brew | shell lint |
| Python | 3.14.7 (`/opt/homebrew/bin/python3`) | brew | runs `tools/*.py`; matches §1's 3.14 requirement |
| Docker | client 29.8.0 / server 29.7.2 | Docker Desktop | available; not needed for this repository's Swift/JS/Python work so far |
| `jq` | 1.8.2 | brew | parsing scanner output |

Language coverage against §1's minimum list:

| Language in repo | formatter | linter | static analyzer | type checker | SAST | CVE | secret scan | coverage |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Swift | `swift-format` | `swiftlint` | `swiftlint` + `swift build` warnings-as-errors | compiler (Swift 6 mode) | `semgrep` | `osv-scanner` | `gitleaks` | `llvm-cov` |
| Python (`tools/`, 5 files) | `ruff format` | `ruff check` | `ruff` | `pyright` | `semgrep` | `osv-scanner` | `gitleaks` | n/a — tooling scripts, not production code |
| Shell (`tools/`, 7 files) | — | `shellcheck` | — | — | `semgrep` | n/a | `gitleaks` | n/a |
| JavaScript (`web/`) | — | see A-findings | — | — | `semgrep` | `osv-scanner` | `gitleaks` | n/a |
| C | none in this repository | — | — | — | — | — | — | — |

There is **no C, C#, or .NET code in this repository**, so the C sanitizer/memory-checker and
.NET requirements of §1 do not apply here. If the audit scope is the whole workspace rather
than this project, those belong to the projects that contain them.

## Reproducing this environment

```sh
# Xcode 26.6 (Swift 6.3.3) — App Store or developer.apple.com, then:
sudo xcode-select -s /Applications/Xcode.app
swift --version                     # expect 6.3.3

brew install swift-format swiftlint llvm gitleaks osv-scanner semgrep ruff pyright shellcheck jq
```

## What this audit installed

**Nothing.** No tool was installed, upgraded, or removed on any host. The fleet is in the state it
was found in, apart from the audit branch and `AUDIT/` directory committed to this repository.

## Hosts touched

| Host | What was written | Removed afterwards |
| --- | --- | --- |
| `this Mac` | the audit branch, `AUDIT/`, and build scratch under the default `.build` | n/a — this is the working checkout |
| `node1` (`ssh node1@node1.local`) | `~/chatbots-audit/`: a fresh `git clone --branch audit/2026-09-13 --single-branch` of the public repository, plus `build.log`, `test.log`, `clone.log`, `guard.log`, `run.log` | **yes** — `rm -rf ~/chatbots-audit`. Verified gone; no `~/Library/Caches/ChatBots`; no chatbot- or audit-named entry left in the home directory. Nothing was installed on `node1`. |

`node1` was used rather than the development Mac because §1b requires the final verification to run
on a host that did not develop the fix. It was used for the A18 fresh-clone check (an independent
host is the entire point of that task, and finding the problem on the first independent run rather
than at the end is why the check was done early) and it will be used again for Phase E, which needs
the same property.

Both runs on `node1` recorded the same facts: `swift build` exit 0, `swift test` exit 0, and
`git rev-parse --short HEAD` naming the exact commit under test, so the result is tied to a commit
rather than to "the branch at some point".
