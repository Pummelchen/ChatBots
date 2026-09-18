# Toolchain

What this project needs, what it is developed and gated against, and how to reproduce it. The short
version: **an Apple-silicon Mac on macOS 26 or newer, Xcode, and one downloadable Xcode component.**

## What you need

| | |
| --- | --- |
| Hardware | Apple silicon (M1–M6). MLX runs on the GPU; there is no Intel or x86_64 build. |
| macOS | **26 or newer.** `Package.swift` declares `.macOS(.v26)` and the app bundle's `LSMinimumSystemVersion` must match it — CI fails if the two disagree. |
| Xcode | 27.0 or newer (this repository is developed on 27.0 with Swift 6.4). |
| Metal toolchain | **Required, and no longer part of Xcode.** `xcodebuild -downloadComponent MetalToolchain` — without it every build fails on the first `.metal` kernel mlx-swift compiles. `tools/check-metal.sh` runs the compiler rather than looking for it, because `xcrun --find metal` answers with a path even where the component is missing. |

## Versions this repository is gated against

Provenance is `brew list --versions …` unless stated.

| Tool | Version | Used for |
| --- | --- | --- |
| Swift | 6.4 (swiftlang-6.4.0.34.1) | build, tests, strict concurrency (`swiftLanguageMode(.v6)`, warnings as errors) |
| `swift-format` | 603.0.0 | formatter and `lint` |
| `swiftlint` | 0.65.1 | linter |
| `llvm-cov` | `xcrun llvm-cov` (Xcode), or Homebrew LLVM 23.1.1 | coverage |
| `gitleaks` | 8.30.1 | secret scan over the **full history** |
| `osv-scanner` | 2.5.1 | dependency/CVE scan of the resolved `Package.resolved` |
| `semgrep` | 1.176.0 | SAST |
| `ruff` | 0.16.7 | Python lint and format check |
| `pyright` | 1.1.414 | Python type check |
| `shellcheck` | 0.11.0 | shell lint |
| `eslint` | 10.10.0 | JavaScript lint (pinned by `package-lock.json`, installed with `npm ci`) |
| `prettier` | 3.9.8 | JavaScript, HTML and CSS format check (same lockfile) |
| Node.js | 26 | runs `tools/check-web-*.js` and the JavaScript toolchain |
| Python | 3.14 | runs `tools/*.py` |
| `jq` | 1.8 | parsing scanner output |

`swiftlint` and `swift-format` run with `--strict` and are judged against zero: gates 5 and 6 of
`tools/mac-checks.sh` fail on a single finding, and the exit status is checked alongside the count so a
run that reports nothing because it linted nothing cannot pass as clean. Both were driven to zero during
the audit — swiftlint from 206 findings, swift-format from 306 diagnostics — so the caps they used to
carry are gone rather than sitting unused. `.swiftlint.yml` and `.swift-format` remain the rule
configuration. The semgrep findings this project accepts are the only entries left in
`tools/analysis-waivers.txt`.

The JavaScript toolchain is installed with `npm ci` from the committed `package-lock.json`; the
lockfile is the pin. `tools/mac-checks.sh` and CI both fail when it has not been installed rather than
skipping the gate, because a gate that silently does nothing is not a gate.

## Reproducing it

```sh
# Xcode 27 (Swift 6.4) — App Store or developer.apple.com, then:
sudo xcode-select -s /Applications/Xcode.app
swift --version                             # expect 6.4

# The compiler Xcode 27 no longer ships:
xcodebuild -downloadComponent MetalToolchain

brew install swift-format swiftlint llvm gitleaks osv-scanner semgrep ruff pyright shellcheck jq
```

Then the gates this repository has:

```sh
tools/mac-checks.sh       # the Mac-only gates: sizes, build, tests + coverage, swiftlint, swift-format, web
tools/check-file-sizes.sh # the same size gate on its own: no tracked code file over 500 lines
```

CI runs the rest on Linux: the generated files are in step, no tracked code file is over 500 lines, the
notices tool passes, the shell, Python and JavaScript are linted and scanned, and `gitleaks` and
`osv-scanner` are clean. The Swift gates cannot run there — no hosted image is macOS 26 on Apple silicon
with MLX — so they live in `tools/mac-checks.sh` and are run on a Mac.

The size limit is one number in one script. `tools/check-file-sizes.sh` asks git for the tracked files,
measures the code (Swift, JavaScript, CSS, HTML, shell, Python) and exempts the two generated files,
`WebAssets.swift` and `NameLists.swift`, whose length is a function of the sources they are built from.
Both CI and `tools/mac-checks.sh` call that script rather than repeating the rule, so the two can never
disagree about which file is too long.

## Pinning

The three tools CI installs as release binaries — `shellcheck`, `gitleaks`, `osv-scanner` — are fetched
by `tools/fetch-analysis-tools.sh`, which pins each version, URL and SHA-256 and verifies the digest before
unpacking. `tools/toolchain-versions.txt` carries the same three versions for the workflow to compare
against, so a bump in one place cannot go unnoticed. PyPI and npm tools are pinned by version alone,
because those registries refuse to publish a version twice.

One input is deliberately *not* pinned: `semgrep --config auto` fetches its rule set from the Semgrep
registry at scan time, so the version pin covers the binary and not the rules. The scan is run without
`--quiet` so its own summary — rules run, targets scanned, findings — is in the job log.
