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
| Shell (`tools/`, 7 files at the baseline) | — | `shellcheck` over every tracked `*.sh` (18: `tools/`, `AUDIT/`, probes — A192) | — | — | `semgrep` | n/a | `gitleaks` | n/a |
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


---

# Re-audit — Swift 6.4 / Xcode 27 / macOS 27 (2026-09-15)

The machine this audit runs on was upgraded between sessions: the same Mac now has macOS 27, Xcode 27
and Swift 6.4, and **the macOS 26 SDK is gone** (27.0 is the only SDK installed). The previous
acceptance described a toolchain that no longer exists on any host in the fleet, which is why a full
re-audit was required rather than a spot check.

| | 2026-09-13 audit | 2026-09-15 re-audit |
| --- | --- | --- |
| macOS | 26.6.2 (25G83) | **27.0 (26A428)** |
| Xcode | 26.6 (17F113) | **27.0 (27A266a)** |
| Swift | 6.3.3 | **6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)** |
| SDK | macOS 26.5 | **macOS 27.0 — the only one installed** |
| Development host | `MacBook-AB.local`, 24 GB | **`node1`**, 8 GB |
| Verification host | `node1` | **`node2`** — a Mac that did not develop the fixes |

## The fleet, measured 2026-09-15

| Host | Class | macOS | Xcode | Swift | Metal toolchain | Role |
| --- | --- | --- | --- | --- | --- | --- |
| `node1` (`Node1.local`) | Mac Mini M2, 8 GB | 27.0 | 27.0 | 6.4 | **installed by this audit** | development |
| `node2` (`Node2.local`) | Mac Mini M2, 8 GB | 27.0 | 27.0 | 6.4 | **installed by this audit** | Phase E |
| `node3` (`Node3.local`) | Mac Mini M2, 8 GB | 27.0 | 27.0 | 6.4 | **missing** | spare |
| `node4` (`Node4.local`) | Mac Mini M2, 8 GB | 27.0 | 27.0 | 6.4 | **missing** | spare |

Access is `ssh <node>@<node>.local` — the **machine name is the username**, not the local user. The
first probe of this session used the default user and was refused on all four; recorded so the next
session does not repeat it.

§1b's memory rule is why development is one 8 GB Mac with a single heavy job at a time: no Docker
alongside an Xcode build, and no second build in parallel.

## The Metal toolchain — Xcode 27's new prerequisite (A133)

**Xcode 27 does not ship the Metal compiler.** It is a downloadable component:

```sh
xcodebuild -downloadComponent MetalToolchain   # 839 MB, resolves as "Metal Toolchain 27A266a"
xcodebuild -runFirstLaunch
```

Without it every build of this package fails, because `mlx-swift` compiles generated Metal kernels:

```
error: cannot execute tool 'metal' due to missing Metal Toolchain
error: CompileMetalFile .../mlx-swift/.../steel_attention.metal failed with a nonzero exit code
```

Installed by this audit on `node1`. It resolves through a cryptex mount, so the working invocation is
`xcrun`, not the Xcode toolchain path:

```
$ xcrun --find metal
/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v27.1.266.1.<id>/Metal.xctoolchain/usr/bin/metal
$ xcrun -sdk macosx metal --version
Apple metal version 32023.921 (metalfe-32023.921.6)
```

**`metal` must be *executed* to know it works, not merely resolved.** `xcrun --find metal` returns a
path on a host where the component is absent, so a check built on `--find` reports success on all four
nodes while three of them cannot build. Measured by execution when the fleet was recorded: node1 worked
and node2, node3 and node4 did not, with a stale `com_apple_MobileAsset_MetalToolchain` asset directory
on node2 that was unusable. **node2's component was installed later the same day**, for Phase E, and
then verified by compiling a real kernel rather than by reading a version string — see *How the Metal
component is checked* at the end of this file. node3 and node4 are still without it.

## Toolchain, re-measured

| Tool | 2026-09-13 | 2026-09-15 | Method |
| --- | --- | --- | --- |
| Swift | 6.3.3 | **6.4** | Xcode 27.0 |
| SDK | macOS 26.5 | **macOS 27.0** | Xcode 27.0 |
| `swift-format` | 603.0.0 (brew) | 603.0.0 (brew), which is the one on `PATH` and the one both gates run; Xcode 27's `xcrun swift-format` (reports `main`) reports the same diagnostics | brew |
| `swiftlint` | 0.65.1 | 0.65.1 | brew |
| `llvm-cov` | Homebrew LLVM 23.1.1 | **`xcrun llvm-cov`** (Xcode 27) | Xcode |
| `gitleaks` / `osv-scanner` / `semgrep` / `ruff` / `pyright` / `shellcheck` | 8.30.1 / 2.5.1 / 1.176.0 / 0.16.7 / 1.1.414 / 0.11.0 | unchanged | brew |
| Python | 3.14.7 | 3.14.7 | brew |
| Metal toolchain | *(bundled)* | **component 27A266a, separate download (A133)** | `xcodebuild -downloadComponent` |

Both `swift-format` builds report the same diagnostics on the same tree — **744** when the toolchain
moved, which is where the recorded waiver comes from, and **739** measured 2026-09-16 — so the move did
not change the formatter's verdict and the waiver never had to be raised. It is the **brew** build the
gates run, because they invoke `swift-format` from `PATH`; Xcode's is reachable only through `xcrun` and
is what the comparison was made with.

## Reproducing this environment (2026-09-15)

```sh
# Xcode 27.0 (Swift 6.4) — App Store or developer.apple.com, then:
sudo xcode-select -s /Applications/Xcode.app
xcodebuild -downloadComponent MetalToolchain     # A133: required, or nothing builds
xcodebuild -runFirstLaunch
swift --version                                  # expect 6.4

brew install swiftlint swift-format llvm gitleaks osv-scanner semgrep ruff pyright shellcheck jq
# `swift-format` is installed from brew on purpose: both gates invoke it from PATH and check it with
# `command -v`, which `xcrun` does not satisfy. Xcode 27 ships one too, and `xcrun --find` reports a path
# for it on a host where nothing else is installed — the lesson the Metal component above taught — so the
# gate must not rest on `xcrun` finding it. The two builds agree on the diagnostics; the recorded waiver
# is from the brew one.
```

**The same versions on the CI runner, verified.** GitHub's Linux runner installs shellcheck,
gitleaks and osv-scanner as release binaries and the rest from PyPI and npm. The three binaries are
fetched by `tools/fetch-audit-tools.sh`, which pins each asset's SHA-256 and checks it before
unpacking (A187), and a step in `.github/workflows/checks.yml` fails if the versions in that script
and the versions in the table above disagree — the record is what the audit ran, so a version bumped
in only one of the two would make it untrue. The digests themselves are in
`AUDIT/baseline/swift64/a187-audit-tools.log`, alongside the figures GitHub publishes for the same
assets. What that pin does **not** cover is semgrep's rule set: `--config auto` fetches its rules
from the Semgrep registry at scan time, so the version is fixed and the rules are not (A192 — the
resolved figures are recorded in `plan.md`).

## What this re-audit installed

| Host | Installed | Why | Removal |
| --- | --- | --- | --- |
| `node1` | Xcode 27 Metal Toolchain component (27A266a, 839 MB) | A133 — without it this package cannot build | Xcode ▸ Settings ▸ Components |
| `node2` | Xcode 27 Metal Toolchain component (27A266a, 839 MB) | A133 and Phase E: node2 is the acceptance host and cannot build without it | Xcode ▸ Settings ▸ Components |

## A credential was sitting in plaintext in two wiki clones (A212)

Found on 2026-09-15 while checking the wiki trackers §9 requires after a push. Two of the three wiki
clones in `~/Downloads/` carried a **fine-grained GitHub personal access token, in plaintext, inside
the `origin` URL** in `.git/config`:

| Clone | State before | State after |
| --- | --- | --- |
| `chatbots-wiki-ro` | `https://Pummelchen:<token>@github.com/Pummelchen/ChatBots.wiki.git` | `https://github.com/Pummelchen/ChatBots.wiki.git` |
| `mcps-wiki-ro` | same shape, for `MCPSearch.wiki.git` | `https://github.com/Pummelchen/MCPSearch.wiki.git` |
| `aisessionserver-wiki` | clean (no credential in the URL) | unchanged |

`ChatBots/.git/config` and the two other repository clones were already clean, and nothing in the
audited repository or its history contains a credential — gitleaks has reported 0 findings over the
full history since Phase A, and that result stands.

**What was done.** Both URLs were rewritten to the bare HTTPS form. Pushes and fetches still
authenticate: `~/.gitconfig` already routes `github.com` through `gh auth git-credential`, and `gh` is
logged in as `Pummelchen`. A fetch against the rewritten clone was run afterwards and succeeded, so
the rewrite removed the secret without removing access. `~/.config/gh/hosts.yml` (mode 0600) still
holds the same token, which is where `gh` is designed to keep it.

**What should still happen, by the token's owner.** A token that has been read out of a file into a
terminal or a session log should be treated as disclosed. It is not in the repository and it was not
committed, but it was visible on screen, so rotating it is the safe move; nothing in this audit needs
it, because the credential helper supplies whatever `gh` holds.

**Why it is recorded here rather than as a source fix.** The file it lived in is not in the tree this
audit has scope over (the brief limits it to `Pummelchen/ChatBots`), so there is no repository change
that removes it and no commit to point at. Recording it is the alternative to fixing it silently.

### How the Metal component is checked (A133)

`tools/check-metal.sh` runs the compiler and exits non-zero with the install command when it cannot,
because a machine without the component still answers `xcrun --find metal` with a path:

| Host | `xcrun --find metal` | `tools/check-metal.sh` |
| --- | --- | --- |
| `node1` | cryptex path | **passes** — Apple metal version 32023.921 |
| `node2` (after the install) | cryptex path | **passes** — and a real `.metal` file compiles to a 3 296-byte `.air` |
| `node3` | `/Applications/Xcode.app/.../metal`, exit 0 | **fails** with `cannot execute tool 'metal' due to missing Metal Toolchain` |
| `node4` | not re-measured | not re-measured — both spare hosts were missing it when the fleet was recorded |

`tools/install.sh` calls that script before it downloads anything, so a machine that cannot build now
stops in the first minute instead of failing three minutes into the build. Raw output:
`AUDIT/baseline/swift64/a133-metal.log`.
