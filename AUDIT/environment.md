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
| Swift | 6.4 (swiftlang-6.4.0.34.1) | Xcode 27.0 (27A266a) | build, tests, strict concurrency |
| SDK | macOS 27.0 | Xcode 27.0 | target platform (package requires `.macOS(.v26)`) |
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
# Xcode 27.0 (Swift 6.4) — App Store or developer.apple.com, then:
sudo xcode-select -s /Applications/Xcode.app
swift --version                     # expect 6.4

brew install swift-format swiftlint llvm gitleaks osv-scanner semgrep ruff pyright shellcheck jq
```

## What this audit installed

**Nothing.** No tool was installed, upgraded, or removed on any host. The fleet is in the state it
was found in, apart from the audit branch and `AUDIT/` directory committed to this repository.

## Contention on the development Mac, measured

Worth recording because Phase E's timings and any flakiness have to be read against it, and
because it is the reason the final verification runs on `node1` rather than here.

The development Mac is an **8-core, 24 GB** machine, and during the fix phase it was running
three concurrent Swift lanes, each with its own `--scratch-path`, while **not** being otherwise
idle:

| Observed | Value |
| --- | --- |
| Load average | **66–92** on 8 cores |
| Memory free | **11 %**, with 3.3 M pageouts |
| An unrelated process | `NVMAIServer`, from a different project under `Coding/`, at ~32 % CPU |
| `fileproviderd` | ~50 % CPU — the CloudStorage file provider reacting to a working tree that lives inside it |
| Build scratch | ~4.7 GB across three `/tmp/chatbots-scratch-*` trees |

So three parallel Swift lanes were oversubscribed, and the scratch trees were cleaned up once the
lanes finished rather than being left in `/tmp`. Two consequences are recorded rather than
discovered later:

- **A green local run is not evidence about a quiet machine.** Phase E therefore runs on `node1`,
  which is not running this workload, and the acceptance script records the commit it tested so the
  result is tied to a revision rather than to a moment.
- **Any timing-sensitive observation taken from this Mac during the fix phase is suspect.** None of
  the conclusions in the ledger rest on a duration; the ones that could have (the import timeout,
  the readiness wait) were verified by asserting behaviour with faked clocks rather than by
  measuring elapsed time on a loaded machine.

## Hosts touched

| Host | What was written | Removed afterwards |
| --- | --- | --- |
| `this Mac` | the audit branch, `AUDIT/`, and build scratch under the default `.build` | n/a — this is the working checkout |
| `node1` (`ssh node1@node1.local`) | `~/chatbots-audit/`: a fresh `git clone --branch audit/2026-09-13 --single-branch` of the public repository, plus `build.log`, `test.log`, `clone.log`, `guard.log`, `run.log` | **yes** — `rm -rf ~/chatbots-audit`. Verified gone; no `~/Library/Caches/ChatBots`; no chatbot- or audit-named entry left in the home directory. Nothing was installed on `node1`. |

`node1` was used rather than the development Mac because §1b requires the final verification to run
on a host that did not develop the fix. It was used for the A18 fresh-clone check (an independent
host is the entire point of that task, and finding the problem on the first independent run rather
than at the end is why the check was done early), and again for Phase E, which needs the same
property.

Both runs on `node1` recorded the same facts: `swift build` exit 0, `swift test` exit 0, and
`git rev-parse --short HEAD` naming the exact commit under test, so the result is tied to a commit
rather than to "the branch at some point".

## Phase E, and what this session did on `node1`

Phase E ran **twice**, and the difference between the runs is the point of running it at all.

| | |
| --- | --- |
| First run | from `~/chatbots-audit`, freshly cloned from the pushed branch at that time. **18 passed, 5 failed.** Every failure was a defect in a gate or a stale record (A123–A127), not in the product. |
| Second run | after those five were fixed and pushed, `~/chatbots-audit` was deleted, re-cloned from the pushed branch, and the run repeated against the final head. |

Both runs used the same path, `~/chatbots-audit`, and **it is removed when the session ends** — per
§1b, the verification host keeps no residue. The final run's logs and `summary.txt` are committed
into this clone at `AUDIT/baseline/phaseE/`, so the evidence outlives the directory that produced it.

**Toolchain added on `node1` for this audit:** `caddy` 2.11.4 (`brew install caddy`), used to verify
A99 by measurement rather than by reading — the shipped `Caddyfile` in front of the real engine, with
an unknown conversation id so that the response body identifies which server answered. `caddy` is not
required to build or run the project; the packaged app and the installer do not use it.

## Toolchain move to Swift 6.4 (2026-09-15)

The package now declares `swift-tools-version: 6.4` and the Mac gates run on Swift 6.4 / Xcode 27.
Verified locally: `swift build` clean (warnings are errors in the manifest) and the full suite green
— 824 tests in 139 suites.

GitHub's CodeQL *default setup* could not follow: its autobuild image ships Swift 6.3.3 and cannot
parse a 6.4 manifest (`package 'sources' is using Swift tools version 6.4.0 but the installed version
is 6.3.3`), so `swift` was removed from this repository's CodeQL default setup. Advanced setup on the
`xcode-27` image with `build-mode: manual`, as MCPSearch uses, is the way to bring Swift CodeQL back;
until then the Swift gates remain the local/CI ones above.
